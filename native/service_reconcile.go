package main

// Service boot reconciliation.
//
// A new session resolves every registry record under role service:<id> BEFORE
// any desired-state start runs (7.3):
//
//   - exact-owned live resources are ADOPTED into their Service runtime —
//     identity is (pid, start-µs, comm) for host processes and the exact
//     io.redimos.* label quartet for containers; a matching name or a recycled
//     pid is never proof (7.4, 7.8);
//   - everything else drops its record, and a verified-own process is stopped
//     so it cannot hold a port the Service wants to (re)start on; containers
//     whose labels don't match are left alone — they are not provably ours;
//   - after the claim pass, svcAutoStartAll starts every Service whose
//     desiredRunning is true and that was not adopted, each independently —
//     one Service's recovery failure never blocks another (7.5, 7.6, 7.7).
//
// The legacy singleton ddb is handled in reconcile.go (version-gated out).

import (
	"os"
	"os/exec"
	"sync"
	"time"
)

// tryAdoptService claims one surviving Service child recorded under
// role service:<id>. Returns the adopted container name (sweep skip), or "".
// Runs inside reconcileOnBoot: synchronous, under the single-instance lock.
func (m *manager) tryAdoptService(rec childRec, id string) string {
	m.mu.Lock()
	scPtr, _ := findService(m.st.Services, id)
	var sc ServiceConfig
	if scPtr != nil {
		sc = *scPtr
	}
	m.mu.Unlock()

	rt, live := m.svcRuntime(id)
	if !live || scPtr == nil {
		// The Service config is gone: drop the record. A verified-own process
		// is stopped (it would hold a port nobody owns anymore); an unproven
		// container is left alone — without the config there is no label
		// baseline to prove ownership, and deleting on suspicion is worse.
		if rec.Container == "" {
			if start, comm, ok := procIdentity(rec.PID); ok && start == rec.StartUnixMicro && comm == rec.Comm {
				killChildTree(rec.PID)
			}
		}
		regRemove(rec.Role)
		return ""
	}

	ad, err := serviceEngineFor(sc.Engine)
	if err != nil {
		regRemove(rec.Role) // unknown engine in persisted data: fail closed
		return ""
	}

	if rec.Container == "" {
		m.adoptServiceProcess(rt, ad, rec, sc)
		return ""
	}
	return m.adoptServiceContainer(rt, ad, rec, sc)
}

// adoptServiceProcess adopts a java-engine Service child after re-verifying
// its exact recorded identity (the PID-reuse guard) and that the config still
// describes the same launch (engine kind + port).
func (m *manager) adoptServiceProcess(rt *serviceRuntime, ad serviceEngine, rec childRec, sc ServiceConfig) {
	start, comm, ok := procIdentity(rec.PID)
	if !ok || start != rec.StartUnixMicro || comm != rec.Comm {
		regRemove(rec.Role) // dead, or the pid was recycled by a stranger (7.8)
		return
	}
	if sc.Engine != ServiceEngineJava || rec.Port != sc.Port {
		// Provably ours but the config moved on: stop it so the fresh start
		// under the current config can own the port.
		killChildTree(rec.PID)
		regRemove(rec.Role)
		return
	}

	in := rt.instance()
	rt.opMu.Lock()
	defer rt.opMu.Unlock()
	if rt.gone {
		regRemove(rec.Role)
		return
	}
	in.mu.Lock()
	switch in.status {
	case "running", "preparing", "restarting":
		in.mu.Unlock()
		return // already live this session (a later reconcile call): leave it
	}
	in.pid, in.startMicro = rec.PID, rec.StartUnixMicro
	in.status = "running"
	in.port, in.role = sc.Port, serviceRole(sc.ID)
	in.detached, in.autoRestart, in.adopted = true, true, true
	in.started = time.UnixMicro(rec.StartUnixMicro)
	in.launchEnv = os.Environ()
	in.bin = rec.Bin
	in.mu.Unlock()

	// Rebuild the launch spec from the CURRENT config so a later supervised
	// restart (or stop-then-start) re-runs it verbatim. java missing from the
	// machine is not fatal: the live process still serves; keep the recorded
	// bin so identity checks stay exact.
	if spec, err := ad.buildLaunch(m, sc); err == nil {
		in.mu.Lock()
		in.bin, in.launchArgs, in.wd = spec.bin, spec.args, spec.dir
		in.mu.Unlock()
	}
	in.appendLog(adoptionBanner(rec))

	rec.Session = m.sessionID
	regUpsert(rec) // re-owned by this session (re-adoptable if we crash too)
	in.superviseWG.Add(1)
	watchProcessExit(rec.PID, rec.StartUnixMicro, func(err error) {
		defer in.superviseWG.Done()
		// Adopted child: in.started is its original cross-session start, so
		// this is how long it actually ran — a long-lived adopted Service that
		// exits reads as a healthy exit (counter reset), not a startup failure.
		in.superviseExit(err, time.Since(in.started))
	})
}

// adoptServiceContainer adopts a containerised Service child after proving
// ownership by the exact label quartet (never by name) and that the config
// still matches. Returns the adopted container name.
func (m *manager) adoptServiceContainer(rt *serviceRuntime, ad serviceEngine, rec childRec, sc ServiceConfig) string {
	name := serviceContainerName(sc.Engine, sc.ID)
	if rec.Container != name {
		regRemove(rec.Role) // stale record naming a container we never derive
		return ""
	}
	docker, ok := svcDockerBin()
	if !ok {
		regRemove(rec.Role) // cannot prove anything without docker
		return ""
	}
	exists, owned, running := inspectServiceContainer(docker, name, sc)
	if !exists || !owned {
		// Gone, or a stranger holds the name: adoption needs the exact labels
		// (7.8). A stranger container is left running — it is not provably
		// ours, and the Service's next start reports the conflict instead.
		regRemove(rec.Role)
		return ""
	}
	if !running {
		regRemove(rec.Role) // exited: the desired-state pass restarts if wanted
		return ""
	}
	if rec.Port != sc.Port {
		// Provably ours but mapped for an old port: remove it so the fresh
		// start under the current config owns the right mapping.
		_ = exec.Command(docker, "rm", "-f", name).Run()
		regRemove(rec.Role)
		return ""
	}

	in := rt.instance()
	rt.opMu.Lock()
	defer rt.opMu.Unlock()
	if rt.gone {
		regRemove(rec.Role)
		return ""
	}
	in.mu.Lock()
	switch in.status {
	case "running", "preparing", "restarting":
		in.mu.Unlock()
		return name // already live this session
	}
	in.status = "running"
	in.port, in.role = sc.Port, serviceRole(sc.ID)
	in.container, in.bin = name, docker
	in.detached, in.autoRestart, in.adopted = true, true, true
	in.started = time.UnixMicro(rec.StartUnixMicro)
	in.launchEnv = os.Environ()
	in.mu.Unlock()

	// Rebuild the launch args so a supervised restart re-runs the Service as a
	// fully-owned fresh container.
	if spec, err := ad.buildLaunch(m, sc); err == nil {
		in.mu.Lock()
		in.launchArgs = spec.args
		in.mu.Unlock()
	}
	in.appendLog(adoptionBanner(rec))

	rec.Session = m.sessionID
	rec.Bin = docker
	regUpsert(rec)
	pumpDockerLogs(docker, name, in)
	watchDockerExit(docker, name, in)
	return name
}

// svcAutoStartAll restores the Services desired-state set after the claim
// pass: every ServiceConfig with desiredRunning=true that was NOT adopted
// starts on its own goroutine — Services are independent entities, and one
// Service's recovery failure is recorded on THAT Service's state and never
// blocks another (7.5, 7.6, 7.7). desiredRunning=false never auto-starts.
func (m *manager) svcAutoStartAll() {
	m.mu.Lock()
	cands := make([]string, 0, len(m.st.Services))
	for _, sc := range m.st.Services {
		if sc.DesiredRunning {
			cands = append(cands, sc.ID)
		}
	}
	m.mu.Unlock()

	var wg sync.WaitGroup
	for _, id := range cands {
		st, ok := m.svcStatus(id)
		if !ok {
			continue
		}
		switch st {
		case "running", "preparing", "restarting":
			continue // adopted or already live (7.4): never launch a duplicate
		}
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			// startService records its own failure on the Service's status and
			// exit message, where the UI reads it; the list ABI additionally
			// surfaces it in errors[] (recovery_failed, 7.6).
			if err := m.startService(id); err != nil {
				m.recordRecoveryError(id, err)
			}
		}(id)
	}
	wg.Wait()
}
