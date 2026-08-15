package main

// Stage 7 tests: unified Stop All / Restore All over Instances AND Services —
// typed snapshot, temporary Service stops (desiredRunning untouched),
// per-entity results, missing/failed handling, and persistence (7.4, 7.5).

import (
	"reflect"
	"strings"
	"testing"
)

// plantInstance registers a legacy Instance config plus a live runtime entry.
// Status "restarting" models a live-but-between-spawns Instance: it is active
// for the snapshot, and terminate() settles it synchronously without needing
// a supervised child.
func plantInstance(t *testing.T, m *manager, id string) {
	t.Helper()
	m.mu.Lock()
	if m.running == nil {
		m.running = map[string]*instance{}
	}
	m.st.Configs = append(m.st.Configs, Config{ID: id, Name: "inst-" + id, Port: freePort(t)})
	m.running[id] = &instance{status: "restarting", role: "config:" + id}
	m.mu.Unlock()
}

func hasRef(refs []EntityRef, kind, id string) bool {
	for _, r := range refs {
		if r.Kind == kind && r.ID == id {
			return true
		}
	}
	return false
}

func hasFailure(fs []EntityFailure, kind, id string) bool {
	for _, f := range fs {
		if f.Kind == kind && f.ID == id {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// 7.4 unit / edge coverage
// ---------------------------------------------------------------------------

func TestStopAllUnifiedSnapshotsBothKinds(t *testing.T) {
	m, _ := lifecycleSetup(t)

	sv := createDockerService(t, m, "ddb-one", freePort(t))
	if err := m.startService(sv.ID); err != nil {
		t.Fatal(err)
	}
	plantInstance(t, m, "inst-1")

	res := m.stopAllUnified()

	// 8.1: snapshot taken before stops, typed by entity kind.
	if !reflect.DeepEqual(res.Snapshot.Instances, []string{"inst-1"}) {
		t.Errorf("instance snapshot = %v", res.Snapshot.Instances)
	}
	if !reflect.DeepEqual(res.Snapshot.Services, []string{sv.ID}) {
		t.Errorf("service snapshot = %v", res.Snapshot.Services)
	}
	if !hasRef(res.Stopped, entityKindInstance, "inst-1") || !hasRef(res.Stopped, entityKindService, sv.ID) {
		t.Errorf("stopped = %+v; want both entities", res.Stopped)
	}
	if len(res.Failed) != 0 {
		t.Errorf("failed = %+v; want none", res.Failed)
	}
	mustStatus(t, m, sv.ID, "stopped")

	// 8.5: the temporary Service stop must NOT rewrite desiredRunning.
	if !desiredOf(t, m, sv.ID) {
		t.Error("Stop All rewrote the Service's long-term desiredRunning")
	}
	// Instance boot set cleared (legacy semantics); snapshot persisted.
	m.mu.Lock()
	autoStart, persisted := append([]string{}, m.st.AutoStart...), m.st.StopAllSnapshotV2
	m.mu.Unlock()
	if len(autoStart) != 0 {
		t.Errorf("AutoStart after Stop All = %v; want cleared", autoStart)
	}
	if !reflect.DeepEqual(persisted, res.Snapshot) {
		t.Errorf("persisted snapshot = %+v; want %+v", persisted, res.Snapshot)
	}
	m.svcEnsureRuntime(sv.ID).instance().superviseWG.Wait() // sync edge for cleanup
}

func TestStopAllPartialFailureReported(t *testing.T) {
	m, _ := lifecycleSetup(t)
	sv := createDockerService(t, m, "ddb-fail-stop", freePort(t))
	if err := m.startService(sv.ID); err != nil {
		t.Fatal(err)
	}
	// Force the stop to miss its settle window: the Service then reports a
	// failure while the snapshot still covers it (8.2 partial failure).
	old := svcStopTimeout
	svcStopTimeout = 1
	t.Cleanup(func() { svcStopTimeout = old })

	res := m.stopAllUnified()

	if !hasFailure(res.Failed, entityKindService, sv.ID) {
		t.Fatalf("failed = %+v; want the unsettled Service reported", res.Failed)
	}
	if len(res.Stopped) != 0 {
		t.Errorf("stopped = %+v; want none", res.Stopped)
	}
	waitSvcSettled(t, m, sv.ID) // the stop still lands asynchronously
	m.svcEnsureRuntime(sv.ID).instance().superviseWG.Wait()
}

func TestRestoreAllEmptySnapshot(t *testing.T) {
	m := mkManager(t)
	res := m.restoreAllUnified()
	if len(res.Restored) != 0 || len(res.Failed) != 0 || len(res.Missing) != 0 {
		t.Errorf("empty snapshot restore = %+v; want all-empty", res)
	}
}

func TestRestoreAllMissingAndFailedEntities(t *testing.T) {
	m, _ := lifecycleSetup(t)

	svcOK := createDockerService(t, m, "ddb-ok", freePort(t))
	svcGone := createDockerService(t, m, "ddb-gone", freePort(t))
	if err := m.startService(svcOK.ID); err != nil {
		t.Fatal(err)
	}
	if err := m.startService(svcGone.ID); err != nil {
		t.Fatal(err)
	}
	plantInstance(t, m, "inst-kept") // config exists but cannot start here

	res := m.stopAllUnified()
	if len(res.Failed) != 0 {
		t.Fatalf("stop failed = %+v", res.Failed)
	}
	// Capture the deleted Service's runtime BEFORE retiring it (retire drops it
	// from the runtime map; its supervise goroutines must stay joinable).
	waitSvcSettled(t, m, svcGone.ID)
	goneInst := m.svcEnsureRuntime(svcGone.ID).instance()
	// Delete one Service after the snapshot: restore must report it and go on.
	// (The full safe-delete lands in Stage 8; excising the config + retiring
	// the runtime is the deletion's observable end state.)
	m.mu.Lock()
	if sc, idx := findService(m.st.Services, svcGone.ID); sc != nil {
		m.st.Services = append(m.st.Services[:idx], m.st.Services[idx+1:]...)
	}
	m.mu.Unlock()
	if rt, ok := m.svcRuntime(svcGone.ID); ok {
		rt.opMu.Lock()
		m.svcRetire(svcGone.ID, rt)
		rt.opMu.Unlock()
	}

	res2 := m.restoreAllUnified()

	if !hasRef(res2.Restored, entityKindService, svcOK.ID) {
		t.Errorf("restored = %+v; want the surviving Service", res2.Restored)
	}
	if !hasRef(res2.Missing, entityKindService, svcGone.ID) {
		t.Errorf("missing = %+v; want the deleted Service reported", res2.Missing)
	}
	// The Instance cannot start in the sandbox (no real binary): reported
	// failed AND kept in the snapshot for retry.
	if !hasFailure(res2.Failed, entityKindInstance, "inst-kept") {
		t.Errorf("failed = %+v; want the unstartable Instance", res2.Failed)
	}
	m.mu.Lock()
	keep := m.st.StopAllSnapshotV2
	m.mu.Unlock()
	if !reflect.DeepEqual(keep.Instances, []string{"inst-kept"}) || len(keep.Services) != 0 {
		t.Errorf("retry snapshot = %+v; want only the failed Instance kept", keep)
	}
	mustStatus(t, m, svcOK.ID, "running")

	if err := m.stopService(svcOK.ID, false); err != nil {
		t.Fatal(err)
	}
	waitSvcSettled(t, m, svcOK.ID)
	m.svcEnsureRuntime(svcOK.ID).instance().superviseWG.Wait()
	goneInst.superviseWG.Wait()
}

func TestRestoreAllCrossKindSameID(t *testing.T) {
	// One ID existing in BOTH namespaces must never confuse the restore: each
	// kind resolves in its own namespace (snapshot keeps them apart).
	m, _ := lifecycleSetup(t)

	const dup = "dup-id"
	sc := svc(dup, ServiceEngineDockerDDB, freePort(t), ServiceStorage{Mode: ServiceStorageMemory}, nil)
	plantServiceConfig(t, m, sc)
	plantInstance(t, m, dup)
	if err := m.startService(dup); err != nil {
		t.Fatal(err)
	}

	res := m.stopAllUnified()
	if !hasRef(res.Stopped, entityKindInstance, dup) || !hasRef(res.Stopped, entityKindService, dup) {
		t.Fatalf("stopped = %+v; want BOTH kinds under the same ID", res.Stopped)
	}
	res2 := m.restoreAllUnified()
	// Service restored; Instance cannot start in the sandbox (failed + kept).
	if !hasRef(res2.Restored, entityKindService, dup) {
		t.Errorf("restored = %+v; want the Service half of the dup ID", res2.Restored)
	}
	if !hasFailure(res2.Failed, entityKindInstance, dup) {
		t.Errorf("failed = %+v; want the Instance half of the dup ID", res2.Failed)
	}

	if err := m.stopService(dup, false); err != nil {
		t.Fatal(err)
	}
	waitSvcSettled(t, m, dup)
	m.svcEnsureRuntime(dup).instance().superviseWG.Wait()
}

// ---------------------------------------------------------------------------
// 7.5 Instance+Service smoke across a persistence restart
// ---------------------------------------------------------------------------

func TestStopRestoreAllSmokeAcrossRestart(t *testing.T) {
	sandboxRegistry(t)
	fake, state := fakeDocker(t)
	overrideSvcBins(t, fake, "")
	probeStub(t, portUpProbe(state))

	m1 := mkManager(t)
	sv := createDockerService(t, m1, "ddb-smoke", freePort(t))
	if err := m1.startService(sv.ID); err != nil {
		t.Fatal(err)
	}
	plantInstance(t, m1, "inst-smoke")

	stop := m1.stopAllUnified()
	if len(stop.Failed) != 0 {
		t.Fatalf("stop failed = %+v", stop.Failed)
	}
	if !desiredOf(t, m1, sv.ID) {
		t.Fatal("Stop All rewrote desiredRunning")
	}
	waitSvcSettled(t, m1, sv.ID)
	m1Inst := m1.svcEnsureRuntime(sv.ID).instance() // join session-1's supervise goroutines later

	// App restart: a fresh session loads the persisted typed snapshot.
	m2 := &manager{storePath: m1.storePath, sessionID: "s2"}
	m2.load()
	m2.mu.Lock()
	loaded := m2.st.StopAllSnapshotV2
	m2.mu.Unlock()
	if !reflect.DeepEqual(loaded, stop.Snapshot) {
		t.Fatalf("snapshot did not survive restart: %+v", loaded)
	}

	// Restore All in the new session: the Service comes back up, the Instance
	// is reported (cannot start without a real binary) and kept for retry.
	res := m2.restoreAllUnified()
	if !hasRef(res.Restored, entityKindService, sv.ID) {
		t.Fatalf("restored = %+v; want the Service", res.Restored)
	}
	if !hasFailure(res.Failed, entityKindInstance, "inst-smoke") {
		t.Fatalf("failed = %+v; want the Instance kept for retry", res.Failed)
	}
	mustStatus(t, m2, sv.ID, "running")
	// Only the snapshot entities are touched: nothing else was started.
	if calls := readCalls(t, state); !containsRunFor(calls, serviceContainerName(sv.Engine, sv.ID)) {
		t.Error("restored Service container never launched")
	}

	if err := m2.stopService(sv.ID, false); err != nil {
		t.Fatal(err)
	}
	waitSvcSettled(t, m2, sv.ID)
	m2.svcEnsureRuntime(sv.ID).instance().superviseWG.Wait()
	m1Inst.superviseWG.Wait()
}

// containsRunFor reports whether calls.log carries a `run` call for the named
// container.
func containsRunFor(calls, name string) bool {
	for _, line := range strings.Split(calls, "\n") {
		if strings.HasPrefix(line, "run ") && strings.Contains(line, name) {
			return true
		}
	}
	return false
}
