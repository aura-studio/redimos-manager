package main

// Local DynamoDB: a single managed local backend for configs to point at.
// Three engines × two storage modes = five launch methods:
//
//   1. java      + memory    java -jar DynamoDBLocal.jar -inMemory -sharedDb
//   2. java      + persist   java -jar DynamoDBLocal.jar -dbPath <dir> -sharedDb
//   3. docker    + memory    docker run amazon/dynamodb-local ... -inMemory -sharedDb
//   4. docker    + persist   docker run -v <vol>:/data ... -dbPath /data -sharedDb
// (-sharedDb is always on so all clients — the proxy and the Endpoint tab's
//  ListTables — share one table namespace regardless of creds/region.)
//   5. localstack             docker run -e SERVICES=dynamodb localstack/localstack
//
// The child reuses the generic instance machinery (logs pump, supervisor with
// backoff, sampler). Docker engines run through a *foreground* `docker run --rm
// --name X` CLI so Wait/logs work unchanged; stopping removes the container,
// which makes the CLI exit on its own.

/*
#include <stdlib.h>
*/
import "C"

import (
	"archive/zip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// LocalDdbConfig is the persisted Local DynamoDB launch configuration.
type LocalDdbConfig struct {
	Engine  string `json:"engine"`  // "java" | "docker" | "localstack"
	Storage string `json:"storage"` // "memory" | "persist" (ignored by localstack)
	Port    int    `json:"port"`    // host port; 0 = engine default (8000 / 4566)
	DataDir string `json:"dataDir"` // java persist: -dbPath directory
	Volume  string `json:"volume"`  // docker persist: named volume
}

const (
	ddbContainerName = "redimos-local-ddb"
	lsContainerName  = "redimos-localstack"
	ddbDownloadURL   = "https://s3.us-west-2.amazonaws.com/dynamodb-local/dynamodb_local_latest.zip"
	// Pinned to the last free community line — the 2026.x "latest" images
	// refuse to boot without a LOCALSTACK_AUTH_TOKEN (license activation).
	localstackImage = "localstack/localstack:4.0"
)

func normalizeDdb(c LocalDdbConfig) LocalDdbConfig {
	if c.Engine == "" {
		c.Engine = "docker"
	}
	if c.Storage == "" {
		c.Storage = "memory"
	}
	if c.Port == 0 {
		if c.Engine == "localstack" {
			c.Port = 4566
		} else {
			c.Port = 8000
		}
	}
	if c.Volume == "" {
		c.Volume = "redimos-ddb-data"
	}
	if c.DataDir == "" {
		home, _ := os.UserHomeDir()
		c.DataDir = filepath.Join(home, ".redimos", "ddb-data")
	}
	return c
}

// ---------------------------------------------------------------------------
// Tool detection (cached): GUI-launched apps get a stripped PATH, so probe the
// usual install locations too, and actually *run* the tool — on macOS
// /usr/bin/java exists as a stub that errors out when no JRE is installed.
// ---------------------------------------------------------------------------

var (
	detectMu    sync.Mutex
	detectCache = map[string]struct {
		path string
		ok   bool
		at   time.Time
	}{}
)

func findTool(name string, fallbacks ...string) (string, bool) {
	detectMu.Lock()
	if c, hit := detectCache[name]; hit && time.Since(c.at) < 30*time.Second {
		detectMu.Unlock()
		return c.path, c.ok
	}
	detectMu.Unlock()

	// Build an ordered candidate list — PATH first, then explicit fallbacks —
	// and probe each until one actually runs. A single-candidate approach trips
	// over shims like macOS's /usr/bin/java stub (on PATH, but fails -version
	// when no JDK is registered), which would otherwise mask a working JDK that
	// lives only in a fallback location (e.g. keg-only brew openjdk).
	var candidates []string
	if p, err := exec.LookPath(name); err == nil {
		candidates = append(candidates, p)
	}
	for _, f := range fallbacks {
		if _, err := os.Stat(f); err == nil {
			candidates = append(candidates, f)
		}
	}

	path, ok := "", false
	if len(candidates) > 0 {
		path = candidates[0] // reported even if every probe fails
	}
	for _, cand := range candidates {
		probe := exec.Command(cand, "-version")
		if name == "docker" {
			probe = exec.Command(cand, "version", "--format", "{{.Client.Version}}")
		}
		done := make(chan error, 1)
		if err := probe.Start(); err != nil {
			continue
		}
		go func() { done <- probe.Wait() }()
		select {
		case err := <-done:
			if err == nil {
				path, ok = cand, true
			}
		case <-time.After(5 * time.Second):
			_ = probe.Process.Kill()
		}
		if ok {
			break
		}
	}
	detectMu.Lock()
	detectCache[name] = struct {
		path string
		ok   bool
		at   time.Time
	}{path, ok, time.Now()}
	detectMu.Unlock()
	return path, ok
}

func dockerBin() (string, bool) {
	return findTool("docker",
		"/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker",
		"/Applications/Docker.app/Contents/Resources/bin/docker")
}

func javaBin() (string, bool) {
	var fb []string
	if jh := os.Getenv("JAVA_HOME"); jh != "" {
		fb = append(fb, filepath.Join(jh, "bin", "java"), filepath.Join(jh, "bin", "java.exe"))
	}
	// A JDK registered with macOS's java_home (Temurin, Zulu, etc.).
	if runtime.GOOS == "darwin" {
		if out, err := exec.Command("/usr/libexec/java_home").Output(); err == nil {
			if home := strings.TrimSpace(string(out)); home != "" {
				fb = append(fb, filepath.Join(home, "bin", "java"))
			}
		}
	}
	// Homebrew's keg-only openjdk: not on PATH, so probe its canonical prefixes.
	fb = append(fb,
		"/usr/local/opt/openjdk/bin/java",    // Intel brew
		"/opt/homebrew/opt/openjdk/bin/java", // Apple-silicon brew
	)
	// The macOS /usr/bin/java stub goes LAST: it exists even with no JDK and
	// only passes its probe when a real runtime is actually registered.
	fb = append(fb, "/usr/bin/java")
	return findTool("java", fb...)
}

// ---------------------------------------------------------------------------
// docker stats sampling for containerised children (shared with run-mode docker)
// ---------------------------------------------------------------------------

// sampleContainer returns (cpuPercentTotal, memBytes). CPU is docker's
// percent-of-one-core scale; the caller divides by NumCPU like the host path.
func sampleContainer(dockerPath, name string) (cpu float64, mem uint64, diskBytes uint64, err error) {
	cmd := exec.Command(dockerPath, "stats", "--no-stream", "--format", "{{.CPUPerc}}|{{.MemUsage}}|{{.BlockIO}}", name)
	out := make(chan []byte, 1)
	errc := make(chan error, 1)
	go func() {
		b, e := cmd.Output()
		if e != nil {
			errc <- e
			return
		}
		out <- b
	}()
	select {
	case b := <-out:
		parts := strings.SplitN(strings.TrimSpace(string(b)), "|", 3)
		if len(parts) < 2 {
			return 0, 0, 0, fmt.Errorf("unexpected docker stats output")
		}
		cpu, _ = strconv.ParseFloat(strings.TrimSuffix(strings.TrimSpace(parts[0]), "%"), 64)
		mem = parseMemUsage(parts[1])
		if len(parts) == 3 {
			diskBytes = parseBlockIO(parts[2]) // cumulative "read / write"
		}
		return cpu, mem, diskBytes, nil
	case e := <-errc:
		return 0, 0, 0, e
	case <-time.After(6 * time.Second):
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		return 0, 0, 0, fmt.Errorf("docker stats timeout")
	}
}

// parseBlockIO turns a docker-stats BlockIO cell ("1.2MB / 3.4MB") into the sum
// of both directions in bytes.
func parseBlockIO(s string) uint64 {
	var total uint64
	for _, part := range strings.Split(s, "/") {
		total += parseSize(strings.TrimSpace(part))
	}
	return total
}

// parseMemUsage parses the left side of docker's "48.2MiB / 7.6GiB".
func parseMemUsage(s string) uint64 {
	// docker reports "used / limit"; we want the used side.
	return parseSize(strings.SplitN(s, "/", 2)[0])
}

// parseSize parses a single docker-style size token ("512MiB", "1.2MB", "0B").
func parseSize(s string) uint64 {
	s = strings.TrimSpace(s)
	units := []struct {
		suffix string
		mult   float64
	}{
		{"GiB", 1 << 30}, {"MiB", 1 << 20}, {"KiB", 1 << 10},
		{"GB", 1e9}, {"MB", 1e6}, {"kB", 1e3}, {"B", 1},
	}
	for _, u := range units {
		if strings.HasSuffix(s, u.suffix) {
			v, err := strconv.ParseFloat(strings.TrimSpace(strings.TrimSuffix(s, u.suffix)), 64)
			if err != nil {
				return 0
			}
			return uint64(v * u.mult)
		}
	}
	return 0
}

// ---------------------------------------------------------------------------
// Java package (DynamoDBLocal.jar) auto-provisioning
// ---------------------------------------------------------------------------

func (m *manager) ddbJavaDir() string {
	m.mu.Lock()
	override := strings.TrimSpace(m.st.Settings.DynamoDbLocalDir)
	m.mu.Unlock()
	if override != "" {
		return override
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".redimos", "dynamodb-local")
}

func ddbJarReady(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, "DynamoDBLocal.jar"))
	return err == nil
}

// ensureDdbJar downloads and unpacks the official DynamoDBLocal package into
// dir. Progress goes to the instance log so the UI can show it live.
func ensureDdbJar(in *instance, dir string) error {
	if ddbJarReady(dir) {
		return nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	in.appendLog("[local-ddb: downloading " + ddbDownloadURL + " ...]")
	client := &http.Client{Timeout: 15 * time.Minute}
	resp, err := client.Get(ddbDownloadURL)
	if err != nil {
		return fmt.Errorf("download failed: %w (set the DynamoDBLocal dir manually in Settings)", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("download failed: HTTP %d", resp.StatusCode)
	}
	tmp, err := os.CreateTemp("", "ddblocal-*.zip")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	var got int64
	buf := make([]byte, 1<<20)
	lastLog := int64(0)
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := tmp.Write(buf[:n]); werr != nil {
				tmp.Close()
				return werr
			}
			got += int64(n)
			if got-lastLog >= 10<<20 {
				in.appendLog(fmt.Sprintf("[local-ddb: downloaded %d MB]", got>>20))
				lastLog = got
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			tmp.Close()
			return rerr
		}
	}
	tmp.Close()
	in.appendLog(fmt.Sprintf("[local-ddb: download complete (%d MB), unpacking...]", got>>20))

	zr, err := zip.OpenReader(tmpPath)
	if err != nil {
		return err
	}
	defer zr.Close()
	for _, f := range zr.File {
		dst := filepath.Join(dir, f.Name)
		if !strings.HasPrefix(filepath.Clean(dst), filepath.Clean(dir)) {
			continue // zip-slip guard
		}
		if f.FileInfo().IsDir() {
			_ = os.MkdirAll(dst, 0o755)
			continue
		}
		_ = os.MkdirAll(filepath.Dir(dst), 0o755)
		rc, err := f.Open()
		if err != nil {
			return err
		}
		w, err := os.OpenFile(dst, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, f.Mode()|0o644)
		if err != nil {
			rc.Close()
			return err
		}
		_, cerr := io.Copy(w, rc)
		rc.Close()
		w.Close()
		if cerr != nil {
			return cerr
		}
	}
	if !ddbJarReady(dir) {
		return fmt.Errorf("unpacked but DynamoDBLocal.jar not found in %s", dir)
	}
	in.appendLog("[local-ddb: DynamoDBLocal ready at " + dir + "]")
	return nil
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

// buildDdbLaunch resolves the Local DynamoDB launch spec for cfg: binary,
// arguments and (for docker engines) the container name. Shared by ddbStart
// and the boot adoption path (which needs a valid spec for later supervised
// restarts of an adopted child).
func (m *manager) buildDdbLaunch(cfg LocalDdbConfig) (bin string, args []string, container string, err error) {
	switch cfg.Engine {
	case "docker", "localstack":
		docker, ok := dockerBin()
		if !ok {
			return "", nil, "", fmt.Errorf("docker not available (install Docker Desktop, or pick the Java engine)")
		}
		// Session-tagged labels: the boot sweep finds leftover containers from
		// dead sessions by label (host `ps` can't see containers at all).
		label1, label2 := "redimos.manager=1", "redimos.manager.session="+m.sessionID
		if cfg.Engine == "localstack" {
			return docker, []string{"run", "--rm", "--name", lsContainerName,
				"--label", label1, "--label", label2,
				"-p", fmt.Sprintf("%d:4566", cfg.Port), "-e", "SERVICES=dynamodb",
				localstackImage}, lsContainerName, nil
		}
		a := []string{"run", "--rm", "--name", ddbContainerName,
			"--label", label1, "--label", label2,
			"-p", fmt.Sprintf("%d:8000", cfg.Port)}
		if cfg.Storage == "persist" {
			// the image runs as a non-root user; a fresh named volume is
			// root-owned, so run as root for the persisted mode
			a = append(a, "-v", cfg.Volume+":/data", "-u", "root")
		}
		a = append(a, "amazon/dynamodb-local", "-jar", "DynamoDBLocal.jar")
		if cfg.Storage == "persist" {
			a = append(a, "-dbPath", "/data", "-sharedDb")
		} else {
			// -sharedDb even in memory: WITHOUT it DynamoDB Local partitions tables by
			// (accessKeyId, region), so a redimos proxy's auto-created table is invisible
			// to the Endpoint tab's ListTables (which signs with different creds/region).
			// One shared namespace makes it behave like real DynamoDB. (-inMemory only
			// conflicts with -dbPath, not -sharedDb.)
			a = append(a, "-inMemory", "-sharedDb")
		}
		return docker, a, ddbContainerName, nil

	case "java":
		java, ok := javaBin()
		if !ok {
			return "", nil, "", fmt.Errorf("java not available (install a JRE, or pick a Docker engine)")
		}
		dir := m.ddbJavaDir()
		// The leading -D is a cmdline sentinel: JVM system properties before -jar
		// are invisible to the app but show up in `ps`, tagging the process as
		// ours even if the registry is lost.
		a := []string{"-Dredimos.manager.session=" + m.sessionID,
			"-Djava.library.path=" + filepath.Join(dir, "DynamoDBLocal_lib"),
			"-jar", filepath.Join(dir, "DynamoDBLocal.jar"),
			"-port", strconv.Itoa(cfg.Port)}
		if cfg.Storage == "persist" {
			_ = os.MkdirAll(cfg.DataDir, 0o755)
			a = append(a, "-dbPath", cfg.DataDir, "-sharedDb")
		} else {
			a = append(a, "-inMemory", "-sharedDb") // shared namespace — see the docker branch
		}
		return java, a, "", nil

	default:
		return "", nil, "", fmt.Errorf("unknown engine %q", cfg.Engine)
	}
}

// publishDdb installs in as the Local DynamoDB child, but only if none is
// already active — the atomic half of ddbStart's check-and-set (the initial
// busy-check can't hold m.mu across the slow buildDdbLaunch tool probes).
func (m *manager) publishDdb(in *instance) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.ddb != nil {
		m.ddb.mu.Lock()
		st := m.ddb.status
		m.ddb.mu.Unlock()
		if st == "running" || st == "preparing" || st == "restarting" {
			return fmt.Errorf("local dynamodb already %s", st)
		}
	}
	m.ddb = in
	return nil
}

func (m *manager) ddbStart() error {
	m.mu.Lock()
	if m.lockErr != nil {
		err := m.lockErr
		m.mu.Unlock()
		return err // a sibling instance owns the children; don't fight it
	}
	cfg := normalizeDdb(m.st.LocalDdb)
	if m.ddb != nil {
		m.ddb.mu.Lock()
		st := m.ddb.status
		m.ddb.mu.Unlock()
		if st == "running" || st == "preparing" || st == "restarting" {
			m.mu.Unlock()
			return fmt.Errorf("local dynamodb already %s", st)
		}
	}
	m.mu.Unlock()

	bin, args, container, err := m.buildDdbLaunch(cfg)
	if err != nil {
		return err
	}

	// detached: the Local DynamoDB is the one STATEFUL child (in-memory dev
	// tables) — it deliberately survives a manager crash so the next session can
	// adopt it instead of wiping the data (no job jail / no janitor kill).
	in := &instance{
		port: cfg.Port, role: "ddb", autoRestart: true, detached: true, status: "preparing",
		bin: bin, launchArgs: args, launchEnv: os.Environ(), container: container,
	}
	// Atomically re-check-and-publish: the top busy-check released m.mu while
	// buildDdbLaunch probed tools, so a second concurrent Start could otherwise
	// slip in and spawn a duelling same-name container. The "preparing" status is
	// what the re-check sees.
	if err := m.publishDdb(in); err != nil {
		return err
	}
	m.rememberDdbAutoStart(true) // remember for next-launch restore
	if container != "" {
		if err := in.spawn(); err != nil {
			in.mu.Lock()
			in.status = "error"
			in.exitMsg = err.Error()
			in.mu.Unlock()
			return err
		}
		return nil
	}

	// java engine: the jar may need downloading first.
	dir := m.ddbJavaDir()
	jarPath := filepath.Join(dir, "DynamoDBLocal.jar")
	go func() {
		// A prior app session may have left an orphaned DynamoDBLocal bound to
		// this port (a child survives an ungraceful app exit). Reap our own
		// straggler first so the fresh child can bind instead of crash-looping
		// on "address already in use".
		reapStalePort(cfg.Port, jarPath, m.livePids())
		if err := ensureDdbJar(in, dir); err != nil {
			in.mu.Lock()
			if !in.intendedStop {
				in.status = "error"
				in.exitMsg = err.Error()
				in.appendLogLocked("[local-ddb: " + err.Error() + "]")
			}
			in.mu.Unlock()
			return
		}
		in.mu.Lock()
		stopped := in.intendedStop
		in.mu.Unlock()
		if stopped {
			return
		}
		if err := in.spawn(); err != nil {
			in.mu.Lock()
			in.status = "error"
			in.exitMsg = err.Error()
			in.mu.Unlock()
		}
	}()
	return nil
}

// managedPathMatches returns the absolute paths that identify our managed
// binaries (the two redimos binaries from Settings + the DynamoDBLocal jar),
// used by the per-OS reapers to recognize candidates.
func (m *manager) managedPathMatches() []string {
	m.mu.Lock()
	var matches []string
	if p := strings.TrimSpace(m.st.Settings.RedimosV1Path); p != "" {
		matches = append(matches, p)
	}
	if p := strings.TrimSpace(m.st.Settings.RedimosV2Path); p != "" {
		matches = append(matches, p)
	}
	m.mu.Unlock()
	return append(matches, filepath.Join(m.ddbJavaDir(), "DynamoDBLocal.jar"))
}

// sweepLabeledContainers removes containers left behind by previous sessions.
// Every container we spawn carries redimos.manager labels with the spawning
// session's id; anything carrying the manager label but a FOREIGN session id is
// a leftover (the docker CLI child died with its manager, the container kept
// running under dockerd — invisible to the host-`ps` sweep). The current
// session's own containers are never touched, and `skip` lets the boot
// reconciler protect containers it chose to adopt. Caller must hold the
// single-instance lock, so no live sibling can own any of these.
func (m *manager) sweepLabeledContainers(skip map[string]bool) {
	docker, ok := dockerBin()
	if !ok {
		return
	}
	out, err := exec.Command(docker, "ps", "-aq", "--filter", "label=redimos.manager").Output()
	if err != nil {
		return
	}
	for _, cid := range strings.Fields(string(out)) {
		insp, err := exec.Command(docker, "inspect", "-f",
			`{{index .Config.Labels "redimos.manager.session"}}|{{.Name}}`, cid).Output()
		if err != nil {
			continue
		}
		parts := strings.SplitN(strings.TrimSpace(string(insp)), "|", 2)
		if len(parts) != 2 {
			continue
		}
		sess, name := parts[0], strings.TrimPrefix(parts[1], "/")
		if sess == m.sessionID || skip[name] {
			continue
		}
		_ = exec.Command(docker, "rm", "-f", cid).Run()
	}
}

// configUsesLocalDdb reports whether a config's endpoint points at the local
// DynamoDB on ddbPort (localhost / 127.0.0.1).
func configUsesLocalDdb(cfg Config, ddbPort int) bool {
	e := cfg.Endpoint
	return strings.Contains(e, fmt.Sprintf("localhost:%d", ddbPort)) ||
		strings.Contains(e, fmt.Sprintf("127.0.0.1:%d", ddbPort))
}

// restartLocalDdbDependents restarts every running redimos instance that points
// at the local DynamoDB, so a backend that just (re)started hands the proxies a
// fresh connection instead of leaving them stuck on "backend error, retry
// later". The Cmd console re-connects on its own once the proxy is back up.
func (m *manager) restartLocalDdbDependents(ddbPort int) {
	m.mu.Lock()
	var ids []string
	for _, cfg := range m.st.Configs {
		in, ok := m.running[cfg.ID]
		if !ok || !configUsesLocalDdb(cfg, ddbPort) {
			continue
		}
		in.mu.Lock()
		live := in.status == "running" || in.status == "restarting"
		in.mu.Unlock()
		if live {
			ids = append(ids, cfg.ID)
		}
	}
	m.mu.Unlock()
	for _, id := range ids {
		go m.restartConfig(id)
	}
}

// restartConfig cleanly stops then re-starts a running config (used to force a
// fresh backend connection after the Local DynamoDB restarts).
func (m *manager) restartConfig(id string) {
	m.mu.Lock()
	in, ok := m.running[id]
	m.mu.Unlock()
	if ok {
		in.appendLog("[local dynamodb restarted — reconnecting]")
		in.terminate()
		for i := 0; i < 50; i++ { // wait out the TERM→KILL grace so start() won't reject
			in.mu.Lock()
			s := in.status
			in.mu.Unlock()
			if s == "stopped" || s == "error" || s == "failed" {
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
	}
	_ = m.start(id)
}

// afterDdbReady waits (bounded) for the Local DynamoDB to report running, then
// runs fn(ddbPort). Used to restart dependents only once the backend can accept
// connections.
func (m *manager) afterDdbReady(ddbPort int, fn func(int)) {
	for i := 0; i < 150; i++ { // up to ~30s
		m.mu.Lock()
		dd := m.ddb
		m.mu.Unlock()
		if dd == nil {
			return
		}
		dd.mu.Lock()
		s := dd.status
		dd.mu.Unlock()
		switch s {
		case "running":
			time.Sleep(1200 * time.Millisecond) // small grace for the port to accept
			fn(ddbPort)
			return
		case "error", "failed", "stopped":
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func (m *manager) ddbStop() error {
	m.mu.Lock()
	in := m.ddb
	m.mu.Unlock()
	if in == nil {
		return fmt.Errorf("not running")
	}
	in.terminate()
	return nil
}

// ---------------------------------------------------------------------------
// FFI
// ---------------------------------------------------------------------------

//export rm_ddb_get
func rm_ddb_get() *C.char {
	mgr.mu.Lock()
	cfg := normalizeDdb(mgr.st.LocalDdb)
	in := mgr.ddb
	mgr.mu.Unlock()

	_, dockerOK := dockerBin()
	_, javaOK := javaBin()
	javaDir := mgr.ddbJavaDir()

	st := map[string]any{"status": "stopped"}
	if in != nil {
		in.mu.Lock()
		st = map[string]any{
			"status":     in.status,
			"pid":        in.pid,
			"port":       in.port,
			"exitMsg":    in.exitMsg,
			"restarts":   in.restarts,
			"cpuPercent": in.cpuPercent,
			"memBytes":   in.memBytes,
			"diskPerSec": in.diskPerSec,
			"adopted":    in.adopted,
			"uptimeSec":  0,
		}
		if in.status == "running" {
			st["uptimeSec"] = int64(time.Since(in.started).Seconds())
		}
		in.mu.Unlock()
	}
	return cjson(map[string]any{
		"config": cfg,
		"status": st,
		"detect": map[string]any{
			"docker":   dockerOK,
			"java":     javaOK,
			"jarReady": ddbJarReady(javaDir),
			"javaDir":  javaDir,
		},
	})
}

//export rm_ddb_set
func rm_ddb_set(in *C.char) *C.char {
	var cfg LocalDdbConfig
	if err := json.Unmarshal([]byte(C.GoString(in)), &cfg); err != nil {
		return errJSON(err)
	}
	switch cfg.Engine {
	case "java", "docker", "localstack":
	default:
		return errJSON(fmt.Errorf("engine must be java|docker|localstack"))
	}
	if cfg.Port < 0 || cfg.Port > 65535 {
		return errJSON(fmt.Errorf("port must be 0..65535"))
	}
	mgr.mu.Lock()
	mgr.st.LocalDdb = cfg
	err := mgr.persist()
	mgr.mu.Unlock()
	if err != nil {
		return errJSON(err)
	}
	return okJSON(nil)
}

//export rm_ddb_start
func rm_ddb_start() *C.char {
	if err := mgr.ddbStart(); err != nil {
		return errJSON(err)
	}
	// User-initiated (re)start: once the backend is ready, restart the redimos
	// instances that depend on it so they reconnect instead of being stuck on
	// "backend error". (autoStartAll's boot restore calls ddbStart directly and
	// deliberately skips this — nothing is running yet to reconnect.)
	mgr.mu.Lock()
	port := normalizeDdb(mgr.st.LocalDdb).Port
	mgr.mu.Unlock()
	go mgr.afterDdbReady(port, mgr.restartLocalDdbDependents)
	return okJSON(nil)
}

//export rm_ddb_stop
func rm_ddb_stop() *C.char {
	mgr.rememberDdbAutoStart(false) // USER stop → don't restore Local DynamoDB next launch
	if err := mgr.ddbStop(); err != nil {
		return errJSON(err)
	}
	return okJSON(nil)
}

// rm_shutdown terminates every managed child — redimos instances and the Local
// DynamoDB backend — so nothing is left orphaned when the app quits. Called from
// the Dart side on an exit request (Cmd-Q / window close).
//
//export rm_shutdown
func rm_shutdown() *C.char {
	// Parallel: each terminate may spend the TERM→KILL grace; the quitting app
	// should pay it once, not once per child.
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); mgr.stopAll() }()
	go func() { defer wg.Done(); _ = mgr.ddbStop() }()
	wg.Wait()
	janitorClose() // disarm the lifeline; children are already down
	return okJSON(nil)
}

//export rm_ddb_logs
func rm_ddb_logs() *C.char {
	mgr.mu.Lock()
	in := mgr.ddb
	mgr.mu.Unlock()
	if in == nil {
		return cjson(map[string]any{"lines": []string{}})
	}
	return cjson(map[string]any{"lines": in.snapshotLogs()})
}
