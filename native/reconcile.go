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
// ours is ADOPTED when it is a Service child (see service_reconcile.go) or a
// still-running docker redimos config, and killed otherwise.
//
// The legacy singleton Local DynamoDB (role "ddb") is version-gated OUT: a
// 1.2 store never persists the legacy lifecycle fields, so this build never
// adopts role-"ddb" children — they are stopped or cleaned without being
// revived, with a one-time migration notice (7.9).
//
// Adoption is the whole point of letting stateful children survive a manager
// crash (`detached`): the default config is an in-memory store, so the orphan
// is carrying the user's dev tables — kill-on-sight would wipe them at the
// exact moment the user tries to resume work. Native redimos children are
// stateless and respawn in milliseconds fully supervised, so for them
// kill-and-restart stays strictly better (an adopted native Go process is also
// a SIGPIPE time bomb once its dead log pipe fills).
//
// Identity is (pid, start-µs, comm) for native children and the exact
// io.redimos.* label quartet for Service containers — the precise replacement
// for the old path-substring heuristic; none of it depends on PPID semantics
// (works unchanged on Windows). Runs once at boot, under the single-instance
// lock.
//
// Returns the container names it adopted so sweepLabeledContainers spares them.
func (m *manager) reconcileOnBoot() map[string]bool {
	adoptedContainers := map[string]bool{}
	for _, rec := range regSnapshot() {
		if id, ok := strings.CutPrefix(rec.Role, serviceRolePrefix); ok {
			if cont := m.tryAdoptService(rec, id); cont != "" {
				adoptedContainers[cont] = true
			}
			continue
		}
		if rec.Container != "" {
			if rec.Role == "ddb" {
				m.cleanLegacyDdbContainer(rec) // version gate: never adopt (7.9)
				continue
			}
			if m.tryAdoptDocker(rec) {
				adoptedContainers[rec.Container] = true
				continue
			}
			// Not adoptable: the label sweep removes the container itself; only
			// the bookkeeping goes here.
			regRemove(rec.Role)
			continue
		}
		if rec.Role == "ddb" {
			m.cleanLegacyDdbProcess(rec) // version gate: never adopt (7.9)
			continue
		}
		start, comm, ok := procIdentity(rec.PID)
		if !ok || start != rec.StartUnixMicro || comm != rec.Comm {
			regRemove(rec.Role) // dead, or the pid was recycled by a stranger
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

// legacyDdbMigrationNoticeText explains the one-time fate of the pre-1.2
// singleton Local DynamoDB: the Service collection supersedes it, so a legacy
// child is stopped at boot instead of adopted. For an in-memory store its
// tables are gone with it — the notice exists so the UI can say so explicitly
// instead of the user discovering a silent loss (7.9).
const legacyDdbMigrationNoticeText = "The legacy single-instance Local DynamoDB is no longer restored: " +
	"it was stopped during the upgrade to Services. If it ran in memory mode its tables " +
	"were lost — create a Service to run a local DynamoDB again."

// cleanLegacyDdbProcess resolves a legacy role-"ddb" process child: identity
// check, then stop without revival (7.9). Adoption is version-gated out — a
// 1.2 store never persists the legacy lifecycle fields, so nothing can revive
// it; the migration notice records the data-loss risk of an in-memory store.
func (m *manager) cleanLegacyDdbProcess(rec childRec) {
	start, comm, ok := procIdentity(rec.PID)
	if !ok || start != rec.StartUnixMicro || comm != rec.Comm {
		regRemove(rec.Role) // dead or recycled — nothing to stop
		return
	}
	m.setLegacyMigrationNotice()
	killChildTree(rec.PID)
	regRemove(rec.Role)
}

// cleanLegacyDdbContainer resolves a legacy role-"ddb" container child: the
// record is dropped and the migration notice recorded; the container itself is
// removed by sweepLabeledContainers (it carries the legacy redimos.manager
// labels). Never adopted (7.9).
func (m *manager) cleanLegacyDdbContainer(rec childRec) {
	if docker, ok := svcDockerBin(); ok && dockerContainerRunning(docker, rec.Container) {
		m.setLegacyMigrationNotice() // a live legacy store is being stopped — say so
	}
	regRemove(rec.Role)
}

// setLegacyMigrationNotice records the one-time legacy-ddb migration notice
// (first writer wins; boot is the only writer today).
func (m *manager) setLegacyMigrationNotice() {
	m.mu.Lock()
	if m.legacyDdbMigrationNotice == "" {
		m.legacyDdbMigrationNotice = legacyDdbMigrationNoticeText
	}
	m.mu.Unlock()
}

// dockerContainerRunning reports whether a container with exactly this name is
// currently running. Bounded: a wedged docker daemon must not hang boot
// reconcile (it runs during dylib load) or the adoption watcher loop.
func dockerContainerRunning(docker, name string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	inspCmd := exec.CommandContext(ctx, docker, "inspect", "-f", "{{.State.Running}}", name)
	hideWindow(inspCmd)
	out, err := inspCmd.Output()
	return err == nil && strings.TrimSpace(string(out)) == "true"
}

// pumpDockerLogs tails a container's history into the instance log. Docker
// keeps history, so adoption even recovers the tail the native path would have
// lost. One shared pipe for both streams, closed on every path — the earlier
// asymmetric StdoutPipe/StderrPipe leaked fds when only the second pipe or
// Start failed.
func pumpDockerLogs(docker, name string, in *instance) {
	logsCmd := exec.Command(docker, "logs", "--tail", "200", "-f", name)
	hideWindow(logsCmd)
	pr, pw, perr := os.Pipe()
	if perr != nil {
		return
	}
	logsCmd.Stdout, logsCmd.Stderr = pw, pw
	if logsCmd.Start() == nil {
		go pump(pr, in)
		go func() { _ = logsCmd.Wait(); _ = pr.Close() }()
	} else {
		_ = pr.Close()
	}
	_ = pw.Close() // the child holds its own dup; the parent's copy isn't needed
}

// watchDockerExit blocks on `docker wait` until the container exits and routes
// the exit through the supervisor — the container analog of cmd.Wait. A
// CLI-side failure (daemon hiccup, socket reset) is NOT an exit: re-check
// liveness and re-arm rather than declaring a spurious exit that would trigger
// a restart.
func watchDockerExit(docker, name string, in *instance) {
	in.superviseWG.Add(1)
	go func() {
		defer in.superviseWG.Done()
		for {
			waitCmd := exec.Command(docker, "wait", name)
			hideWindow(waitCmd)
			out, werr := waitCmd.Output()
			code := strings.TrimSpace(string(out))
			if werr == nil && code != "" {
				if code == "0" {
					in.superviseExit(nil, time.Since(in.started))
				} else {
					in.superviseExit(fmt.Errorf("container exited with status %s", code), time.Since(in.started))
				}
				return
			}
			// wait failed or returned nothing: only a genuine exit if the
			// container is actually gone; otherwise a transient CLI/daemon error.
			if !dockerContainerRunning(docker, name) {
				in.superviseExit(nil, time.Since(in.started))
				return
			}
			time.Sleep(2 * time.Second) // transient — retry the wait
		}
	}()
}

// tryAdoptDocker adopts a container that outlived its session's docker CLI —
// docker children are first-class adoptees: `docker logs --tail -f` recovers
// history the native path loses, `docker wait` returns the true exit code, and
// stats/metrics/terminate were name-addressed all along. Serves config:<id>
// redimos containers only (the legacy ddb singleton is version-gated out by
// the caller; Services have their own adoption path). Adopts only when the
// current config still matches (run-mode docker + same port); otherwise the
// label sweep removes it.
func (m *manager) tryAdoptDocker(rec childRec) bool {
	id, found := strings.CutPrefix(rec.Role, "config:")
	if !found {
		return false // "ddb" is gated out upstream; anything else is unknown
	}
	docker, ok := dockerBin()
	if !ok || !dockerContainerRunning(docker, rec.Container) {
		return false
	}

	m.mu.Lock()
	cfg, _ := m.findConfig(id)
	match := cfg != nil && cfg.RunMode == "docker" && cfg.Port == rec.Port
	autoRestart := cfg != nil && cfg.AutoRestart
	_, alreadyRunning := m.running[id]
	m.mu.Unlock()
	if !match || alreadyRunning {
		return false
	}

	in := &instance{
		port: rec.Port, role: rec.Role, autoRestart: autoRestart, detached: false, adopted: true,
		container: rec.Container, bin: docker, launchEnv: os.Environ(),
		status: "running", started: time.UnixMicro(rec.StartUnixMicro),
	}
	// Rebuild the launch args so a supervised restart re-runs the child as a
	// fully-owned fresh container.
	m.mu.Lock()
	if cfg, _ := m.findConfig(id); cfg != nil {
		if _, args, _, _, err := m.buildDockerLaunch(cfg); err == nil {
			in.launchArgs = args
		}
	}
	m.mu.Unlock()
	in.appendLog(adoptionBanner(rec))

	m.mu.Lock()
	m.running[id] = in
	m.mu.Unlock()

	rec.Session = m.sessionID
	rec.Bin = docker
	regUpsert(rec)
	// Lifetime binding for the stateless adopted redimos container.
	janitorRegister(false, 0, docker, rec.Container)

	pumpDockerLogs(docker, rec.Container, in)
	watchDockerExit(docker, rec.Container, in)
	return true
}
