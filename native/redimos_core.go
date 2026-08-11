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

// Formatter is a user-defined value formatter for the Browser's format dropdown:
// an external program (Command) invoked with Params (an argv template in which
// {VALUE}/{HEX}/{KEY}/… are substituted — see rm_format_custom). Name is the
// dropdown label and the unique id.
type Formatter struct {
	Name    string `json:"name"`
	Command string `json:"command"`
	Params  string `json:"params"`
}

type store struct {
	Configs  []Config `json:"configs"`
	Settings Settings `json:"settings"`
	// LocalDdb/DdbAutoStart are the legacy single-instance Local DynamoDB
	// fields. They are no longer read from or written to disk — the Service
	// collection is the only source of truth for local servers — and the
	// in-memory copies exist only until the legacy rm_ddb_* call chain is
	// removed.
	LocalDdb LocalDdbConfig `json:"localDdb"`
	// Custom value formatters for the Browser (persisted independently of
	// Settings so the settings page can't clobber them).
	Formatters []Formatter `json:"formatters"`
	// Session restore: the "desired running" set, updated live on start/stop, so
	// the next launch relaunches exactly what was running last time (survives a
	// clean quit AND a crash). See autoStartAll.
	AutoStart    []string `json:"autoStart"`    // config IDs to relaunch on boot
	DdbAutoStart bool     `json:"ddbAutoStart"` // legacy; no longer persisted
	// The configs that were running when the user last hit the AppBar "Stop all",
	// persisted so the green "restore" affordance survives an app restart.
	StopAllSnapshot []string `json:"stopAllSnapshot"`
	// First-class local DynamoDB servers (Services), keyed by immutable ID.
	// Supersedes the legacy LocalDdb singleton.
	Services []ServiceConfig `json:"services"`
	// Typed Stop All snapshot (Instance + Service ID namespaces); supersedes
	// StopAllSnapshot. The legacy array is migrated read-only on load.
	StopAllSnapshotV2 GlobalStopSnapshot `json:"stopAllSnapshotV2"`
}

// ---------------------------------------------------------------------------
// Runtime (non-persisted) instance state
// ---------------------------------------------------------------------------

const maxLogLines = 800

// Supervisor restart policy: exponential-ish backoff, capped, with a crash-loop
// guard so an always-crashing instance stops retrying instead of spinning forever.
var restartBackoff = []time.Duration{time.Second, 2 * time.Second, 5 * time.Second, 10 * time.Second, 30 * time.Second}

const crashLoopMax = 5                 // give up after this many consecutive early exits
const healthyUptime = 20 * time.Second // a child that stays up this long counts as "started OK"

type instance struct {
	mu         sync.Mutex
	cmd        *exec.Cmd
	pid        int
	startMicro int64 // process start-time identity of pid (0 = docker/unknown)
	port       int
	role       string // registry key: "config:<id>" | "ddb" | "service:<id>"
	started    time.Time
	status     string // "running" | "restarting" | "stopped" | "error" | "failed"
	exitMsg    string
	// failReason is the real cause of a startup/early failure (redimos's own fatal
	// line, e.g. the backend startup check), set only on an errored early exit and
	// cleared on a clean/healthy exit or a successful start — so benign lifecycle
	// lines ("shutdown complete", "connection closed") are never shown as the cause.
	failReason string
	logs       []string

	// Launch spec captured at user-start so the supervisor can re-run it verbatim.
	bin        string
	launchArgs []string
	launchEnv  []string
	wd         string // working directory for the child ("" = inherit manager's)
	container  string // docker container name when the child runs containerised ("" = plain process)

	// Lifetime policy. A detached child deliberately SURVIVES manager death so
	// the next session can adopt it (the stateful Local DynamoDB — its in-memory
	// tables are the user's dev data); everything else is lifetime-bound to the
	// manager (Windows: job object kill-on-close; macOS: janitor).
	detached bool
	adopted  bool    // inherited from a previous session (no cmd handle; watcher-supervised)
	job      uintptr // windows: KILL_ON_JOB_CLOSE job handle (0 = none / darwin)

	// Supervisor state.
	autoRestart  bool
	intendedStop bool        // set by user Stop; suppresses auto-restart
	restarts     int         // successful supervised restarts so far
	failCount    int         // consecutive early exits (never stayed up healthyUptime)
	restartTimer *time.Timer // pending backoff timer; cancelled by terminate()

	// superviseWG counts the live supervise goroutines for this child (one per
	// spawn generation; a restart arms a fresh one; an adopted child counts its
	// exit watcher instead). Tests join it so teardown never races the
	// terminal-exit bookkeeping (registry removal etc.).
	superviseWG sync.WaitGroup

	// Monitoring (filled by the sampler loop).
	cpuPercent   float64       // % of all cores, Task-Manager style
	memBytes     uint64        // working set
	diskPerSec   float64       // disk I/O bytes/sec (read+written), rate over the interval
	prevBusy     time.Duration // accumulated CPU time at the previous sample
	prevDisk     uint64        // cumulative disk bytes at the previous sample
	prevSampleAt time.Time

	// redimos /metrics scraping (filled by the scraper loop).
	metricsAddr string // resolved reachable host:port ("" until discovered)
	mtxOK       bool   // last scrape reached the endpoint
	mtxHealthy  bool   // /healthz == 200
	mtxReady    bool   // /readyz == 200
	// backendError is redimos's own reported cause for a failing backend check,
	// read from the /readyz body. Empty whenever redimos does not report one — a
	// ready proxy, an unreachable endpoint, or a redimos too old to carry the field
	// — so a consumer must treat "" as "no cause known" and say only what the
	// healthy/ready signals prove, never as "no problem".
	backendError string
	opsPerSec    float64   // rate of redimos_commands_total across the last interval
	avgLatencyMs float64   // delta(duration_sum)/delta(duration_count) in ms
	throttled    int64     // redimos_dynamodb_throttled_total (cumulative)
	prevCmdTotal float64   // previous cumulative command count
	prevDurSum   float64   // previous cumulative duration sum (seconds)
	prevDurCount float64   // previous cumulative duration count
	prevMtxAt    time.Time // timestamp of the previous successful scrape

	// Local DynamoDB latency probe (filled by the ddb probe in scraperLoop; role "ddb" only).
	ddbProbeOK   bool
	ddbLatencyMs float64
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

	sessionID string   // one id per manager run; tags children (env / -D / docker label)
	lockFile  *os.File // machine-wide single-instance lock, held for the process lifetime
	lockErr   error    // non-nil when another instance already holds the lock

	// One-shot "-auto-create-table" injection consumed by the next buildLaunch of
	// that config id — used by table recreate so redimos rebuilds the table on
	// restart regardless of the config's persisted AutoCreate setting. Guarded by mu.
	forceAC map[string]bool

	// Diagnostics from decoding the persisted services collection (corrupt or
	// conflicting entries skipped at load). Written once during load — before
	// this manager is published as mgr — and read-only afterwards.
	serviceLoadErrors []string

	// One-time notice set at boot when a legacy pre-1.2 singleton Local
	// DynamoDB child was stopped instead of adopted (7.9). Guarded by mu;
	// surfaced to the UI through the ABI (stage 9).
	legacyDdbMigrationNotice string

	// Multi-Service runtime registry, keyed by immutable Service ID. See
	// service_runtime.go for the lock discipline (svcMu guards membership only;
	// per-Service opMu serializes lifecycle ops without touching this lock).
	svcMu sync.Mutex
	svc   map[string]*serviceRuntime

	// Auto-start (recovery) failures recorded by svcAutoStartAll, one entry per
	// affected Service. Guarded by mu; surfaced through rm_services' errors[]
	// (7.6, stage 9).
	svcRecoveryErrs []string
}

// mgr is populated by init() (a var initializer would reject the newManager →
// reconcileOnBoot → superviseExit → spawn back-edge as an init cycle).
var mgr *manager

func init() { newManager() }

func newManager() *manager {
	m := &manager{running: map[string]*instance{}, storePath: defaultStorePath(), sessionID: newID()}
	// Publish the global BEFORE anything that can transitively dereference it:
	// spawn() reads mgr.sessionID, and reconcileOnBoot arms watcher / docker-wait
	// goroutines whose exit callbacks reach doRestart → spawn. Goroutine creation
	// and the synchronous reconcile both happen-after this store, so no reader
	// can observe a nil mgr.
	mgr = m
	m.load()
	if f, err := acquireInstanceLock(); err != nil {
		// A sibling instance is live. Its children are healthy and supervised —
		// no sweeps, no starts; rm_load surfaces the error to the UI.
		m.lockErr = err
	} else {
		m.lockFile = f
		// The SIGKILL-proof prevention layer (darwin): children registered with
		// the janitor die within milliseconds of the manager, however it dies.
		// Started first so boot adoption can register adopted containers.
		startJanitor()
		// A fresh session inherits no live process handles: anything still
		// running from a previous session is either adopted (the stateful DDB /
		// matching docker children) or an orphan we kill. Resolve at boot: first
		// the registry (exact identity), then the legacy heuristic sweep as
		// backstop. Containers are swept async — docker probing can take seconds
		// and this runs during dylib load — sparing what adoption claimed.
		adopted := m.reconcileOnBoot()
		m.reapStartupOrphans()
		go m.sweepLabeledContainers(adopted)
		// Session restore: relaunch whatever was running last time but didn't
		// survive as an adopted child. Async so it never blocks dylib load.
		go m.autoStartAll()
		// Service restore runs AFTER the reconcile claim pass (adoption above):
		// every desiredRunning Service not adopted starts independently, and
		// one Service's failure never blocks another.
		go m.svcAutoStartAll()
	}
	go m.samplerLoop()
	go m.scraperLoop()
	go m.probeDdbLoop()
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
				cpu, mem, disk, err := sampleContainer(in.bin, cont)
				now := time.Now()
				if err == nil {
					in.mu.Lock()
					in.cpuPercent, in.memBytes = cpu/numCPU, mem
					if !in.prevSampleAt.IsZero() && disk >= in.prevDisk {
						if wall := now.Sub(in.prevSampleAt).Seconds(); wall > 0 {
							in.diskPerSec = float64(disk-in.prevDisk) / wall
						}
					}
					in.prevDisk = disk
					in.prevSampleAt = now
					in.mu.Unlock()
				}
				continue
			}
			if pid <= 0 {
				continue
			}
			busy, mem, disk, err := sampleProcess(pid)
			now := time.Now()
			in.mu.Lock()
			if err != nil || in.pid != pid {
				in.mu.Unlock()
				continue
			}
			in.memBytes = mem
			if !in.prevSampleAt.IsZero() {
				wall := now.Sub(in.prevSampleAt)
				if busy >= in.prevBusy && wall > 0 {
					in.cpuPercent = float64(busy-in.prevBusy) / float64(wall) / numCPU * 100
				}
				if disk >= in.prevDisk && wall > 0 {
					in.diskPerSec = float64(disk-in.prevDisk) / wall.Seconds()
				}
			}
			in.prevBusy = busy
			in.prevDisk = disk
			in.prevSampleAt = now
			in.mu.Unlock()
		}
	}
}

func defaultStorePath() string {
	// REDIMOS_STORE_PATH relocates ALL on-disk state (store, registry, instance
	// lock, managed Service data) — used by the C ABI smoke test so it never
	// touches the live ~/.redimos state. Empty/unset keeps the default.
	if p := os.Getenv("REDIMOS_STORE_PATH"); p != "" {
		return p
	}
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
	var d diskStore
	if json.Unmarshal(b, &d) != nil {
		return
	}
	m.st.Settings = d.Settings
	m.st.Formatters = d.Formatters
	m.st.AutoStart = d.AutoStart
	m.st.StopAllSnapshot = d.StopAllSnapshot
	// Legacy singleton fields (localDdb / ddbAutoStart) are intentionally NOT
	// decoded: the Service collection is the sole source of truth for local
	// servers, and legacy lifecycle state is never combined with it.
	//
	// Typed Stop All snapshot: prefer the new key; read-only migrate the legacy
	// string array (Instance IDs only) when the new key is absent, so no
	// snapshot data is discarded by the upgrade.
	if d.StopAllSnapshotV2 != nil {
		m.st.StopAllSnapshotV2 = *d.StopAllSnapshotV2
	} else if len(d.StopAllSnapshot) > 0 {
		m.st.StopAllSnapshotV2 = GlobalStopSnapshot{
			Instances: append([]string(nil), d.StopAllSnapshot...),
		}
	}
	// Prefer the split form; fall back to a legacy pre-1.2 configs[] (rewritten
	// in the new shape on the next persist).
	if len(d.Instances) > 0 || len(d.Endpoints) > 0 {
		m.st.Configs = mergeToConfigs(d.Endpoints, d.Instances)
	} else {
		m.st.Configs = d.Configs
	}
	// Services decode independently of the entities above: a corrupt services
	// collection must not wipe endpoints/instances/settings.
	m.st.Services, m.serviceLoadErrors = decodeServices(b)
	// Every loaded Service gets its runtime carrier so lifecycle ops can find
	// it by ID; process state itself is rebuilt by reconcile/adoption.
	for i := range m.st.Services {
		m.svcEnsureRuntime(m.st.Services[i].ID)
	}
}

func (m *manager) persist() error {
	eps, insts := splitConfigs(m.st.Configs)
	d := diskStore{
		Endpoints: eps,
		Instances: insts,
		// Legacy mirror: keep configs[] so a downgrade to a pre-1.2 build still
		// sees the configs. load() prefers endpoints/instances when present; an
		// old build overwrites the whole file with configs[] only, after which a
		// new build falls back to configs[] cleanly.
		Configs:         m.st.Configs,
		Settings:        m.st.Settings,
		Formatters:      m.st.Formatters,
		AutoStart:       m.st.AutoStart,
		StopAllSnapshot: m.st.StopAllSnapshot,
	}
	// The legacy singleton fields (localDdb / ddbAutoStart) are never written.
	if !m.st.StopAllSnapshotV2.empty() {
		snap := m.st.StopAllSnapshotV2
		d.StopAllSnapshotV2 = &snap
	}
	// The services collection rides alongside diskStore but is declared here,
	// not on diskStore, so a corrupt services array can never break the decode
	// of the other entities.
	out := struct {
		diskStore
		Services []ServiceConfig `json:"services,omitempty"`
	}{diskStore: d, Services: m.st.Services}
	b, err := json.MarshalIndent(out, "", "  ")
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
		// No explicit path configured: auto-detect the bundled binary in a
		// bin/ dir next to the manager's own executable (the release packages
		// ship redimos-v1(.exe) / redimos-v2(.exe) there — see
		// scripts/build-windows-prep.sh). Falls back to the plain name on
		// non-Windows so macOS/Linux unpackaged runs work too.
		if d := detectBundledBinary(cfg.Version); d != "" {
			return d, nil
		}
		return "", fmt.Errorf("no redimos %s binary path set (Settings); also not found at bin/redimos-%s(.exe) next to the app", cfg.Version, cfg.Version)
	}
	if _, err := os.Stat(p); err != nil {
		return "", fmt.Errorf("redimos %s binary not found: %s", cfg.Version, p)
	}
	return p, nil
}

// detectBundledBinary returns the absolute path of bin/redimos-<version>[.exe]
// sitting next to the current executable, or "" if not present.
func detectBundledBinary(version string) string {
	exe, err := os.Executable()
	if err != nil || exe == "" {
		return ""
	}
	// Resolve symlinks so the bin/ lookup anchors to the real binary location.
	if r, err := filepath.EvalSymlinks(exe); err == nil {
		exe = r
	}
	return findBundledBinary(filepath.Dir(exe), version)
}

// findBundledBinary looks for bin/redimos-<version>[.exe] under dir. Split out
// from detectBundledBinary so tests can point it at a temp dir.
func findBundledBinary(dir, version string) string {
	base := filepath.Join(dir, "bin", "redimos-"+version)
	name := base
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	if _, err := os.Stat(name); err == nil {
		return name
	}
	// Cross-platform convenience: accept the extensionless name too.
	if _, err := os.Stat(base); err == nil {
		return base
	}
	return ""
}

func (cfg *Config) args() []string { return cfg.argsFor(cfg.Endpoint, ":0") }

// argsFor builds the redimos CLI flags. endpoint and metricsDefault are
// parameters so the docker run-mode can rewrite the endpoint host (localhost ->
// host.docker.internal) and pin metrics to a known container port.
func (cfg *Config) argsFor(endpoint, metricsDefault string) []string {
	a := []string{"-addr", fmt.Sprintf(":%d", cfg.Port), "-table", cfg.Table}
	if strings.TrimSpace(endpoint) != "" {
		a = append(a, "-endpoint-url", endpoint)
		// The partition id only makes sense alongside a custom endpoint URL (a local
		// DynamoDB). In AWS mode (empty endpoint) it must NOT be passed: redimos
		// installs its custom endpoint resolver when EITHER -endpoint-url OR
		// -endpoint-partition-id is set (assembly.go: endpointSet), and a resolver
		// that returns an empty URL shadows the SDK's default AWS endpoint — every
		// request then goes to "" ("unsupported protocol scheme"), the startup
		// backend check fails, and the process crash-loops. So gate it on endpoint.
		if strings.TrimSpace(cfg.PartitionID) != "" {
			a = append(a, "-endpoint-partition-id", cfg.PartitionID)
		}
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

	if m.lockErr != nil {
		return m.lockErr // a sibling instance owns the children; don't fight it
	}
	if in, ok := m.running[id]; ok {
		in.mu.Lock()
		st, pid := in.status, in.pid
		in.mu.Unlock()
		// Reject any non-terminal state (read under in.mu — status is mutated by
		// the supervisor/watcher goroutines). "restarting" matters most: its
		// armed backoff timer would otherwise spawn a phantom child into the map
		// entry we're about to overwrite, and that phantom would hold the port.
		if st == "running" || st == "restarting" || st == "preparing" {
			return fmt.Errorf("already %s (pid %d) — stop it first", st, pid)
		}
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
		role:        "config:" + cfg.ID,
		bin:         bin,
		launchArgs:  args,
		launchEnv:   env,
		container:   container,
		autoRestart: cfg.AutoRestart,
	}
	m.running[id] = in
	// A native redimos we started in a prior session may have outlived an
	// ungraceful app exit and still hold this port; reap our own straggler so the
	// fresh child can bind instead of crash-looping on "address already in use".
	// Only matches our own binary path, so a real Redis on the same port is safe.
	if container == "" {
		reapStalePort(cfg.Port, bin, m.livePidsLocked()) // spare our own live children
	}
	if err := in.spawn(); err != nil {
		in.mu.Lock()
		in.status = "error"
		in.exitMsg = err.Error()
		in.mu.Unlock()
		return fmt.Errorf("start failed: %w", err)
	}
	m.setConfigAutoStartLocked(id, true) // remember for next-launch restore (holds m.mu)
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
		bin, args, env, container, err = m.buildDockerLaunch(cfg)
		if err == nil {
			args = m.applyForceAutoCreate(cfg, args)
		}
		return bin, args, env, container, err
	}
	bin, err = m.binaryFor(cfg)
	if err != nil {
		return "", nil, nil, "", err
	}
	args = m.applyForceAutoCreate(cfg, cfg.args())
	return bin, args, append(os.Environ(), cfg.awsCredEnv()...), "", nil
}

// applyForceAutoCreate consumes a one-shot auto-create injection (set by a table
// recreate) for EITHER run mode, appending -auto-create-table unless the config
// already carries it. Caller holds m.mu. Docker mode previously dropped this,
// which left a recreated table uncreated for an AutoCreate=Off docker config.
func (m *manager) applyForceAutoCreate(cfg *Config, args []string) []string {
	if m.forceAC[cfg.ID] {
		delete(m.forceAC, cfg.ID)
		if !cfg.AutoCreateTable {
			args = append(args, "-auto-create-table")
		}
	}
	return args
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
		// Session-tagged labels: the boot sweep finds leftover containers from
		// dead sessions by label (host `ps` can't see containers at all).
		"--label", "redimos.manager=1",
		"--label", "redimos.manager.session=" + m.sessionID,
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
		rmCmd := exec.Command(in.bin, "rm", "-f", in.container)
		hideWindow(rmCmd)
		_ = rmCmd.Run()
	}
	cmd := exec.Command(in.bin, in.launchArgs...)
	if in.wd != "" {
		cmd.Dir = in.wd
	}
	// Sentinel env marker: identifies the child as ours to `ps -E`-style
	// inspection even when the registry is lost (docker CLI children carry it
	// too, though the container itself is identified by label instead).
	cmd.Env = append(append([]string{}, in.launchEnv...), "REDIMOS_MANAGER_SESSION="+mgr.sessionID)
	preSpawn(cmd) // per-OS: own process group (darwin) / job containment (windows)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("stdout pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("stderr pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	postSpawn(in, cmd)
	in.mu.Lock()
	if in.intendedStop {
		// terminate() interleaved between doRestart's intendedStop check and our
		// Start: the user asked for a stop, so put the fresh child straight down
		// instead of letting it outlive the request (or the app).
		in.status = "stopped"
		cont := in.container
		in.mu.Unlock()
		killChildTree(cmd.Process.Pid)
		if cont != "" {
			// The killed process is only the `docker run` CLI; remove the
			// container it may have spawned, matching terminate()'s docker path.
			rmCmd := exec.Command(in.bin, "rm", "-f", cont)
			hideWindow(rmCmd)
			_ = rmCmd.Run()
		}
		go func() { _ = cmd.Wait() }() // reap; no supervision for a child we just killed
		return nil
	}
	in.cmd = cmd
	in.pid = cmd.Process.Pid
	in.started = time.Now()
	in.status = "running"
	in.failReason = "" // fresh start — drop any prior early-failure cause
	in.adopted = false // a (re)spawned child is fully ours again
	in.prevBusy = 0
	in.prevDisk = 0
	in.prevSampleAt = time.Time{} // fresh pid → fresh CPU / disk baseline
	in.cpuPercent = 0
	in.diskPerSec = 0
	// Fresh listener → rediscover the metrics endpoint (docker maps a new host
	// port each run; native -metrics-addr :0 auto-picks a new port too).
	in.metricsAddr = ""
	in.mtxOK, in.mtxHealthy, in.mtxReady = false, false, false
	in.backendError = "" // fresh child — the old one's backend cause is not ours
	in.opsPerSec, in.avgLatencyMs, in.throttled = 0, 0, 0
	in.prevMtxAt = time.Time{}
	// Fresh child → drop the dead process's round-trip time; without this a
	// restarted Local DynamoDB reports the previous child's RTT until the next probe.
	in.ddbProbeOK, in.ddbLatencyMs = false, 0
	in.appendLogLocked(fmt.Sprintf("$ %s %s", in.bin, strings.Join(in.launchArgs, " ")))
	// Record the child's start-time identity so terminate() can re-verify the pid
	// hasn't been reaped-and-recycled before it signals.
	start, comm, idOK := procIdentity(cmd.Process.Pid)
	in.startMicro = start
	role, cont, port, bin, detached := in.role, in.container, in.port, in.bin, in.detached
	in.mu.Unlock()

	// Record the child in the persisted registry with its exact identity so the
	// next session's boot reconciler can tell it apart from strangers.
	if idOK {
		regUpsert(childRec{
			Role: role, PID: cmd.Process.Pid, StartUnixMicro: start, Comm: comm,
			Port: port, Container: cont, Bin: bin, Session: mgr.sessionID,
		})
	}
	// Lifetime binding (darwin): the janitor kills this child when we die.
	janitorRegister(detached, cmd.Process.Pid, bin, cont)

	go pump(stdout, in)
	go pump(stderr, in)
	in.superviseWG.Add(1)
	go func(started time.Time) {
		defer in.superviseWG.Done()
		in.superviseExit(cmd.Wait(), time.Since(started))
	}(in.started)
	return nil
}

// crashGuard decides the supervisor's response to a child exit. ranFor is how long
// the child stayed up before exiting; failCount is the running count of consecutive
// EARLY exits so far (before this one). A child that stayed up past healthyUptime
// started successfully, so a later exit is a fresh incident — the counter resets and
// it is restarted. A child that exits sooner never got healthy (e.g. a failing
// startup backend check that crash-loops), so it is counted, and after crashLoopMax
// such early exits the supervisor gives up.
//
// This is uptime-based on purpose. A wall-clock "N exits within a 30s window" guard
// is defeated by the growing backoff: once the delay reaches 10s/30s the exits spread
// out until no five ever land inside one window, so the child would restart forever.
func crashGuard(failCount int, ranFor time.Duration) (count int, giveUp bool, backoff time.Duration) {
	if ranFor >= healthyUptime {
		failCount = 0
	}
	failCount++
	if failCount >= crashLoopMax {
		return failCount, true, 0
	}
	return failCount, false, restartBackoff[min(failCount-1, len(restartBackoff)-1)]
}

// lastRedimosError returns redimos's startup-failure cause from the log tail, or ""
// if none is present. It matches ONLY redimos's distinct fatal marker
// ("redimos: cannot start: …" — its sole log.Fatalf, emitted just before it exits
// without ever serving), NOT the bare "redimos: " prefix that every benign lifecycle
// line ("connection … closed", "metrics …", "shutdown …") also carries. So when the
// real cause is not a redimos-logged startup fatal (an external kill, or a spawn that
// never ran), this returns "" and the caller falls back to the OS error instead of a
// misleading benign line.
func lastRedimosError(logs []string) string {
	const marker = "redimos: cannot start: "
	for i := len(logs) - 1; i >= 0; i-- {
		// Stop at the current incarnation's launch line ("$ <bin> …", written by
		// spawn) — the log buffer is NOT cleared across restarts, so without this a
		// stale marker from a prior failed start would be wrongly attributed to an
		// exit (e.g. an external kill) of a later incarnation that started cleanly.
		if strings.HasPrefix(logs[i], "$ ") {
			break
		}
		if idx := strings.Index(logs[i], marker); idx >= 0 {
			return strings.TrimSpace(logs[i][idx+len(marker):])
		}
	}
	return ""
}

// superviseExit runs when the child exits. On an unexpected exit it restarts the
// child (with backoff) when auto-restart is on, unless the user asked it to stop
// or it has crash-looped past the guard.
func (in *instance) superviseExit(werr error, ranFor time.Duration) {
	in.mu.Lock()
	if in.intendedStop {
		in.status = "stopped"
		in.appendLogLocked("[stopped]")
		role, pid, cont := in.role, in.pid, in.container
		in.mu.Unlock()
		regRemove(role) // terminal: nothing left to reconcile at next boot
		janitorUnregister(pid, cont)
		releaseInstance(in) // windows: close the job handle
		return
	}
	if werr != nil {
		in.exitMsg = werr.Error()
		in.appendLogLocked("[process exited: " + werr.Error() + "]")
	} else {
		in.exitMsg = ""
		in.appendLogLocked("[process exited cleanly]")
	}
	// Record the cause only for an errored EARLY exit — a genuine startup failure,
	// where redimos exits via log.Fatalf before it ever serves, so its own fatal
	// line is reliably the last "redimos:" line. A clean exit (werr==nil) or a
	// healthy-then-exited child (ranFor>=healthyUptime) is NOT a startup failure, so
	// clear the cause: otherwise benign lifecycle lines ("shutdown complete",
	// "connection … closed") would be surfaced as a misleading failure reason.
	if werr != nil && ranFor < healthyUptime {
		if r := lastRedimosError(in.logs); r != "" {
			in.failReason = r
		} else {
			in.failReason = werr.Error()
		}
	} else {
		in.failReason = ""
	}
	if !in.autoRestart {
		in.status = "error"
		role, pid, cont := in.role, in.pid, in.container
		in.mu.Unlock()
		regRemove(role)
		janitorUnregister(pid, cont)
		releaseInstance(in)
		return
	}
	var giveUp bool
	var backoff time.Duration
	in.failCount, giveUp, backoff = crashGuard(in.failCount, ranFor)
	if giveUp {
		in.status = "failed"
		// Surface WHY: the recorded startup-failure cause beats a bare "exit status 1".
		if in.failReason != "" {
			in.exitMsg = in.failReason
		}
		in.appendLogLocked(fmt.Sprintf("[supervisor: gave up after %d early exits (never stayed up %s)]", in.failCount, healthyUptime))
		role, pid, cont := in.role, in.pid, in.container
		in.mu.Unlock()
		regRemove(role)
		janitorUnregister(pid, cont)
		releaseInstance(in)
		return
	}
	in.status = "restarting"
	in.appendLogLocked(fmt.Sprintf("[supervisor: restart #%d in %s]", in.restarts+1, backoff))
	in.restartTimer = time.AfterFunc(backoff, in.doRestart) // terminate() cancels this
	pid, cont := in.pid, in.container
	in.mu.Unlock()
	janitorUnregister(pid, cont) // the dead child's entry; respawn re-registers
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
		// Start() itself failed — the child never ran, so ranFor is 0 (an early
		// failure that must count toward the crash-loop guard; using the stale
		// in.started would keep resetting the counter and loop forever).
		in.superviseExit(err, 0)
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
	// NB: the restore-set is NOT cleared here — stop() is also the shutdown path
	// (stopAll → stop), and a clean quit must keep what was running so it can be
	// restored. Only a USER stop (rm_stop / rm_ddb_stop) clears the flag.
	in.terminate()
	return nil
}

// terminate stops a child for good: marks the stop as intended (suppressing the
// supervisor), cancels any pending backoff restart, removes the container for
// containerised children, and gracefully kills the process tree (TERM → grace →
// KILL on the child's own process group). Safe to call in any state.
func (in *instance) terminate() {
	in.mu.Lock()
	in.intendedStop = true
	if in.restartTimer != nil {
		in.restartTimer.Stop()
		in.restartTimer = nil
	}
	pid := in.pid
	startMicro := in.startMicro
	cont := in.container
	bin := in.bin
	role := in.role
	running := in.status == "running"
	settled := in.status == "restarting" || in.status == "preparing"
	if settled {
		in.status = "stopped" // no live process right now
	}
	in.mu.Unlock()
	if settled {
		regRemove(role) // no exit event will fire for a child that isn't running
		janitorUnregister(pid, cont)
		releaseInstance(in) // windows: close the job handle
	}
	if cont != "" {
		// Removing the container makes the foreground docker CLI exit on its own.
		rmCmd := exec.Command(bin, "rm", "-f", cont)
		hideWindow(rmCmd)
		_ = rmCmd.Run()
	} else if running && pid > 0 {
		// The cmd.Wait goroutine (or adoption watcher) may have already reaped
		// this pid a moment ago without superviseExit yet flipping status off
		// "running" — signalling the raw pid/pgid then would risk a recycled pid.
		// Re-verify the start-time identity right before killing; a mismatch means
		// it's already gone. (Windows kills via the job handle, immune to reuse,
		// so it skips the check when startMicro is unknown.)
		if startMicro == 0 || identityMatches(pid, startMicro) {
			killInstanceTree(in, pid)
		}
	}
}

// identityMatches reports whether pid is still the same process that recorded
// startMicro (guards the reaped-then-recycled window before a kill).
func identityMatches(pid int, startMicro int64) bool {
	s, _, ok := procIdentity(pid)
	return ok && s == startMicro
}

// setConfigAutoStartLocked adds/removes a config from the persisted restore set.
// Caller holds m.mu.
func (m *manager) setConfigAutoStartLocked(id string, on bool) {
	next := make([]string, 0, len(m.st.AutoStart)+1)
	for _, x := range m.st.AutoStart {
		if x != id {
			next = append(next, x)
		}
	}
	if on {
		next = append(next, id)
	}
	m.st.AutoStart = next
	_ = m.persist()
}

// rememberConfigAutoStart is setConfigAutoStartLocked for callers not holding m.mu.
func (m *manager) rememberConfigAutoStart(id string, on bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.setConfigAutoStartLocked(id, on)
}

// rememberDdbAutoStart records whether Local DynamoDB should relaunch on boot.
func (m *manager) rememberDdbAutoStart(on bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.st.DdbAutoStart != on {
		m.st.DdbAutoStart = on
		_ = m.persist()
	}
}

// autoStartAll restores last session's running set: relaunch every config (and
// the Local DynamoDB) that was running at the previous shutdown/crash but isn't
// already live this boot (reconcile may have adopted survivors). Runs once at
// boot in a goroutine — the DDB is started first so redimos configs pointing at
// it come up against a live backend (the supervisor retries either way).
func (m *manager) autoStartAll() {
	m.mu.Lock()
	ddbWant := m.st.DdbAutoStart
	ddbLive := m.ddb != nil
	ids := append([]string{}, m.st.AutoStart...)
	m.mu.Unlock()

	if ddbWant && !ddbLive {
		_ = m.ddbStart()
	}
	for _, id := range ids {
		m.mu.Lock()
		_, live := m.running[id]
		m.mu.Unlock()
		if live {
			continue // adopted or already running
		}
		_ = m.start(id) // start()'s own guards no-op anything already up
	}
}

// livePids returns the pids of every child this session currently manages —
// including freshly ADOPTED ones, which are not OS-children of this process
// and would otherwise look exactly like reapable orphans to the heuristic
// sweeps (parentless + our path + our sentinel).
func (m *manager) livePids() map[int]bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.livePidsLocked()
}

// livePidsLocked is livePids for callers that already hold m.mu (e.g. start()).
// It additionally takes m.svcMu: safe, because no path takes svcMu and then
// m.mu (see the lock discipline in service_runtime.go). Service children count
// as live: they are detached and carry the spawn sentinel, so without them the
// orphan sweeps would kill a Service this session adopted or started.
func (m *manager) livePidsLocked() map[int]bool {
	ins := make([]*instance, 0, len(m.running)+len(m.svc)+1)
	for _, in := range m.running {
		ins = append(ins, in)
	}
	if m.ddb != nil {
		ins = append(ins, m.ddb)
	}
	m.svcMu.Lock()
	for _, rt := range m.svc {
		if rt.inst != nil {
			ins = append(ins, rt.inst)
		}
	}
	m.svcMu.Unlock()
	out := map[int]bool{}
	for _, in := range ins {
		in.mu.Lock()
		if in.pid > 0 {
			out[in.pid] = true
		}
		in.mu.Unlock()
	}
	return out
}

func (m *manager) stopAll() {
	m.mu.Lock()
	ins := make([]*instance, 0, len(m.running))
	for _, in := range m.running {
		ins = append(ins, in)
	}
	m.mu.Unlock()
	// Parallel: each terminate may spend the TERM→KILL grace period; app quit
	// shouldn't pay it once per child.
	var wg sync.WaitGroup
	for _, in := range ins {
		wg.Add(1)
		go func(in *instance) {
			defer wg.Done()
			in.terminate()
		}(in)
	}
	wg.Wait()
}

// stopAllSnapshot is the legacy AppBar "Stop all" entry point. It delegates to
// the unified Instance+Service path and reports only the Instance half of the
// snapshot (the pre-Service ABI shape); the typed snapshot is persisted by the
// unified path. Replaced wholesale by the Stage-9 ABI.
func (m *manager) stopAllSnapshot() []string {
	return m.stopAllUnified().Snapshot.Instances
}

// restoreAll is the legacy AppBar green "restore" entry point. It delegates to
// the unified restore and reports only the restored Instance IDs (the
// pre-Service ABI shape). Replaced wholesale by the Stage-9 ABI.
func (m *manager) restoreAll() []string {
	res := m.restoreAllUnified()
	out := make([]string, 0, len(res.Restored))
	for _, e := range res.Restored {
		if e.Kind == entityKindInstance {
			out = append(out, e.ID)
		}
	}
	return out
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
	Adopted     bool    `json:"adopted"` // inherited from a previous session

	// redimos /metrics-derived fields (zero/false until the first scrape).
	MetricsOK    bool    `json:"metricsOk"`    // scrape reached the endpoint
	Healthy      bool    `json:"healthy"`      // /healthz == 200
	Ready        bool    `json:"ready"`        // /readyz == 200
	OpsPerSec    float64 `json:"opsPerSec"`    // command rate over the last interval
	AvgLatencyMs float64 `json:"avgLatencyMs"` // average command latency (ms)
	Throttled    int64   `json:"throttled"`    // cumulative DynamoDB throttles
	// BackendError is redimos's reported cause for a failing backend check (the
	// /readyz body's backend_error). "" = no cause reported; the UI then explains
	// only the observed signal rather than guessing one.
	BackendError string `json:"backendError"`
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
			// For a non-running instance, prefer the recorded startup-failure cause
			// (a failing backend check, bad creds, missing table, …) over a bare
			// "exit status 1", so the UI shows why it isn't up. failReason is empty
			// for clean/healthy exits, so benign lifecycle lines never leak here.
			if in.status != "running" && in.failReason != "" {
				r.ExitMsg = in.failReason
			}
			r.Restarts = in.restarts
			r.AutoRestart = in.autoRestart
			r.Adopted = in.adopted
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
				// Scoped to a running child, like Healthy/Ready: the cause explains a
				// LIVE proxy's degraded backend. A stopped/failed one reports its cause
				// through ExitMsg (failReason) instead, and must not carry both.
				r.BackendError = in.backendError
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
	// endpoints[] + instances[] are the v1.2 split view of configs[] (same data,
	// grouped by backend). configs[] is still returned for any code path that
	// hasn't migrated to the split model yet.
	eps, insts := splitConfigs(mgr.st.Configs)
	out := map[string]any{
		"configs":           mgr.st.Configs,
		"endpoints":         eps,
		"instances":         insts,
		"settings":          mgr.st.Settings,
		"localDdb":          mgr.st.LocalDdb,
		"stopAllSnapshot":   mgr.st.StopAllSnapshot,
		"stopAllSnapshotV2": mgr.st.StopAllSnapshotV2,
		"services":          mgr.st.Services,
	}
	if mgr.lockErr != nil {
		out["lockError"] = mgr.lockErr.Error()
	}
	return cjson(out)
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
	mgr.setConfigAutoStartLocked(id, false) // don't try to restore a deleted config (also persists)
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

//export rm_get_formatters
func rm_get_formatters() *C.char {
	mgr.mu.Lock()
	defer mgr.mu.Unlock()
	fs := mgr.st.Formatters
	if fs == nil {
		fs = []Formatter{}
	}
	return cjson(map[string]any{"ok": true, "formatters": fs})
}

//export rm_set_formatters
func rm_set_formatters(in *C.char) *C.char {
	var req struct {
		Formatters []Formatter `json:"formatters"`
	}
	if err := json.Unmarshal([]byte(C.GoString(in)), &req); err != nil {
		return errJSON(err)
	}
	mgr.mu.Lock()
	mgr.st.Formatters = req.Formatters
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
	id := C.GoString(in)
	mgr.rememberConfigAutoStart(id, false) // USER stop → drop from next-launch restore
	if err := mgr.stop(id); err != nil {
		return errJSON(err)
	}
	return okJSON(nil)
}

//export rm_stop_all
func rm_stop_all() *C.char {
	res := mgr.stopAllUnified()
	return cjson(map[string]any{
		"ok":       true,
		"snapshot": res.Snapshot.Instances, // legacy shape during the migration
		"result":   res,                    // typed: snapshot{instances,services} + stopped/failed
	})
}

// rm_restore_all restarts everything recorded by the last Stop all (the green
// "restore" affordance). Successful and missing entities drop from the
// snapshot; failed ones stay for retry (8.3, 8.4).
//
//export rm_restore_all
func rm_restore_all() *C.char {
	res := mgr.restoreAllUnified()
	started := make([]string, 0, len(res.Restored))
	for _, e := range res.Restored {
		if e.Kind == entityKindInstance {
			started = append(started, e.ID)
		}
	}
	return cjson(map[string]any{
		"ok":      true,
		"started": started, // legacy shape during the migration
		"result":  res,     // typed: restored/failed/missing
	})
}

// rm_inspect_table peeks at the DynamoDB table a config points at and reports
// whether the data already there disagrees with the config's Version / MultiDB.
// Input is a full config JSON; output is a tableInspect JSON. Best-effort —
// returns Checked=false (never an error) when it can't tell.
//
//export rm_inspect_table
func rm_inspect_table(in *C.char) *C.char {
	var cfg Config
	if err := json.Unmarshal([]byte(C.GoString(in)), &cfg); err != nil {
		return cjson(tableInspect{})
	}
	return cjson(checkTableCompat(&cfg))
}

// rm_table_meta returns the selectable Scan/Query targets (base table + indexes)
// with their pk/sk attribute name and type. Input is a full config JSON.
//
//export rm_table_meta
func rm_table_meta(in *C.char) *C.char {
	var cfg Config
	if err := json.Unmarshal([]byte(C.GoString(in)), &cfg); err != nil {
		return errJSON(err)
	}
	return cjson(tableMeta(&cfg))
}

// rm_table_page runs one Scan or Query page for the Table browser. Input is a
// tablePageReq JSON (config + op + filters + pagination); output is the page.
//
//export rm_table_page
func rm_table_page(in *C.char) *C.char {
	var req tablePageReq
	if err := json.Unmarshal([]byte(C.GoString(in)), &req); err != nil {
		return errJSON(err)
	}
	return cjson(tablePage(&req))
}

// rm_partiql executes one PartiQL statement (ExecuteStatement) for the PartiQL
// tab. Input is a partiqlReq JSON; output has rows/cols/nextToken or an error.
//
//export rm_partiql
func rm_partiql(in *C.char) *C.char {
	var req partiqlReq
	if err := json.Unmarshal([]byte(C.GoString(in)), &req); err != nil {
		return errJSON(err)
	}
	return cjson(partiqlExec(&req))
}

// rm_ep_list_tables lists every table on a config's endpoint (the endpoint
// Browser's Tables sidebar), with DescribeTable metadata, a redimos-kind
// inference, the configs that use each table, and ghost rows for
// bound-but-missing tables. Read-only. Input is a full config JSON (endpoint +
// creds).
//
//export rm_ep_list_tables
func rm_ep_list_tables(in *C.char) *C.char {
	var cfg Config
	if err := json.Unmarshal([]byte(C.GoString(in)), &cfg); err != nil {
		return errJSON(err)
	}
	return cjson(mgr.endpointTables(&cfg))
}

// rm_table_get_item fetches one full item by key. Input: {config, key}. Read-only.
//
//export rm_table_get_item
func rm_table_get_item(in *C.char) *C.char {
	var req struct {
		Config Config         `json:"config"`
		Key    map[string]any `json:"key"`
	}
	if err := json.Unmarshal([]byte(C.GoString(in)), &req); err != nil {
		return errJSON(err)
	}
	return cjson(mgr.getItem(&req.Config, req.Key))
}

// rm_table_put_item writes (creates/replaces) one item on a config's table.
// Input: {config, item} where item is DynamoDB-JSON. Endpoint-gated.
//
//export rm_table_put_item
func rm_table_put_item(in *C.char) *C.char {
	var req struct {
		Config Config         `json:"config"`
		Item   map[string]any `json:"item"`
	}
	if err := json.Unmarshal([]byte(C.GoString(in)), &req); err != nil {
		return errJSON(err)
	}
	return cjson(mgr.putItem(&req.Config, req.Item))
}

// rm_table_delete_item removes one item by its key. Input: {config, key}. Endpoint-gated.
//
//export rm_table_delete_item
func rm_table_delete_item(in *C.char) *C.char {
	var req struct {
		Config Config         `json:"config"`
		Key    map[string]any `json:"key"`
	}
	if err := json.Unmarshal([]byte(C.GoString(in)), &req); err != nil {
		return errJSON(err)
	}
	return cjson(mgr.deleteItem(&req.Config, req.Key))
}

// rm_table_precheck returns the info the recreate confirmation dialog needs
// (allowed?, endpoint, loopback, item count/age, running dependents).
// Input is the config id string.
//
//export rm_table_precheck
func rm_table_precheck(in *C.char) *C.char {
	return cjson(mgr.tablePrecheck(C.GoString(in)))
}

// rm_table_recreate stops dependents, deletes the table, and restarts them with
// a one-shot auto-create so redimos rebuilds it. Input is the config id.
//
//export rm_table_recreate
func rm_table_recreate(in *C.char) *C.char {
	return cjson(mgr.recreateTable(C.GoString(in)))
}

// rm_table_inspect returns the blast-radius info (allowed?, endpoint, loopback,
// item count/age, bound running dependents) for a Purge/Delete confirmation on an
// arbitrary table. Input: {config, table}. Read-only.
//
//export rm_table_inspect
func rm_table_inspect(in *C.char) *C.char {
	var req struct {
		Config Config `json:"config"`
		Table  string `json:"table"`
	}
	if err := json.Unmarshal([]byte(C.GoString(in)), &req); err != nil {
		return errJSON(err)
	}
	return cjson(mgr.inspectTable(&req.Config, req.Table))
}

// rm_table_purge deletes every item from a table (schema kept). Input: {config,
// table}. Endpoint-gated.
//
//export rm_table_purge
func rm_table_purge(in *C.char) *C.char {
	var req struct {
		Config Config `json:"config"`
		Table  string `json:"table"`
	}
	if err := json.Unmarshal([]byte(C.GoString(in)), &req); err != nil {
		return errJSON(err)
	}
	return cjson(mgr.purgeItems(&req.Config, req.Table))
}

// rm_table_delete drops a table entirely (no recreate), stopping any bound running
// configs and leaving them stopped. Input: {config, table}. Endpoint-gated.
//
//export rm_table_delete
func rm_table_delete(in *C.char) *C.char {
	var req struct {
		Config Config `json:"config"`
		Table  string `json:"table"`
	}
	if err := json.Unmarshal([]byte(C.GoString(in)), &req); err != nil {
		return errJSON(err)
	}
	return cjson(mgr.deleteTableOnly(&req.Config, req.Table))
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
