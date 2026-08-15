package main

// Stage 6 tests: registry-backed boot reconciliation for Services — exact
// adoption (process identity / label quartet), stranger rejection, orphan
// cleanup, legacy-ddb suppression, desired-state restore, and the simulated
// app-restart smoke (6.4, 6.5).

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// plantServiceConfig registers a ServiceConfig on a bare manager (no
// validation/persist — reconcile tests only need the in-memory truth).
func plantServiceConfig(t *testing.T, m *manager, sc ServiceConfig) {
	t.Helper()
	m.mu.Lock()
	m.st.Services = append(m.st.Services, sc)
	m.mu.Unlock()
	m.svcEnsureRuntime(sc.ID)
}

// startSleep launches a real `sleep` child and returns its exact identity.
// The deferred kill/wait keeps a leaked child from outliving the test.
func startSleep(t *testing.T) (*exec.Cmd, int, int64, string) {
	t.Helper()
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	})
	pid := cmd.Process.Pid
	start, comm, ok := procIdentity(pid)
	if !ok {
		t.Fatalf("procIdentity failed for fresh sleep pid %d", pid)
	}
	return cmd, pid, start, comm
}

// hasRecord reports whether the registry still carries role.
func hasRecord(t *testing.T, role string) (childRec, bool) {
	t.Helper()
	for _, rec := range regSnapshot() {
		if rec.Role == role {
			return rec, true
		}
	}
	return childRec{}, false
}

// waitSvcSettled waits until the Service reaches a terminal status AND its
// exit path finished the terminal registry write: superviseExit flips the
// status slightly BEFORE regRemove, and test cleanups restore the registry
// sandbox global — settling on status alone would race the cleanup.
func waitSvcSettled(t *testing.T, m *manager, id string) {
	t.Helper()
	waitFor(t, id+" settles", func() bool {
		switch s, _ := m.svcStatus(id); s {
		case "stopped", "failed", "error":
		default:
			return false
		}
		_, ok := hasRecord(t, serviceRole(id))
		return !ok
	})
}

// ---------------------------------------------------------------------------
// 6.4 process adoption
// ---------------------------------------------------------------------------

func TestReconcileAdoptsLiveServiceProcess(t *testing.T) {
	sandboxRegistry(t)
	overrideSvcBins(t, "", writeScript(t, "#!/bin/bash\nexit 0\n")) // java for spec rebuild
	m := mkManager(t)
	m.sessionID = "sess-new"

	port := freePort(t)
	sc := svc("adopt-proc", ServiceEngineJava, port, ServiceStorage{Mode: ServiceStorageMemory}, nil)
	plantServiceConfig(t, m, sc)

	_, pid, start, comm := startSleep(t)
	regUpsert(childRec{Role: serviceRole(sc.ID), PID: pid, StartUnixMicro: start, Comm: comm, Port: port, Bin: "/opt/java", Session: "sess-old"})

	m.reconcileOnBoot()

	rt, live := m.svcRuntime(sc.ID)
	if !live {
		t.Fatal("runtime vanished after adoption")
	}
	in := rt.instance()
	in.mu.Lock()
	status, adopted, gotPid, gotRole := in.status, in.adopted, in.pid, in.role
	in.mu.Unlock()
	if status != "running" || !adopted || gotPid != pid {
		t.Fatalf("adoption state = %q adopted=%v pid=%d; want running/true/%d", status, adopted, gotPid, pid)
	}
	if gotRole != serviceRole(sc.ID) {
		t.Errorf("adopted instance role = %q", gotRole)
	}
	rec, ok := hasRecord(t, serviceRole(sc.ID))
	if !ok {
		t.Fatal("registry record dropped during adoption")
	}
	if rec.Session != "sess-new" {
		t.Errorf("adopted record session = %q; want re-owned sess-new", rec.Session)
	}

	// Teardown: terminate the adopted child; the kqueue watcher must settle it.
	in.terminate()
	waitSvcSettled(t, m, sc.ID)
	in.superviseWG.Wait() // sync edge: cleanup may now restore the sandbox
	if _, ok := hasRecord(t, serviceRole(sc.ID)); ok {
		t.Error("registry record must be removed after the adopted child stops")
	}
}

func TestReconcileRejectsRecycledPID(t *testing.T) {
	sandboxRegistry(t)
	m := mkManager(t)

	port := freePort(t)
	sc := svc("recycled", ServiceEngineJava, port, ServiceStorage{Mode: ServiceStorageMemory}, nil)
	plantServiceConfig(t, m, sc)

	_, pid, start, comm := startSleep(t)
	// Wrong start time = the pid was recycled by a stranger (7.8).
	regUpsert(childRec{Role: serviceRole(sc.ID), PID: pid, StartUnixMicro: start + 424242, Comm: comm, Port: port, Session: "sess-old"})

	m.reconcileOnBoot()

	mustStatus(t, m, sc.ID, "stopped")
	if _, ok := hasRecord(t, serviceRole(sc.ID)); ok {
		t.Error("recycled-pid record must be dropped")
	}
	rt, _ := m.svcRuntime(sc.ID)
	rt.instance().mu.Lock()
	adopted := rt.instance().adopted
	rt.instance().mu.Unlock()
	if adopted {
		t.Error("recycled pid must never be adopted")
	}
}

func TestReconcileKillsProcessAfterConfigDrift(t *testing.T) {
	sandboxRegistry(t)
	m := mkManager(t)

	sc := svc("drift", ServiceEngineJava, freePort(t), ServiceStorage{Mode: ServiceStorageMemory}, nil)
	plantServiceConfig(t, m, sc)

	cmd, pid, start, comm := startSleep(t)
	// Provably ours, but recorded for a different port than the config now has.
	regUpsert(childRec{Role: serviceRole(sc.ID), PID: pid, StartUnixMicro: start, Comm: comm, Port: sc.Port + 1, Session: "sess-old"})

	m.reconcileOnBoot()

	waitFor(t, "drifted process killed", func() bool {
		_, _, ok := procIdentity(pid)
		return !ok
	})
	_, _ = cmd.Process.Wait()
	if _, ok := hasRecord(t, serviceRole(sc.ID)); ok {
		t.Error("drifted record must be dropped")
	}
	mustStatus(t, m, sc.ID, "stopped")
}

// ---------------------------------------------------------------------------
// 6.4 container adoption & ownership
// ---------------------------------------------------------------------------

// seedOwnedContainer writes the canned inspect answer for a container owned by
// sc and running, exactly as the live daemon would present it.
func seedOwnedContainer(t *testing.T, state string, sc ServiceConfig, owned, running bool) string {
	t.Helper()
	name := serviceContainerName(sc.Engine, sc.ID)
	labels := map[string]string{}
	if owned {
		for _, kv := range serviceLabelPairs(sc) {
			i := strings.IndexByte(kv, '=')
			labels[kv[:i]] = kv[i+1:]
		}
	} else {
		labels = map[string]string{
			"io.redimos.managed":    "true",
			"io.redimos.entity":     "service",
			"io.redimos.service-id": "someone-else",
			"io.redimos.engine":     string(sc.Engine),
		}
	}
	lb, err := json.Marshal(labels)
	if err != nil {
		t.Fatal(err)
	}
	run := "false"
	if running {
		run = "true"
	}
	if err := os.WriteFile(filepath.Join(state, "container-"+name+".inspect"), append(lb, []byte("|"+run)...), 0o644); err != nil {
		t.Fatal(err)
	}
	return name
}

func TestReconcileAdoptsOwnedServiceContainer(t *testing.T) {
	sandboxRegistry(t)
	fake, state := fakeDocker(t)
	overrideSvcBins(t, fake, "")
	m := mkManager(t)
	m.sessionID = "sess-new"

	sc := svc("adopt-cont", ServiceEngineDockerDDB, freePort(t), ServiceStorage{Mode: ServiceStorageMemory}, nil)
	plantServiceConfig(t, m, sc)
	name := seedOwnedContainer(t, state, sc, true, true)
	regUpsert(childRec{Role: serviceRole(sc.ID), StartUnixMicro: 1000, Port: sc.Port, Container: name, Bin: fake, Session: "sess-old"})

	adopted := m.reconcileOnBoot()
	if !adopted[name] {
		t.Fatalf("reconcile did not report adopting %s", name)
	}
	rt, live := m.svcRuntime(sc.ID)
	if !live {
		t.Fatal("runtime vanished after adoption")
	}
	in := rt.instance()
	in.mu.Lock()
	status, adoptedFlag, gotCont := in.status, in.adopted, in.container
	in.mu.Unlock()
	if status != "running" || !adoptedFlag || gotCont != name {
		t.Fatalf("container adoption = %q adopted=%v cont=%q; want running/true/%s", status, adoptedFlag, gotCont, name)
	}
	if calls := readCalls(t, state); strings.Contains(calls, "run ") {
		t.Error("adoption must never launch a duplicate container")
	}
	rec, ok := hasRecord(t, serviceRole(sc.ID))
	if !ok || rec.Session != "sess-new" || rec.Bin != fake {
		t.Errorf("adopted container record = %+v; want session sess-new, bin %s", rec, fake)
	}

	// Teardown: terminate issues `rm -f`, the docker-wait watcher observes it
	// and settles the instance through the supervisor.
	in.terminate()
	waitSvcSettled(t, m, sc.ID)
	in.superviseWG.Wait() // sync edge: cleanup may now restore the sandbox
}

func TestReconcileRejectsStrangerContainerAndStartFails(t *testing.T) {
	sandboxRegistry(t)
	fake, state := fakeDocker(t)
	overrideSvcBins(t, fake, "")
	m := mkManager(t)

	sc := svc("stranger", ServiceEngineDockerDDB, freePort(t), ServiceStorage{Mode: ServiceStorageMemory}, nil)
	plantServiceConfig(t, m, sc)
	name := seedOwnedContainer(t, state, sc, false, true) // same name, foreign labels
	regUpsert(childRec{Role: serviceRole(sc.ID), StartUnixMicro: 1000, Port: sc.Port, Container: name, Session: "sess-old"})

	adopted := m.reconcileOnBoot()
	if adopted[name] {
		t.Fatal("stranger container must never be adopted")
	}
	mustStatus(t, m, sc.ID, "stopped")
	if _, ok := hasRecord(t, serviceRole(sc.ID)); ok {
		t.Error("record for a stranger-held name must be dropped")
	}
	if calls := readCalls(t, state); strings.Contains(calls, "rm ") {
		t.Error("stranger container must be left alone, not removed")
	}

	// The Service's next start reports the conflict instead of hijacking the name.
	err := m.startService(sc.ID)
	if err == nil || !strings.Contains(err.Error(), "resource_unowned") {
		t.Fatalf("start over a stranger container = %v; want resource_unowned", err)
	}
	mustStatus(t, m, sc.ID, "failed")
}

func TestReconcileOrphanRecordWithoutConfig(t *testing.T) {
	sandboxRegistry(t)
	m := mkManager(t)

	cmd, pid, start, comm := startSleep(t)
	regUpsert(childRec{Role: serviceRole("ghost"), PID: pid, StartUnixMicro: start, Comm: comm, Port: 9999, Session: "sess-old"})

	m.reconcileOnBoot()

	// Verified-own process is stopped (it would hold a port nobody owns)...
	waitFor(t, "orphan process killed", func() bool {
		_, _, ok := procIdentity(pid)
		return !ok
	})
	_, _ = cmd.Process.Wait()
	// ...and the record is dropped.
	if _, ok := hasRecord(t, serviceRole("ghost")); ok {
		t.Error("orphan record must be dropped")
	}
}

// ---------------------------------------------------------------------------
// 6.4 legacy singleton ddb suppression (7.9)
// ---------------------------------------------------------------------------

// TestLegacyDdbProcessSuppression covers a native legacy ddb child: stopped
// without revival, migration notice recorded (7.9). The registry is keyed by
// role and the legacy ddb was a singleton, so the process and container cases
// are separate tests.
func TestLegacyDdbProcessSuppression(t *testing.T) {
	sandboxRegistry(t)
	m := mkManager(t)

	cmd, pid, start, comm := startSleep(t)
	regUpsert(childRec{Role: "ddb", PID: pid, StartUnixMicro: start, Comm: comm, Port: 8000, Session: "sess-old"})

	m.reconcileOnBoot()

	waitFor(t, "legacy ddb process killed", func() bool {
		_, _, ok := procIdentity(pid)
		return !ok
	})
	_, _ = cmd.Process.Wait()
	if _, ok := hasRecord(t, "ddb"); ok {
		t.Error("legacy ddb record must be dropped")
	}
	m.mu.Lock()
	notice := m.legacyDdbMigrationNotice
	m.mu.Unlock()
	if notice != legacyDdbMigrationNoticeText {
		t.Errorf("migration notice = %q; want the legacy-ddb text", notice)
	}
}

// TestLegacyDdbContainerSuppression covers a container legacy ddb child: record
// dropped, notice recorded, never revived (7.9). The daemon answer is canned
// "running" so the notice path fires deterministically.
func TestLegacyDdbContainerSuppression(t *testing.T) {
	sandboxRegistry(t)
	fake, state := fakeDocker(t)
	overrideSvcBins(t, fake, "")
	m := mkManager(t)

	if err := os.WriteFile(filepath.Join(state, "container-redimos-local-ddb.inspect"), []byte("{}|true"), 0o644); err != nil {
		t.Fatal(err)
	}
	regUpsert(childRec{Role: "ddb", StartUnixMicro: 1000, Port: 8001, Container: "redimos-local-ddb", Session: "sess-old"})

	m.reconcileOnBoot()

	if _, ok := hasRecord(t, "ddb"); ok {
		t.Error("legacy ddb record must be dropped")
	}
	m.mu.Lock()
	notice := m.legacyDdbMigrationNotice
	m.mu.Unlock()
	if notice != legacyDdbMigrationNoticeText {
		t.Errorf("migration notice = %q; want the legacy-ddb text", notice)
	}
	if calls := readCalls(t, state); strings.Contains(calls, "run ") {
		t.Error("legacy ddb must never be revived")
	}
}

// ---------------------------------------------------------------------------
// 6.4 desired-state restore
// ---------------------------------------------------------------------------

func TestSvcAutoStartAllRestoresDesiredOnly(t *testing.T) {
	m, state := lifecycleSetup(t)

	a := createDockerService(t, m, "want-a", freePort(t))
	b := createDockerService(t, m, "want-b", freePort(t))
	c := createDockerService(t, m, "want-c", freePort(t))
	if err := m.persistDesired(a.ID, true); err != nil {
		t.Fatal(err)
	}
	// C simulates a Service already adopted by the claim pass.
	inC := m.svcEnsureRuntime(c.ID).instance()
	inC.mu.Lock()
	inC.status = "running"
	inC.mu.Unlock()

	m.svcAutoStartAll()

	mustStatus(t, m, a.ID, "running")
	mustStatus(t, m, b.ID, "stopped") // desired=false never auto-starts
	mustStatus(t, m, c.ID, "running")

	nameA, nameB, nameC := serviceContainerName(a.Engine, a.ID), serviceContainerName(b.Engine, b.ID), serviceContainerName(c.Engine, c.ID)
	for _, line := range strings.Split(readCalls(t, state), "\n") {
		if !strings.HasPrefix(line, "run ") {
			continue
		}
		if strings.Contains(line, nameB) {
			t.Error("desired=false Service must not be started")
		}
		if strings.Contains(line, nameC) {
			t.Error("already-running Service must not be started twice")
		}
		if !strings.Contains(line, nameA) {
			t.Errorf("unexpected run call: %s", line)
		}
	}

	if err := m.stopService(a.ID, false); err != nil {
		t.Fatal(err)
	}
	waitSvcSettled(t, m, a.ID)
	m.svcEnsureRuntime(a.ID).instance().superviseWG.Wait()
}

// ---------------------------------------------------------------------------
// 6.5 simulated app-restart smoke
// ---------------------------------------------------------------------------

// TestRestartRecoversServices replays a manager crash: session 1 creates and
// runs three Services, then "dies" with A and C desired; A's container
// survives. Session 2 must adopt the survivor, start the missing C, and leave
// B (desired=false) alone — no duplicate launches anywhere.
func TestRestartRecoversServices(t *testing.T) {
	sandboxRegistry(t)
	fake, state := fakeDocker(t)
	overrideSvcBins(t, fake, "")
	probeStub(t, portUpProbe(state))

	// ---- session 1 ----
	m1 := mkManager(t)
	a := createDockerService(t, m1, "ddb-a", freePort(t))
	b := createDockerService(t, m1, "ddb-b", freePort(t))
	c := createDockerService(t, m1, "ddb-c", freePort(t))
	for _, sc := range []ServiceConfig{a, b, c} {
		if err := m1.startService(sc.ID); err != nil {
			t.Fatalf("session1 start %s: %v", sc.ID, err)
		}
	}
	for _, sc := range []ServiceConfig{a, b, c} {
		if err := m1.stopService(sc.ID, false); err != nil {
			t.Fatalf("session1 stop %s: %v", sc.ID, err)
		}
		waitSvcSettled(t, m1, sc.ID)
		m1.svcEnsureRuntime(sc.ID).instance().superviseWG.Wait()
	}
	// Desired state that survives the crash: A and C should run, B should not.
	if err := m1.persistDesired(a.ID, true); err != nil {
		t.Fatal(err)
	}
	if err := m1.persistDesired(c.ID, true); err != nil {
		t.Fatal(err)
	}

	// A's container survives the crash: re-arm its ownership evidence exactly
	// as the live daemon would present it.
	nameA := seedOwnedContainer(t, state, a, true, true)
	regUpsert(childRec{Role: serviceRole(a.ID), StartUnixMicro: 1000, Port: a.Port, Container: nameA, Bin: fake, Session: "s1"})

	// ---- session 2 ----
	m2 := &manager{storePath: m1.storePath, sessionID: "s2"}
	m2.load()
	callsBefore := readCalls(t, state)

	adopted := m2.reconcileOnBoot()
	if !adopted[nameA] {
		t.Fatalf("session2 did not adopt surviving container %s", nameA)
	}
	rtA, _ := m2.svcRuntime(a.ID)
	inA := rtA.instance()
	inA.mu.Lock()
	stA, adoptedFlag := inA.status, inA.adopted
	inA.mu.Unlock()
	if stA != "running" || !adoptedFlag {
		t.Fatalf("survivor state after claim = %q adopted=%v; want running/true", stA, adoptedFlag)
	}
	if rec, ok := hasRecord(t, serviceRole(a.ID)); !ok || rec.Session != "s2" {
		t.Fatalf("survivor record not re-owned by session2: %+v %v", rec, ok)
	}

	m2.svcAutoStartAll()
	mustStatus(t, m2, a.ID, "running") // adopted, not restarted
	mustStatus(t, m2, c.ID, "running") // missing → restored
	mustStatus(t, m2, b.ID, "stopped") // desired=false stays down

	nameC := serviceContainerName(c.Engine, c.ID)
	newCalls := strings.TrimPrefix(readCalls(t, state), callsBefore)
	runsA, runsC := 0, 0
	for _, line := range strings.Split(newCalls, "\n") {
		if !strings.HasPrefix(line, "run ") {
			continue
		}
		if strings.Contains(line, nameA) {
			runsA++
		}
		if strings.Contains(line, nameC) {
			runsC++
		}
	}
	if runsA != 0 {
		t.Errorf("adopted survivor was relaunched %d time(s)", runsA)
	}
	if runsC != 1 {
		t.Errorf("missing Service C launched %d time(s); want exactly 1", runsC)
	}

	// Teardown: terminate the adopted survivor; stop the restored Service.
	inA.terminate()
	if err := m2.stopService(c.ID, false); err != nil {
		t.Fatal(err)
	}
	waitSvcSettled(t, m2, a.ID)
	waitSvcSettled(t, m2, c.ID)
	inA.superviseWG.Wait() // sync edge: cleanup may now restore the sandbox
	m2.svcEnsureRuntime(c.ID).instance().superviseWG.Wait()
}
