package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Boot reconciliation: resolve the children registry a previous session left
// behind. For every record, decide dead / stranger / ours; what's provably
// ours is ADOPTED when it is the stateful Local DynamoDB (or a still-running
// docker child whose config hasn't changed) and killed otherwise.
//
// Adoption is the whole point of letting the DDB survive a manager crash
// (`detached`): its default config is an in-memory store, so the orphan is
// carrying the user's dev tables — kill-on-sight would wipe them at the exact
// moment the user tries to resume work. Native redimos children are stateless
// and respawn in milliseconds fully supervised, so for them kill-and-restart
// stays strictly better (an adopted native Go process is also a SIGPIPE time
// bomb once its dead log pipe fills).
//
// Identity is (pid, start-µs, comm) for native children and the container
// name/label for docker ones — the precise replacement for the old
// path-substring heuristic; none of it depends on PPID semantics (works
// unchanged on Windows). Runs once at boot, under the single-instance lock.
//
// Returns the container names it adopted so sweepLabeledContainers spares them.
func (m *manager) reconcileOnBoot() map[string]bool {
	adoptedContainers := map[string]bool{}
	for _, rec := range regSnapshot() {
		if rec.Container != "" {
			if m.tryAdoptDocker(rec) {
				adoptedContainers[rec.Container] = true
				continue
			}
			// Not adoptable: the label sweep removes the container itself; only
			// the bookkeeping goes here.
			regRemove(rec.Role)
			continue
		}
		start, comm, ok := procIdentity(rec.PID)
		if !ok || start != rec.StartUnixMicro || comm != rec.Comm {
			regRemove(rec.Role) // dead, or the pid was recycled by a stranger
			continue
		}
		if rec.Role == "ddb" && m.tryAdoptNativeDdb(rec) {
			continue
		}
		// Verified orphan of a dead session (were its manager alive, we could
		// not hold the single-instance lock).
		killChildTree(rec.PID)
		regRemove(rec.Role)
	}
	return adoptedContainers
}

func adoptionBanner(rec childRec) string {
	return fmt.Sprintf("[adopted from previous session: pid %d, started %s]",
		rec.PID, time.UnixMicro(rec.StartUnixMicro).Format("2006-01-02 15:04:05"))
}

// tryAdoptNativeDdb adopts a still-running java DynamoDBLocal from a previous
// session, preserving its in-memory tables: the instance is rebuilt around the
// live pid (no cmd handle), a kqueue/handle watcher stands in for cmd.Wait so
// the supervisor — including restart-on-death — keeps working, and the launch
// spec is rebuilt from the current config so a later supervised restart works
// verbatim. Only adopts when the config still matches what the process was
// started as (engine java on the same port); otherwise the caller kills it.
func (m *manager) tryAdoptNativeDdb(rec childRec) bool {
	m.mu.Lock()
	cfg := normalizeDdb(m.st.LocalDdb)
	busy := m.ddb != nil
	m.mu.Unlock()
	if busy || cfg.Engine != "java" || cfg.Port != rec.Port {
		return false
	}
	bin, args, _, err := m.buildDdbLaunch(cfg) // spec for future restarts
	if err != nil {
		// java vanished from the machine; the running orphan still works, but a
		// restart wouldn't. Adopt anyway — killing it would wipe data for no win.
		bin, args = rec.Bin, nil
	}
	in := &instance{
		port: rec.Port, role: "ddb", autoRestart: true, detached: true, adopted: true,
		pid: rec.PID, startMicro: rec.StartUnixMicro, status: "running",
		started: time.UnixMicro(rec.StartUnixMicro),
		bin: bin, launchArgs: args, launchEnv: os.Environ(),
	}
	in.appendLog(adoptionBanner(rec))
	m.mu.Lock()
	m.ddb = in
	m.mu.Unlock()
	rec.Session = m.sessionID
	regUpsert(rec) // re-owned by this session (re-adoptable if we crash too)
	watchProcessExit(rec.PID, rec.StartUnixMicro, in.superviseExit)
	return true
}

// dockerContainerRunning reports whether a container with exactly this name is
// currently running. Bounded: a wedged docker daemon must not hang boot
// reconcile (it runs during dylib load) or the adoption watcher loop.
func dockerContainerRunning(docker, name string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, docker, "inspect", "-f", "{{.State.Running}}", name).Output()
	return err == nil && strings.TrimSpace(string(out)) == "true"
}

// tryAdoptDocker adopts a container that outlived its session's docker CLI —
// docker children are first-class adoptees: `docker logs --tail -f` recovers
// history the native path loses, `docker wait` returns the true exit code, and
// stats/metrics/terminate were name-addressed all along. Adopts only when the
// current config still matches (same engine/port for the ddb; run-mode docker
// + same port for a redimos config); otherwise the label sweep removes it.
func (m *manager) tryAdoptDocker(rec childRec) bool {
	docker, ok := dockerBin()
	if !ok || !dockerContainerRunning(docker, rec.Container) {
		return false
	}

	var configID string // "" => the ddb
	autoRestart, detached := true, false
	if rec.Role == "ddb" {
		m.mu.Lock()
		cfg := normalizeDdb(m.st.LocalDdb)
		busy := m.ddb != nil
		m.mu.Unlock()
		wantName := ddbContainerName
		if cfg.Engine == "localstack" {
			wantName = lsContainerName
		}
		if busy || cfg.Engine == "java" || rec.Container != wantName || cfg.Port != rec.Port {
			return false
		}
		detached = true
	} else {
		id, found := strings.CutPrefix(rec.Role, "config:")
		if !found {
			return false
		}
		m.mu.Lock()
		cfg, _ := m.findConfig(id)
		match := cfg != nil && cfg.RunMode == "docker" && cfg.Port == rec.Port
		if match {
			autoRestart = cfg.AutoRestart
		}
		_, alreadyRunning := m.running[id]
		m.mu.Unlock()
		if !match || alreadyRunning {
			return false
		}
		configID = id
	}

	in := &instance{
		port: rec.Port, role: rec.Role, autoRestart: autoRestart, detached: detached, adopted: true,
		container: rec.Container, bin: docker, launchEnv: os.Environ(),
		status: "running", started: time.UnixMicro(rec.StartUnixMicro),
	}
	// Rebuild the launch args so a supervised restart re-runs the child as a
	// fully-owned fresh container.
	if configID == "" {
		m.mu.Lock()
		cfg := normalizeDdb(m.st.LocalDdb)
		m.mu.Unlock()
		if _, args, _, err := m.buildDdbLaunch(cfg); err == nil {
			in.launchArgs = args
		}
	} else {
		m.mu.Lock()
		if cfg, _ := m.findConfig(configID); cfg != nil {
			if _, args, _, _, err := m.buildDockerLaunch(cfg); err == nil {
				in.launchArgs = args
			}
		}
		m.mu.Unlock()
	}
	in.appendLog(adoptionBanner(rec))

	m.mu.Lock()
	if configID == "" {
		m.ddb = in
	} else {
		m.running[configID] = in
	}
	m.mu.Unlock()

	rec.Session = m.sessionID
	rec.Bin = docker
	regUpsert(rec)
	// Lifetime binding for the stateless adopted redimos container (the ddb
	// stays detached by design).
	janitorRegister(detached, 0, docker, rec.Container)

	// Log pump: docker keeps history, so adoption even recovers the tail the
	// native path would have lost. One shared pipe for both streams, closed on
	// every path — the earlier asymmetric StdoutPipe/StderrPipe leaked fds when
	// only the second pipe or Start failed.
	logsCmd := exec.Command(docker, "logs", "--tail", "200", "-f", rec.Container)
	if pr, pw, perr := os.Pipe(); perr == nil {
		logsCmd.Stdout, logsCmd.Stderr = pw, pw
		if logsCmd.Start() == nil {
			go pump(pr, in)
			go func() { _ = logsCmd.Wait(); _ = pr.Close() }()
		} else {
			_ = pr.Close()
		}
		_ = pw.Close() // the child holds its own dup; the parent's copy isn't needed
	}
	// Watcher: docker wait blocks until the container exits and prints its exit
	// code — the container analog of cmd.Wait. A CLI-side failure (daemon hiccup,
	// socket reset) is NOT an exit: re-check liveness and re-arm rather than
	// declaring a spurious exit that would trigger a restart.
	go func() {
		for {
			out, werr := exec.Command(docker, "wait", rec.Container).Output()
			code := strings.TrimSpace(string(out))
			if werr == nil && code != "" {
				if code == "0" {
					in.superviseExit(nil)
				} else {
					in.superviseExit(fmt.Errorf("container exited with status %s", code))
				}
				return
			}
			// wait failed or returned nothing: only a genuine exit if the
			// container is actually gone; otherwise a transient CLI/daemon error.
			if !dockerContainerRunning(docker, rec.Container) {
				in.superviseExit(nil)
				return
			}
			time.Sleep(2 * time.Second) // transient — retry the wait
		}
	}()
	return true
}
