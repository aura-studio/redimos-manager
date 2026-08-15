package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Lifecycle test fixtures
// ---------------------------------------------------------------------------

// freePort reserves an OS-assigned port and returns it for use as a fake
// Service port (the fakes never actually bind it).
func freePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

// probeStub swaps the readiness probe.
func probeStub(t *testing.T, ready func(port int) bool) {
	t.Helper()
	old := svcReadyProbe
	svcReadyProbe = ready
	t.Cleanup(func() { svcReadyProbe = old })
}

func probeAlwaysReady(t *testing.T) { probeStub(t, func(int) bool { return true }) }

func shortReadiness(t *testing.T, d time.Duration) {
	t.Helper()
	old := svcReadinessTimeout
	svcReadinessTimeout = d
	t.Cleanup(func() { svcReadinessTimeout = old })
}

// lifecycleSetup builds a sandboxed manager with a fake docker engine whose
// readiness probe reports a Service ready exactly when its fake container has
// armed its stop channel (tests override either).
func lifecycleSetup(t *testing.T) (*manager, string) {
	t.Helper()
	sandboxRegistry(t)
	fake, state := fakeDocker(t)
	overrideSvcBins(t, fake, "")
	probeStub(t, portUpProbe(state))
	return mkManager(t), state
}

func createDockerService(t *testing.T, m *manager, name string, port int) ServiceConfig {
	t.Helper()
	c, err := m.createServiceConfig(ServiceConfig{Name: name, Engine: ServiceEngineDockerDDB, Port: port})
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func mustStatus(t *testing.T, m *manager, id, want string) {
	t.Helper()
	st, ok := m.svcStatus(id)
	if !ok || st != want {
		t.Fatalf("status(%s) = %q,%v; want %q", id, st, ok, want)
	}
}

func desiredOf(t *testing.T, m *manager, id string) bool {
	t.Helper()
	m.mu.Lock()
	defer m.mu.Unlock()
	sc, _ := findService(m.st.Services, id)
	if sc == nil {
		t.Fatalf("service %s vanished", id)
	}
	return sc.DesiredRunning
}

// ---------------------------------------------------------------------------
// 5.1/5.2 start & stop state machine
// ---------------------------------------------------------------------------

func TestStartStopPersistsDesiredState(t *testing.T) {
	m, _ := lifecycleSetup(t)
	a := createDockerService(t, m, "Alpha", freePort(t))
	b := createDockerService(t, m, "Beta", freePort(t))

	if err := m.startService(a.ID); err != nil {
		t.Fatal(err)
	}
	mustStatus(t, m, a.ID, "running")
	if !desiredOf(t, m, a.ID) {
		t.Error("successful start must persist desiredRunning=true")
	}
	// Another Service is untouched by A's start.
	mustStatus(t, m, b.ID, "stopped")
	if desiredOf(t, m, b.ID) {
		t.Error("start of A must not touch B's desired state")
	}

	if err := m.stopService(a.ID, false); err != nil {
		t.Fatal(err)
	}
	mustStatus(t, m, a.ID, "stopped")
	if desiredOf(t, m, a.ID) {
		t.Error("explicit stop must persist desiredRunning=false")
	}
	// Stopping again is an invalid transition.
	if err := m.stopService(a.ID, false); !errors.Is(err, errInvalidTransition) {
		t.Fatalf("stop-when-stopped must be invalid_transition, got %v", err)
	}
	rt, _ := m.svcRuntime(a.ID)
	rt.instance().superviseWG.Wait()
}

func TestStartUnknownIDFailsClosed(t *testing.T) {
	m, _ := lifecycleSetup(t)
	if err := m.startService("nope"); !errors.Is(err, errServiceNotFound) {
		t.Fatalf("want service-not-found, got %v", err)
	}
	if _, ok := m.svcRuntime("nope"); ok {
		t.Error("unknown id must not conjure a runtime")
	}
	if err := m.stopService("nope", false); !errors.Is(err, errServiceNotFound) {
		t.Fatalf("want service-not-found, got %v", err)
	}
	if err := m.restartService("nope"); !errors.Is(err, errServiceNotFound) {
		t.Fatalf("want service-not-found, got %v", err)
	}
}

func TestStartWhileRunningIsInvalidTransition(t *testing.T) {
	m, _ := lifecycleSetup(t)
	a := createDockerService(t, m, "Alpha", freePort(t))
	if err := m.startService(a.ID); err != nil {
		t.Fatal(err)
	}
	if err := m.startService(a.ID); !errors.Is(err, errInvalidTransition) {
		t.Fatalf("start-while-running must be invalid_transition, got %v", err)
	}
	mustStatus(t, m, a.ID, "running") // the rejected second start changed nothing
	rt, _ := m.svcRuntime(a.ID)
	if err := m.stopService(a.ID, false); err != nil {
		t.Fatal(err)
	}
	rt.instance().superviseWG.Wait()
}

func TestStartPortConflictRejectsCleanly(t *testing.T) {
	m, _ := lifecycleSetup(t)
	// Occupy a real port, then configure a Service on top of it.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	busy := ln.Addr().(*net.TCPAddr).Port
	a := createDockerService(t, m, "Alpha", busy)

	err = m.startService(a.ID)
	if !errors.Is(err, errPortConflict) {
		t.Fatalf("want port_conflict, got %v", err)
	}
	mustStatus(t, m, a.ID, "failed")
	if desiredOf(t, m, a.ID) {
		t.Error("rejected start must not change desired state")
	}
	rt, _ := m.svcRuntime(a.ID)
	rt.instance().mu.Lock()
	msg := rt.instance().exitMsg
	rt.instance().mu.Unlock()
	if !strings.Contains(msg, "port") {
		t.Errorf("exit message should name the cause: %q", msg)
	}

	// Free the port: the same Service starts cleanly.
	ln.Close()
	if err := m.startService(a.ID); err != nil {
		t.Fatal(err)
	}
	mustStatus(t, m, a.ID, "running")
	if err := m.stopService(a.ID, false); err != nil {
		t.Fatal(err)
	}
	rt.instance().superviseWG.Wait()
}

func TestStartReadinessTimeoutRollsBack(t *testing.T) {
	m, state := lifecycleSetup(t)
	// Never becomes ready — but each probe first blocks until the fake has
	// armed, so the rollback's terminate lands after the stop channel is
	// observable (mirrors real docker, where a not-yet-created container is
	// not what a readiness timeout rolls back).
	probeStub(t, func(port int) bool { waitPortUp(state, port); return false })
	shortReadiness(t, 150*time.Millisecond)
	a := createDockerService(t, m, "Alpha", freePort(t))

	err := m.startService(a.ID)
	if !errors.Is(err, errReadinessTimeout) {
		t.Fatalf("want readiness_timeout, got %v", err)
	}
	if desiredOf(t, m, a.ID) {
		t.Error("rolled-back start must not change desired state")
	}
	rt, _ := m.svcRuntime(a.ID)
	rt.instance().superviseWG.Wait()
	mustStatus(t, m, a.ID, "stopped")
	// The runtime resource created by the attempt was removed.
	if _, err := os.ReadFile(filepath.Join(state, "container-redimos-service-"+a.ID+".removed")); err != nil {
		t.Error("rollback must remove the container created by this attempt")
	}
}

func TestStartPersistFailureRollsBack(t *testing.T) {
	m, state := lifecycleSetup(t)
	a := createDockerService(t, m, "Alpha", freePort(t))
	breakPersist(t, m) // occupy the tmp path so persist fails

	err := m.startService(a.ID)
	if !errors.Is(err, errPersistFailed) {
		t.Fatalf("want persist_failed, got %v", err)
	}
	if desiredOf(t, m, a.ID) {
		t.Error("failed persist must not leave desiredRunning=true")
	}
	rt, _ := m.svcRuntime(a.ID)
	rt.instance().superviseWG.Wait()
	mustStatus(t, m, a.ID, "stopped")
	if _, err := os.ReadFile(filepath.Join(state, "container-redimos-service-"+a.ID+".removed")); err != nil {
		t.Error("persist failure must roll back the running resource")
	}
}

// ---------------------------------------------------------------------------
// 5.2 explicit stop vs temporary stop (Stop All mode)
// ---------------------------------------------------------------------------

func TestStopPreserveDesiredKeepsDesiredTrue(t *testing.T) {
	m, _ := lifecycleSetup(t)
	a := createDockerService(t, m, "Alpha", freePort(t))
	if err := m.startService(a.ID); err != nil {
		t.Fatal(err)
	}
	if err := m.stopService(a.ID, true); err != nil { // Stop All path
		t.Fatal(err)
	}
	mustStatus(t, m, a.ID, "stopped")
	if !desiredOf(t, m, a.ID) {
		t.Error("temporary stop must NOT rewrite desiredRunning")
	}
	rt, _ := m.svcRuntime(a.ID)
	rt.instance().superviseWG.Wait()
}

// ---------------------------------------------------------------------------
// 5.3 restart keeps identity, logs and data; reports stop-ok/start-fail
// ---------------------------------------------------------------------------

func TestRestartPreservesIdentityAndLogs(t *testing.T) {
	m, _ := lifecycleSetup(t)
	a := createDockerService(t, m, "Alpha", freePort(t))
	if err := m.startService(a.ID); err != nil {
		t.Fatal(err)
	}
	rt, _ := m.svcRuntime(a.ID)
	in := rt.instance()
	logsBefore := in.snapshotLogs()

	if err := m.restartService(a.ID); err != nil {
		t.Fatal(err)
	}
	mustStatus(t, m, a.ID, "running")
	if rt.instance() != in {
		t.Error("restart must keep the same runtime carrier (identity)")
	}
	logsAfter := in.snapshotLogs()
	if len(logsAfter) <= len(logsBefore) {
		t.Error("restart must preserve and extend the log stream")
	}
	shared := true
	for i := range logsBefore {
		if logsBefore[i] != logsAfter[i] {
			shared = false
			break
		}
	}
	if !shared {
		t.Error("restart must not rewrite earlier log lines")
	}
	if !desiredOf(t, m, a.ID) {
		t.Error("successful restart must persist desiredRunning=true")
	}

	// Restart from stopped is legal: it just starts.
	if err := m.stopService(a.ID, false); err != nil {
		t.Fatal(err)
	}
	if err := m.restartService(a.ID); err != nil {
		t.Fatalf("restart-from-stopped must succeed: %v", err)
	}
	mustStatus(t, m, a.ID, "running")
	if err := m.stopService(a.ID, false); err != nil {
		t.Fatal(err)
	}
	in.superviseWG.Wait()
}

func TestRestartStopOKStartFailStaysHonest(t *testing.T) {
	m, _ := lifecycleSetup(t)
	port := freePort(t)
	a := createDockerService(t, m, "Alpha", port)
	if err := m.startService(a.ID); err != nil {
		t.Fatal(err)
	}
	// Occupy the port while the Service runs (the fake never binds it), so the
	// restart's start half hits a real conflict after the stop half succeeds.
	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	err = m.restartService(a.ID)
	if !errors.Is(err, errPortConflict) {
		t.Fatalf("want port_conflict from the start half, got %v", err)
	}
	// Honest terminal state: stopped process, failed start, never "running".
	st, _ := m.svcStatus(a.ID)
	if st == "running" {
		t.Fatal("failed restart must never report running")
	}
	if st != "failed" {
		t.Errorf("status = %q, want failed", st)
	}
	if !desiredOf(t, m, a.ID) {
		t.Error("failed restart must not rewrite the prior desired state")
	}
	rt, _ := m.svcRuntime(a.ID)
	rt.instance().superviseWG.Wait()
}

// ---------------------------------------------------------------------------
// 5.4 concurrency: same-ID requests serialize deterministically
// ---------------------------------------------------------------------------

func TestConcurrentSameIDStartsSerialize(t *testing.T) {
	m, _ := lifecycleSetup(t)
	a := createDockerService(t, m, "Alpha", freePort(t))

	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		go func() { errs <- m.startService(a.ID) }()
	}
	e1, e2 := <-errs, <-errs
	if (e1 == nil) == (e2 == nil) {
		t.Fatalf("exactly one concurrent start must win: %v / %v", e1, e2)
	}
	loser := e1
	if loser == nil {
		loser = e2
	}
	if !errors.Is(loser, errInvalidTransition) {
		t.Fatalf("the second start must be rejected as invalid_transition, got %v", loser)
	}
	mustStatus(t, m, a.ID, "running")
	if err := m.stopService(a.ID, false); err != nil {
		t.Fatal(err)
	}
	rt, _ := m.svcRuntime(a.ID)
	rt.instance().superviseWG.Wait()
}

// ---------------------------------------------------------------------------
// 5.5 smoke: two Services live independent lifecycles
// ---------------------------------------------------------------------------

func TestTwoServicesIndependentLifecycleSmoke(t *testing.T) {
	m, state := lifecycleSetup(t)
	portA, portB := freePort(t), freePort(t)
	a := createDockerService(t, m, "Alpha", portA)
	b := createDockerService(t, m, "Beta", portB)

	// Only A is ready: B's start must time out and roll back while A runs on.
	// Each probe first blocks until THAT Service's fake has armed, so B's
	// rollback terminate cannot land before its stop channel is observable.
	probeStub(t, func(p int) bool { waitPortUp(state, p); return p == portA })
	shortReadiness(t, 150*time.Millisecond)

	if err := m.startService(a.ID); err != nil {
		t.Fatal(err)
	}
	if err := m.startService(b.ID); !errors.Is(err, errReadinessTimeout) {
		t.Fatalf("B must fail readiness, got %v", err)
	}
	mustStatus(t, m, a.ID, "running") // A survives B's failure
	if desiredOf(t, m, a.ID) != true || desiredOf(t, m, b.ID) != false {
		t.Error("desired states diverged from the outcomes")
	}
	rtB, _ := m.svcRuntime(b.ID)
	rtB.instance().superviseWG.Wait()
	rtB.instance().mu.Lock()
	bMsg := rtB.instance().exitMsg
	rtB.instance().mu.Unlock()
	if !strings.Contains(bMsg, "readiness") {
		t.Errorf("B must carry its own failure cause: %q", bMsg)
	}
	rtA, _ := m.svcRuntime(a.ID)
	rtA.instance().mu.Lock()
	aMsg := rtA.instance().exitMsg
	rtA.instance().mu.Unlock()
	if aMsg != "" {
		t.Errorf("B's failure leaked into A: %q", aMsg)
	}

	// Both ready: B starts and restarts independently while A keeps running.
	probeStub(t, portUpProbe(state))
	svcReadinessTimeout = 2 * time.Second // phase 2 arms real fakes; give exec headroom
	if err := m.startService(b.ID); err != nil {
		t.Fatal(err)
	}
	if err := m.restartService(b.ID); err != nil {
		t.Fatal(err)
	}
	mustStatus(t, m, a.ID, "running")
	mustStatus(t, m, b.ID, "running")

	// Stopping A never touches B.
	if err := m.stopService(a.ID, false); err != nil {
		t.Fatal(err)
	}
	mustStatus(t, m, a.ID, "stopped")
	mustStatus(t, m, b.ID, "running")
	if desiredOf(t, m, a.ID) {
		t.Error("A's stop must clear only A's desired state")
	}
	if !desiredOf(t, m, b.ID) {
		t.Error("A's stop must not touch B's desired state")
	}

	if err := m.stopService(b.ID, false); err != nil {
		t.Fatal(err)
	}
	rtA.instance().superviseWG.Wait()
	rtB.instance().superviseWG.Wait()
}
