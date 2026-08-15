package main

import (
	"sync"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Registry basics and fail-closed behavior
// ---------------------------------------------------------------------------

func TestSvcBeginUnknownIDFailsClosed(t *testing.T) {
	m := mkManager(t)
	if _, _, err := m.svcBeginOp("nope"); err != errServiceNotFound {
		t.Fatalf("want errServiceNotFound, got %v", err)
	}
	// Fail closed: no runtime may be conjured for an unknown ID.
	if _, ok := m.svcRuntime("nope"); ok {
		t.Error("unknown id must not create a runtime")
	}
}

func TestSvcEnsureAndStatus(t *testing.T) {
	m := mkManager(t)
	rt := m.svcEnsureRuntime("s1")
	if rt == nil {
		t.Fatal("ensure returned nil")
	}
	if m.svcEnsureRuntime("s1") != rt {
		t.Error("ensure must be idempotent per id")
	}
	st, ok := m.svcStatus("s1")
	if !ok || st != "stopped" {
		t.Errorf("fresh runtime status = %q,%v", st, ok)
	}
	if _, ok := m.svcStatus("nope"); ok {
		t.Error("unknown id must report not-ok")
	}
}

// ---------------------------------------------------------------------------
// Operation lock: same ID serial, different IDs independent
// ---------------------------------------------------------------------------

func TestSvcSameIDOpsSerialize(t *testing.T) {
	m := mkManager(t)
	m.svcEnsureRuntime("s1")

	rt1, gen1, err := m.svcBeginOp("s1")
	if err != nil || gen1 != 1 {
		t.Fatalf("first begin: gen=%d err=%v", gen1, err)
	}

	type result struct {
		gen uint64
		err error
	}
	ch := make(chan result, 1)
	go func() {
		_, gen, err := m.svcBeginOp("s1")
		ch <- result{gen, err}
	}()

	// While the first op holds the lock, the second must NOT proceed.
	select {
	case r := <-ch:
		t.Fatalf("second op ran concurrently: %+v", r)
	case <-time.After(50 * time.Millisecond):
	}

	m.svcEndOp(rt1)
	r := <-ch
	if r.err != nil || r.gen != 2 {
		t.Fatalf("serialized begin: gen=%d err=%v", r.gen, r.err)
	}
}

func TestSvcDifferentIDsRunIndependently(t *testing.T) {
	m := mkManager(t)
	m.svcEnsureRuntime("a")
	m.svcEnsureRuntime("b")

	rtA, _, err := m.svcBeginOp("a")
	if err != nil {
		t.Fatal(err)
	}
	// Holding A's op lock must not block B.
	done := make(chan error, 1)
	go func() {
		rtB, _, err := m.svcBeginOp("b")
		if err == nil {
			m.svcEndOp(rtB)
		}
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("independent op failed: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("op on b blocked by op on a")
	}
	m.svcEndOp(rtA)
}

// ---------------------------------------------------------------------------
// Generation and stale exit callbacks
// ---------------------------------------------------------------------------

// armRunning simulates a successful start under the op lock.
func armRunning(t *testing.T, m *manager, id string, gen uint64, rt *serviceRuntime) {
	t.Helper()
	rt.spawnGen = gen
	in := rt.instance()
	in.mu.Lock()
	in.status = "running"
	in.mu.Unlock()
}

func TestSvcStaleExitCallbackDropped(t *testing.T) {
	m := mkManager(t)
	m.svcEnsureRuntime("s1")

	rt, gen, err := m.svcBeginOp("s1")
	if err != nil {
		t.Fatal(err)
	}
	armRunning(t, m, "s1", gen, rt)
	m.svcEndOp(rt)

	// A callback from an OLDER generation must not touch the current run.
	m.serviceExited("s1", gen-1, "old crash", true)
	if st, _ := m.svcStatus("s1"); st != "running" {
		t.Errorf("stale exit corrupted status: %q", st)
	}

	// The current generation's exit is recorded.
	m.serviceExited("s1", gen, "boom", true)
	rt2, _ := m.svcRuntime("s1")
	rt2.inst.mu.Lock()
	st, msg := rt2.inst.status, rt2.inst.exitMsg
	rt2.inst.mu.Unlock()
	if st != "failed" || msg != "boom" {
		t.Errorf("exit not recorded: %q %q", st, msg)
	}

	// Clean exits map to stopped.
	rt3, gen3, err := m.svcBeginOp("s1")
	if err != nil {
		t.Fatal(err)
	}
	armRunning(t, m, "s1", gen3, rt3)
	m.svcEndOp(rt3)
	m.serviceExited("s1", gen3, "bye", false)
	if st, _ := m.svcStatus("s1"); st != "stopped" {
		t.Errorf("clean exit status = %q", st)
	}
}

func TestSvcExitNeverTouchesOtherServices(t *testing.T) {
	m := mkManager(t)
	m.svcEnsureRuntime("a")
	m.svcEnsureRuntime("b")

	rtA, genA, _ := m.svcBeginOp("a")
	armRunning(t, m, "a", genA, rtA)
	m.svcEndOp(rtA)
	rtB, genB, _ := m.svcBeginOp("b")
	armRunning(t, m, "b", genB, rtB)
	m.svcEndOp(rtB)

	m.serviceExited("a", genA, "a died", true)
	if st, _ := m.svcStatus("b"); st != "running" {
		t.Errorf("exit of a corrupted b: %q", st)
	}
}

// ---------------------------------------------------------------------------
// Delete interaction
// ---------------------------------------------------------------------------

// svcTestDelete mimics the stage-8 delete order: take the op lock (waits for
// any in-flight op), retire the runtime, release.
func svcTestDelete(m *manager, id string) error {
	rt, ok := m.svcRuntime(id)
	if !ok {
		return errServiceNotFound
	}
	rt.opMu.Lock()
	defer rt.opMu.Unlock()
	m.svcRetire(id, rt)
	return nil
}

func TestSvcStartDuringDeleteFailsClosed(t *testing.T) {
	m := mkManager(t)
	m.svcEnsureRuntime("s1")

	// Simulate a delete in flight: it holds the op lock.
	rt, ok := m.svcRuntime("s1")
	if !ok {
		t.Fatal("runtime missing")
	}
	rt.opMu.Lock()

	type result struct {
		err error
	}
	ch := make(chan result, 1)
	go func() {
		_, _, err := m.svcBeginOp("s1")
		ch <- result{err}
	}()
	time.Sleep(80 * time.Millisecond) // let the begin resolve the map & block

	m.svcRetire("s1", rt) // gone + removed from registry
	rt.opMu.Unlock()

	r := <-ch
	if r.err != errServiceGone {
		t.Fatalf("start during delete must fail closed, got %v", r.err)
	}
	// After retirement the ID is unknown again.
	if _, _, err := m.svcBeginOp("s1"); err != errServiceNotFound {
		t.Fatalf("after delete want errServiceNotFound, got %v", err)
	}
	// Exit callbacks for the retired runtime are dropped without panic.
	m.serviceExited("s1", 1, "late", true)
}

func TestSvcCreateSeedsRuntimeAndDeleteRetires(t *testing.T) {
	m := mkManager(t)
	c, err := m.createServiceConfig(ServiceConfig{Name: "Alpha", Engine: ServiceEngineDockerDDB})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := m.svcRuntime(c.ID); !ok {
		t.Fatal("create must seed a runtime")
	}
	if err := svcTestDelete(m, c.ID); err != nil {
		t.Fatal(err)
	}
	if _, ok := m.svcRuntime(c.ID); ok {
		t.Error("delete must retire the runtime")
	}
}

// ---------------------------------------------------------------------------
// Smoke: two fake-engine Services run parallel lifecycles without crosstalk
// ---------------------------------------------------------------------------

func TestTwoFakeServicesParallelLifecycle(t *testing.T) {
	m := mkManager(t)
	a, err := m.createServiceConfig(ServiceConfig{Name: "Fake A", Engine: ServiceEngineJava, Port: 9501})
	if err != nil {
		t.Fatal(err)
	}
	b, err := m.createServiceConfig(ServiceConfig{Name: "Fake B", Engine: ServiceEngineDockerDDB, Port: 9502})
	if err != nil {
		t.Fatal(err)
	}

	// Start both (fake engines: arm state directly under the op lock).
	rtA, genA, err := m.svcBeginOp(a.ID)
	if err != nil {
		t.Fatal(err)
	}
	armRunning(t, m, a.ID, genA, rtA)
	rtA.instance().appendLog("A boot line")
	m.svcEndOp(rtA)

	rtB, genB, err := m.svcBeginOp(b.ID)
	if err != nil {
		t.Fatal(err)
	}
	armRunning(t, m, b.ID, genB, rtB)
	rtB.instance().appendLog("B boot line")
	m.svcEndOp(rtB)

	// Status and logs are isolated by ID.
	if st, _ := m.svcStatus(a.ID); st != "running" {
		t.Errorf("A status = %q", st)
	}
	if st, _ := m.svcStatus(b.ID); st != "running" {
		t.Errorf("B status = %q", st)
	}
	if logs := rtA.instance().snapshotLogs(); len(logs) != 1 || logs[0] != "A boot line" {
		t.Errorf("A logs leaked: %v", logs)
	}
	if logs := rtB.instance().snapshotLogs(); len(logs) != 1 || logs[0] != "B boot line" {
		t.Errorf("B logs leaked: %v", logs)
	}

	// Failing A must not disturb B.
	m.serviceExited(a.ID, genA, "A crashed", true)
	if st, _ := m.svcStatus(a.ID); st != "failed" {
		t.Errorf("A should be failed, got %q", st)
	}
	if st, _ := m.svcStatus(b.ID); st != "running" {
		t.Errorf("B must stay running, got %q", st)
	}

	// Concurrent lifecycle churn on both IDs must not error or cross wires.
	var wg sync.WaitGroup
	for _, id := range []string{a.ID, b.ID} {
		for i := 0; i < 5; i++ {
			wg.Add(1)
			go func(id string) {
				defer wg.Done()
				rt, _, err := m.svcBeginOp(id)
				if err != nil {
					t.Errorf("churn begin(%s): %v", id, err)
					return
				}
				m.svcEndOp(rt)
			}(id)
		}
	}
	wg.Wait()

	// B survives the churn with its identity intact.
	if st, _ := m.svcStatus(b.ID); st != "running" {
		t.Errorf("B status after churn = %q", st)
	}
}
