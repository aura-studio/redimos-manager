// Package main is the redimos-manager core, compiled as a C-shared dynamic
// library (redimos_core.dll / .so / .dylib) and driven from the Flutter UI via
// dart:ffi.
//
// The core owns everything stateful: it persists the set of configurations, and
// it launches / stops / monitors one redimos child process per configuration.
// The FFI surface is deliberately tiny — every exported function takes and
// returns a UTF-8 JSON string (a C char*). Strings returned to Dart are heap
// C strings that the caller MUST release with rm_free.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
	"unsafe"
)

func main() {} // required for c-shared, never called

// ---------------------------------------------------------------------------
// Persisted model
// ---------------------------------------------------------------------------

// Config is one redimos instance definition. A single Config works for both a
// LOCAL DynamoDB (set Endpoint to e.g. http://localhost:8000) and an ONLINE AWS
// table (leave Endpoint empty so the AWS default credential/region chain is
// used); the same fields cover both. Version selects which redimos binary (and
// therefore which redimo line, v1 or v2) is launched.
type Config struct {
	ID              string   `json:"id"`
	Name            string   `json:"name"`
	Version         string   `json:"version"` // "v1" | "v2"
	Port            int      `json:"port"`
	Table           string   `json:"table"`
	Endpoint        string   `json:"endpoint"` // endpoint url; "" => online AWS default resolver
	PartitionID     string   `json:"partitionID"`
	Region          string   `json:"region"` // signingRegion
	AccessKeyID     string   `json:"accessKeyId"`
	SecretKey       string   `json:"secretKey"`
	SessionToken    string   `json:"sessionToken"`
	Source          string   `json:"source"`
	MultiDB         bool     `json:"multiDb"`
	AutoCreateTable bool     `json:"autoCreateTable"`
	AutoRestart     bool     `json:"autoRestart"`
	RunMode         string   `json:"runMode"` // "" | "native" | "docker"
	Requirepass     string   `json:"requirepass"`
	ExtraFlags      []FlagKV `json:"extraFlags"`
}

// FlagKV is one extra redimos flag: a key (flag name) and its value.
type FlagKV struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

// Settings are process-wide: the paths to the two redimos binaries. A Config
// with Version "v1" launches RedimosV1Path; "v2" launches RedimosV2Path.
type Settings struct {
	RedimosV1Path string `json:"redimosV1Path"`
	RedimosV2Path string `json:"redimosV2Path"`
	// DynamoDbLocalDir overrides where the Java DynamoDBLocal package lives
	// (DynamoDBLocal.jar + DynamoDBLocal_lib). Empty = ~/.redimos/dynamodb-local,
	// auto-downloaded on first use.
	DynamoDbLocalDir string `json:"dynamoDbLocalDir"`
	// Docker images used when a config's RunMode is "docker". Empty falls back
	// to redimos-v1:local / redimos-v2:local.
	RedimosV1Image string `json:"redimosV1Image"`
	RedimosV2Image string `json:"redimosV2Image"`
}

type store struct {
	Configs  []Config       `json:"configs"`
	Settings Settings       `json:"settings"`
	LocalDdb LocalDdbConfig `json:"localDdb"`
}

// ---------------------------------------------------------------------------
// Runtime (non-persisted) instance state
// ---------------------------------------------------------------------------

const maxLogLines = 800

// Supervisor restart policy: exponential-ish backoff, capped, with a crash-loop
// guard so an always-crashing instance stops retrying instead of spinning forever.
var restartBackoff = []time.Duration{time.Second, 2 * time.Second, 5 * time.Second, 10 * time.Second, 30 * time.Second}

const crashLoopMax = 5                   // give up after this many failures ...
const crashLoopWindow = 30 * time.Second // ... within this window

type instance struct {
	mu      sync.Mutex
	cmd     *exec.Cmd
	pid     int
	port    int
	started time.Time
	status  string // "running" | "restarting" | "stopped" | "error" | "failed"
	exitMsg string
	logs    []string

	// Launch spec captured at user-start so the supervisor can re-run it verbatim.
	bin        string
	launchArgs []string
	launchEnv  []string
	container  string // docker container name when the child runs containerised ("" = plain process)

	// Supervisor state.
	autoRestart  bool
	intendedStop bool      // set by user Stop; suppresses auto-restart
	restarts     int       // successful supervised restarts so far
	failCount    int       // failures within the current crash-loop window
	failWindow   time.Time // start of the current crash-loop window

	// Monitoring (filled by the sampler loop).
	cpuPercent   float64       // % of all cores, Task-Manager style
	memBytes     uint64        // working set
	prevBusy     time.Duration // accumulated CPU time at the previous sample
	prevSampleAt time.Time

	// redimos /metrics scraping (filled by the scraper loop).
	metricsAddr  string    // resolved reachable host:port ("" until discovered)
	mtxOK        bool      // last scrape reached the endpoint
	mtxHealthy   bool      // /healthz == 200
	mtxReady     bool      // /readyz == 200
	opsPerSec    float64   // rate of redimos_commands_total across the last interval
	avgLatencyMs float64   // delta(duration_sum)/delta(duration_count) in ms
	throttled    int64     // redimos_dynamodb_throttled_total (cumulative)
	prevCmdTotal float64   // previous cumulative command count
	prevDurSum   float64   // previous cumulative duration sum (seconds)
	prevDurCount float64   // previous cumulative duration count
	prevMtxAt    time.Time // timestamp of the previous successful scrape
}

func (in *instance) appendLog(line string) {
	in.mu.Lock()
	defer in.mu.Unlock()
	in.logs = append(in.logs, line)
	if len(in.logs) > maxLogLines {
		in.logs = in.logs[len(in.logs)-maxLogLines:]
	}
}

func (in *instance) snapshotLogs() []string {
	in.mu.Lock()
	defer in.mu.Unlock()
	out := make([]string, len(in.logs))
	copy(out, in.logs)
	return out
}

// ---------------------------------------------------------------------------
// Manager singleton
// ---------------------------------------------------------------------------

type manager struct {
	mu        sync.Mutex
	st        store
	running   map[string]*instance
	storePath string
	ddb       *instance // the Local DynamoDB child (nil until first start)
}

var mgr = newManager()

func newManager() *manager {
	m := &manager{running: map[string]*instance{}, storePath: defaultStorePath()}
	m.load()
	go m.samplerLoop()
	go m.scraperLoop()
	return m
}

// samplerLoop refreshes per-child CPU/memory stats every 2s so rm_status stays
// a cheap cached read. Plain processes are sampled via the OS (procstats_*);
// containerised children via `docker stats`. A restarted child (new pid)
// resets its CPU baseline.
func (m *manager) samplerLoop() {
	numCPU := float64(runtime.NumCPU())
	t := time.NewTicker(2 * time.Second)
	for range t.C {
		m.mu.Lock()
		ins := make([]*instance, 0, len(m.running)+1)
		for _, in := range m.running {
			ins = append(ins, in)
		}
		if m.ddb != nil {
			ins = append(ins, m.ddb)
		}
		m.mu.Unlock()
		for _, in := range ins {
			in.mu.Lock()
			pid, running, cont := in.pid, in.status == "running", in.container
			in.mu.Unlock()
			if !running {
				continue
			}
			if cont != "" {
				cpu, mem, err := sampleContainer(in.bin, cont)
				if err == nil {
					in.mu.Lock()
					in.cpuPercent, in.memBytes = cpu/numCPU, mem
					in.mu.Unlock()
				}
				continue
			}
			if pid <= 0 {
				continue
			}
			busy, mem, err := sampleProcess(pid)
			now := time.Now()
			in.mu.Lock()
			if err != nil || in.pid != pid {
				in.mu.Unlock()
				continue
			}
			in.memBytes = mem
			if !in.prevSampleAt.IsZero() && busy >= in.prevBusy {
				wall := now.Sub(in.prevSampleAt)
				if wall > 0 {
					in.cpuPercent = float64(busy-in.prevBusy) / float64(wall) / numCPU * 100
				}
			}
			in.prevBusy = busy
			in.prevSampleAt = now
			in.mu.Unlock()
		}
	}
}

func defaultStorePath() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home, _ = os.Getwd()
	}
	dir := filepath.Join(home, ".redimos")
	_ = os.MkdirAll(dir, 0o755)
	return filepath.Join(dir, "store.json")
}

func (m *manager) load() {
	b, err := os.ReadFile(m.storePath)
	if err != nil {
		return // fresh install: empty store
	}
	_ = json.Unmarshal(b, &m.st)
}

func (m *manager) persist() error {
	b, err := json.MarshalIndent(m.st, "", "  ")
	if err != nil {
		return err
	}
	tmp := m.storePath + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, m.storePath)
}

func (m *manager) findConfig(id string) (*Config, int) {
	for i := range m.st.Configs {
		if m.st.Configs[i].ID == id {
			return &m.st.Configs[i], i
		}
	}
	return nil, -1
}

// ---------------------------------------------------------------------------
// Process lifecycle
// ---------------------------------------------------------------------------

func (m *manager) binaryFor(cfg *Config) (string, error) {
	var p string
	switch cfg.Version {
	case "v1":
		p = m.st.Settings.RedimosV1Path
	case "v2":
		p = m.st.Settings.RedimosV2Path
	default:
		return "", fmt.Errorf("config %q has unknown version %q (want v1 or v2)", cfg.Name, cfg.Version)
	}
	if strings.TrimSpace(p) == "" {
		return "", fmt.Errorf("no redimos %s binary path set (Settings)", cfg.Version)
	}
	if _, err := os.Stat(p); err != nil {
		return "", fmt.Errorf("redimos %s binary not found: %s", cfg.Version, p)
	}
	return p, nil
}

func (cfg *Config) args() []string { return cfg.argsFor(cfg.Endpoint, ":0") }

// argsFor builds the redimos CLI flags. endpoint and metricsDefault are
// parameters so the docker run-mode can rewrite the endpoint host (localhost ->
// host.docker.internal) and pin metrics to a known container port.
func (cfg *Config) argsFor(endpoint, metricsDefault string) []string {
	a := []string{"-addr", fmt.Sprintf(":%d", cfg.Port), "-table", cfg.Table}
	if strings.TrimSpace(endpoint) != "" {
		a = append(a, "-endpoint-url", endpoint)
	}
	if strings.TrimSpace(cfg.PartitionID) != "" {
		a = append(a, "-endpoint-partition-id", cfg.PartitionID)
	}
	if strings.TrimSpace(cfg.Region) != "" {
		a = append(a, "-region", cfg.Region)
	}
	if cfg.MultiDB {
		a = append(a, "-multi-db")
	}
	if cfg.AutoCreateTable {
		a = append(a, "-auto-create-table")
	}
	if strings.TrimSpace(cfg.Requirepass) != "" {
		a = append(a, "-requirepass", cfg.Requirepass)
	}
	userMetrics := false
	for _, f := range cfg.ExtraFlags {
		k := strings.TrimSpace(f.Key)
		if k == "" {
			continue
		}
		if !strings.HasPrefix(k, "-") {
			k = "-" + k
		}
		if k == "-metrics-addr" {
			userMetrics = true
		}
		a = append(a, k)
		if v := strings.TrimSpace(f.Value); v != "" {
			a = append(a, v)
		}
	}
	// Each instance exposes a Prometheus /metrics endpoint (default :9121). When
	// the manager runs several instances at once they would all fight over that
	// one port and every instance after the first would fail to start, so
	// auto-select a free port unless the user pinned one via an extra flag.
	if !userMetrics {
		a = append(a, "-metrics-addr", metricsDefault)
	}
	return a
}

func (m *manager) start(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if in, ok := m.running[id]; ok && in.status == "running" {
		return fmt.Errorf("already running (pid %d)", in.pid)
	}
	cfg, _ := m.findConfig(id)
	if cfg == nil {
		return fmt.Errorf("no config with id %s", id)
	}
	bin, args, env, container, err := m.buildLaunch(cfg)
	if err != nil {
		return err
	}

	// A fresh user-initiated start: new instance with restart counters reset.
	in := &instance{
		port:        cfg.Port,
		bin:         bin,
		launchArgs:  args,
		launchEnv:   env,
		container:   container,
		autoRestart: cfg.AutoRestart,
	}
	m.running[id] = in
	if err := in.spawn(); err != nil {
		in.mu.Lock()
		in.status = "error"
		in.exitMsg = err.Error()
		in.mu.Unlock()
		return fmt.Errorf("start failed: %w", err)
	}
	return nil
}

// awsCredEnv returns AWS_* env entries in "K=V" form for a config.
func (cfg *Config) awsCredEnv() []string {
	var e []string
	if cfg.AccessKeyID != "" {
		e = append(e, "AWS_ACCESS_KEY_ID="+cfg.AccessKeyID)
	}
	if cfg.SecretKey != "" {
		e = append(e, "AWS_SECRET_ACCESS_KEY="+cfg.SecretKey)
	}
	if cfg.SessionToken != "" {
		e = append(e, "AWS_SESSION_TOKEN="+cfg.SessionToken)
	}
	if cfg.Region != "" {
		e = append(e, "AWS_REGION="+cfg.Region, "AWS_DEFAULT_REGION="+cfg.Region)
	}
	// A local DynamoDB endpoint still needs *some* credentials for the SDK to
	// sign requests; supply harmless dummies when the user left them blank.
	if cfg.Endpoint != "" && cfg.AccessKeyID == "" {
		e = append(e, "AWS_ACCESS_KEY_ID=local", "AWS_SECRET_ACCESS_KEY=local")
	}
	return e
}

// buildLaunch resolves how to run a config: bin + args + env, and a container
// name when it runs in docker mode ("" for a plain process). Caller holds m.mu.
func (m *manager) buildLaunch(cfg *Config) (bin string, args []string, env []string, container string, err error) {
	if cfg.RunMode == "docker" {
		return m.buildDockerLaunch(cfg)
	}
	bin, err = m.binaryFor(cfg)
	if err != nil {
		return "", nil, nil, "", err
	}
	return bin, cfg.args(), append(os.Environ(), cfg.awsCredEnv()...), "", nil
}

// dockerLocalhostRewrite rewrites a localhost endpoint to host.docker.internal
// so a containerised redimos reaches services published on the host.
func dockerLocalhostRewrite(endpoint string) string {
	e := endpoint
	e = strings.ReplaceAll(e, "127.0.0.1", "host.docker.internal")
	e = strings.ReplaceAll(e, "localhost", "host.docker.internal")
	return e
}

// buildDockerLaunch produces a `docker run` command line for a redimos config.
// All container ports are published to the host: the RESP port 1:1, and the
// metrics port (:9121 inside) to an OS-chosen host port read back later via
// `docker port`. The DynamoDB endpoint's host is rewritten to
// host.docker.internal, and AWS creds are passed through as container env.
func (m *manager) buildDockerLaunch(cfg *Config) (string, []string, []string, string, error) {
	docker, ok := dockerBin()
	if !ok {
		return "", nil, nil, "", fmt.Errorf("docker not available (install Docker Desktop, or use Native run mode)")
	}
	var image string
	switch cfg.Version {
	case "v1":
		image = m.st.Settings.RedimosV1Image
	case "v2":
		image = m.st.Settings.RedimosV2Image
	default:
		return "", nil, nil, "", fmt.Errorf("config %q has unknown version %q", cfg.Name, cfg.Version)
	}
	if strings.TrimSpace(image) == "" {
		image = "redimos-" + cfg.Version + ":local"
	}
	cname := "redimos-mgr-" + cfg.ID

	run := []string{
		"run", "--rm", "--name", cname,
		"--add-host", "host.docker.internal:host-gateway",
		"-p", fmt.Sprintf("%d:%d", cfg.Port, cfg.Port),
		"-p", "127.0.0.1::9121",
	}
	for _, kv := range cfg.awsCredEnv() {
		run = append(run, "-e", kv)
	}
	run = append(run, image)
	run = append(run, cfg.argsFor(dockerLocalhostRewrite(cfg.Endpoint), ":9121")...)
	return docker, run, os.Environ(), cname, nil
}

// spawn launches (or re-launches) the child from the captured spec and wires up
// the log pumps plus the supervisor's exit watcher.
func (in *instance) spawn() error {
	if in.container != "" {
		// A containerised child runs through a foreground `docker run --rm --name X`
		// CLI, so the container may survive a dead CLI; clear any leftover first.
		_ = exec.Command(in.bin, "rm", "-f", in.container).Run()
	}
	cmd := exec.Command(in.bin, in.launchArgs...)
	cmd.Env = in.launchEnv
	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		return err
	}
	in.mu.Lock()
	in.cmd = cmd
	in.pid = cmd.Process.Pid
	in.started = time.Now()
	in.status = "running"
	in.prevBusy = 0
	in.prevSampleAt = time.Time{} // fresh pid → fresh CPU baseline
	in.cpuPercent = 0
	// Fresh listener → rediscover the metrics endpoint (docker maps a new host
	// port each run; native -metrics-addr :0 auto-picks a new port too).
	in.metricsAddr = ""
	in.mtxOK, in.mtxHealthy, in.mtxReady = false, false, false
	in.opsPerSec, in.avgLatencyMs, in.throttled = 0, 0, 0
	in.prevMtxAt = time.Time{}
	in.appendLogLocked(fmt.Sprintf("$ %s %s", in.bin, strings.Join(in.launchArgs, " ")))
	in.mu.Unlock()

	go pump(stdout, in)
	go pump(stderr, in)
	go func() { in.superviseExit(cmd.Wait()) }()
	return nil
}

// superviseExit runs when the child exits. On an unexpected exit it restarts the
// child (with backoff) when auto-restart is on, unless the user asked it to stop
// or it has crash-looped past the guard.
func (in *instance) superviseExit(werr error) {
	in.mu.Lock()
	if in.intendedStop {
		in.status = "stopped"
		in.appendLogLocked("[stopped]")
		in.mu.Unlock()
		return
	}
	if werr != nil {
		in.exitMsg = werr.Error()
		in.appendLogLocked("[process exited: " + werr.Error() + "]")
	} else {
		in.exitMsg = ""
		in.appendLogLocked("[process exited cleanly]")
	}
	if !in.autoRestart {
		in.status = "error"
		in.mu.Unlock()
		return
	}
	now := time.Now()
	if in.failWindow.IsZero() || now.Sub(in.failWindow) > crashLoopWindow {
		in.failCount = 0
		in.failWindow = now
	}
	in.failCount++
	if in.failCount >= crashLoopMax {
		in.status = "failed"
		in.appendLogLocked(fmt.Sprintf("[supervisor: gave up after %d exits within %s]", in.failCount, crashLoopWindow))
		in.mu.Unlock()
		return
	}
	backoff := restartBackoff[min(in.failCount-1, len(restartBackoff)-1)]
	in.status = "restarting"
	in.appendLogLocked(fmt.Sprintf("[supervisor: restart #%d in %s]", in.restarts+1, backoff))
	in.mu.Unlock()
	time.AfterFunc(backoff, in.doRestart)
}

// doRestart is invoked by the backoff timer to bring the child back up.
func (in *instance) doRestart() {
	in.mu.Lock()
	if in.intendedStop {
		in.status = "stopped"
		in.mu.Unlock()
		return
	}
	in.restarts++
	in.mu.Unlock()
	if err := in.spawn(); err != nil {
		in.superviseExit(err) // Start() itself failed — treat as another exit.
	}
}

func (in *instance) appendLogLocked(line string) {
	in.logs = append(in.logs, line)
	if len(in.logs) > maxLogLines {
		in.logs = in.logs[len(in.logs)-maxLogLines:]
	}
}

func pump(r interface{ Read([]byte) (int, error) }, in *instance) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		in.appendLog(sc.Text())
	}
}

func (m *manager) stop(id string) error {
	m.mu.Lock()
	in, ok := m.running[id]
	m.mu.Unlock()
	if !ok {
		return fmt.Errorf("not running")
	}
	in.terminate()
	return nil
}

// terminate stops a child for good: marks the stop as intended (suppressing the
// supervisor), removes the container for containerised children, and kills the
// process. Safe to call in any state.
func (in *instance) terminate() {
	in.mu.Lock()
	in.intendedStop = true
	proc := in.cmd
	cont := in.container
	bin := in.bin
	if in.status == "restarting" || in.status == "preparing" {
		in.status = "stopped" // no live process right now
	}
	in.mu.Unlock()
	if cont != "" {
		// Removing the container makes the foreground docker CLI exit on its own.
		_ = exec.Command(bin, "rm", "-f", cont).Run()
	} else if proc != nil && proc.Process != nil {
		_ = proc.Process.Kill()
	}
}

func (m *manager) stopAll() {
	m.mu.Lock()
	ids := make([]string, 0, len(m.running))
	for id := range m.running {
		ids = append(ids, id)
	}
	m.mu.Unlock()
	for _, id := range ids {
		_ = m.stop(id)
	}
}

type statusRow struct {
	ID          string  `json:"id"`
	Status      string  `json:"status"` // running|restarting|stopped|error|failed
	PID         int     `json:"pid"`
	Port        int     `json:"port"`
	UptimeSec   int64   `json:"uptimeSec"`
	ExitMsg     string  `json:"exitMsg"`
	Restarts    int     `json:"restarts"`
	AutoRestart bool    `json:"autoRestart"`
	CPUPercent  float64 `json:"cpuPercent"`
	MemBytes    int64   `json:"memBytes"`
	RunMode     string  `json:"runMode"` // "native" | "docker"

	// redimos /metrics-derived fields (zero/false until the first scrape).
	MetricsOK    bool    `json:"metricsOk"`    // scrape reached the endpoint
	Healthy      bool    `json:"healthy"`      // /healthz == 200
	Ready        bool    `json:"ready"`        // /readyz == 200
	OpsPerSec    float64 `json:"opsPerSec"`    // command rate over the last interval
	AvgLatencyMs float64 `json:"avgLatencyMs"` // average command latency (ms)
	Throttled    int64   `json:"throttled"`    // cumulative DynamoDB throttles
}

func (m *manager) statuses() []statusRow {
	m.mu.Lock()
	defer m.mu.Unlock()
	rows := make([]statusRow, 0, len(m.st.Configs))
	for _, cfg := range m.st.Configs {
		runMode := cfg.RunMode
		if runMode == "" {
			runMode = "native"
		}
		r := statusRow{ID: cfg.ID, Status: "stopped", Port: cfg.Port, AutoRestart: cfg.AutoRestart, RunMode: runMode}
		if in, ok := m.running[cfg.ID]; ok {
			in.mu.Lock()
			r.Status = in.status
			r.PID = in.pid
			r.Port = in.port
			r.ExitMsg = in.exitMsg
			r.Restarts = in.restarts
			r.AutoRestart = in.autoRestart
			if in.container != "" {
				r.RunMode = "docker"
			}
			if in.status == "running" {
				r.UptimeSec = int64(time.Since(in.started).Seconds())
				r.CPUPercent = in.cpuPercent
				r.MemBytes = int64(in.memBytes)
				r.MetricsOK = in.mtxOK
				r.Healthy = in.mtxHealthy
				r.Ready = in.mtxReady
				r.OpsPerSec = in.opsPerSec
				r.AvgLatencyMs = in.avgLatencyMs
				r.Throttled = in.throttled
			}
			in.mu.Unlock()
		}
		rows = append(rows, r)
	}
	return rows
}

func newID() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// ---------------------------------------------------------------------------
// FFI helpers
// ---------------------------------------------------------------------------

func okJSON(extra map[string]any) *C.char {
	m := map[string]any{"ok": true}
	for k, v := range extra {
		m[k] = v
	}
	return cjson(m)
}

func errJSON(err error) *C.char {
	return cjson(map[string]any{"ok": false, "error": err.Error()})
}

func cjson(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		return C.CString(`{"ok":false,"error":"marshal failed"}`)
	}
	return C.CString(string(b))
}

// ---------------------------------------------------------------------------
// Exported C ABI
// ---------------------------------------------------------------------------

//export rm_version
func rm_version() *C.char { return C.CString("redimos-manager-core 0.1.0") }

//export rm_free
func rm_free(p *C.char) { C.free(unsafe.Pointer(p)) }

//export rm_load
func rm_load() *C.char {
	mgr.mu.Lock()
	defer mgr.mu.Unlock()
	return cjson(mgr.st)
}

//export rm_save_config
func rm_save_config(in *C.char) *C.char {
	var cfg Config
	if err := json.Unmarshal([]byte(C.GoString(in)), &cfg); err != nil {
		return errJSON(err)
	}
	if strings.TrimSpace(cfg.Name) == "" {
		return errJSON(fmt.Errorf("name is required"))
	}
	if cfg.Version != "v1" && cfg.Version != "v2" {
		return errJSON(fmt.Errorf("version must be v1 or v2"))
	}
	if cfg.Port <= 0 || cfg.Port > 65535 {
		return errJSON(fmt.Errorf("port must be 1..65535"))
	}
	mgr.mu.Lock()
	if cfg.ID == "" {
		cfg.ID = newID()
		mgr.st.Configs = append(mgr.st.Configs, cfg)
	} else if _, idx := mgr.findConfig(cfg.ID); idx >= 0 {
		mgr.st.Configs[idx] = cfg
	} else {
		mgr.st.Configs = append(mgr.st.Configs, cfg)
	}
	err := mgr.persist()
	mgr.mu.Unlock()
	if err != nil {
		return errJSON(err)
	}
	return okJSON(map[string]any{"id": cfg.ID})
}

//export rm_delete_config
func rm_delete_config(in *C.char) *C.char {
	id := C.GoString(in)
	_ = mgr.stop(id)
	mgr.mu.Lock()
	_, idx := mgr.findConfig(id)
	if idx >= 0 {
		mgr.st.Configs = append(mgr.st.Configs[:idx], mgr.st.Configs[idx+1:]...)
	}
	delete(mgr.running, id)
	err := mgr.persist()
	mgr.mu.Unlock()
	if err != nil {
		return errJSON(err)
	}
	return okJSON(nil)
}

//export rm_set_settings
func rm_set_settings(in *C.char) *C.char {
	var s Settings
	if err := json.Unmarshal([]byte(C.GoString(in)), &s); err != nil {
		return errJSON(err)
	}
	mgr.mu.Lock()
	mgr.st.Settings = s
	err := mgr.persist()
	mgr.mu.Unlock()
	if err != nil {
		return errJSON(err)
	}
	return okJSON(nil)
}

//export rm_start
func rm_start(in *C.char) *C.char {
	if err := mgr.start(C.GoString(in)); err != nil {
		return errJSON(err)
	}
	return okJSON(nil)
}

//export rm_stop
func rm_stop(in *C.char) *C.char {
	if err := mgr.stop(C.GoString(in)); err != nil {
		return errJSON(err)
	}
	return okJSON(nil)
}

//export rm_stop_all
func rm_stop_all() *C.char {
	mgr.stopAll()
	return okJSON(nil)
}

//export rm_status
func rm_status() *C.char { return cjson(mgr.statuses()) }

//export rm_logs
func rm_logs(in *C.char) *C.char {
	id := C.GoString(in)
	mgr.mu.Lock()
	in2, ok := mgr.running[id]
	mgr.mu.Unlock()
	if !ok {
		return cjson(map[string]any{"lines": []string{}})
	}
	return cjson(map[string]any{"lines": in2.snapshotLogs()})
}
