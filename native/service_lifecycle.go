package main

// ID-addressed Service lifecycle: start / stop / restart behind the per-ID
// operation lock.
//
// State machine (Core statuses; the UI adds presentational stopping/recovering):
//
//	start:   stopped|failed|error → preparing → running
//	stop:    running|preparing|restarting|failed|error → stopped
//	restart: ensure stopped (internal stop, desired preserved), then start
//
// Failure semantics (design §Rollback rules):
//
//   - start rejected (port conflict, engine error, readiness timeout, persist
//     failure): the runtime resource created by THIS attempt is stopped and
//     removed, managed data is preserved, and desiredRunning is untouched;
//   - stop succeeds but persisting desiredRunning=false fails: the Service is
//     recorded stopped and the error is surfaced;
//   - restart whose stop succeeds but start fails: stays stopped/failed, never
//     reports running.

import (
	"errors"
	"fmt"
	"net"
	"syscall"
	"time"
)

// Lifecycle sentinels. The ABI layer maps these onto error codes (stage 9).
var (
	errInvalidTransition = errors.New("invalid transition")
	errPortConflict      = errors.New("port conflict")
	errReadinessTimeout  = errors.New("readiness timeout")
	errPersistFailed     = errors.New("persist failed")
	// errResourceUnowned: a container/process under this Service's expected
	// name carries foreign ownership labels — never hijacked, never removed.
	errResourceUnowned = errors.New("resource_unowned")
)

// Readiness is injectable so tests never need real listeners. The production
// probe treats "accepting TCP connections on the host port" as ready.
var svcReadyProbe = func(port int) bool {
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 250*time.Millisecond)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

// svcReadinessTimeout bounds how long start waits for the port to come up
// before rolling the attempt back.
var svcReadinessTimeout = 30 * time.Second

// svcStopTimeout bounds how long stop waits for the child to settle.
var svcStopTimeout = 10 * time.Second

// svcPortInUse reports whether something already owns the host port. It probes
// both loopback stacks: a bind failure with EADDRINUSE is proof of occupancy,
// any other failure (e.g. no IPv6 on this host) is not.
func svcPortInUse(port int) bool {
	for _, addr := range []string{
		fmt.Sprintf("127.0.0.1:%d", port),
		fmt.Sprintf("[::1]:%d", port),
	} {
		ln, err := net.Listen("tcp", addr)
		if err != nil {
			if errors.Is(err, syscall.EADDRINUSE) {
				return true
			}
			continue
		}
		_ = ln.Close()
	}
	return false
}

// startService brings one Service up: config lookup, transition guard, port
// check, engine start, readiness wait, then desired-state persist — with
// rollback of the created runtime resource on any post-spawn failure.
func (m *manager) startService(id string) error {
	rt, gen, err := m.svcBeginOp(id)
	if err != nil {
		return err
	}
	defer m.svcEndOp(rt)
	return m.startServiceLocked(rt, gen, id)
}

// stopService stops one Service. preserveDesired is the Stop All mode: the
// temporary stop must NOT rewrite the long-term desiredRunning.
func (m *manager) stopService(id string, preserveDesired bool) error {
	rt, _, err := m.svcBeginOp(id)
	if err != nil {
		return err
	}
	defer m.svcEndOp(rt)
	return m.stopServiceLocked(rt, id, preserveDesired)
}

// restartService stops (if needed) and starts one Service under a single
// operation lock: identity, configuration, logs, and data location are never
// touched — only the process generation moves on.
func (m *manager) restartService(id string) error {
	rt, gen, err := m.svcBeginOp(id)
	if err != nil {
		return err
	}
	defer m.svcEndOp(rt)
	// Internal stop preserves desired state: the start half owns the final
	// desired-state write. An already-stopped Service just proceeds to start.
	if err := m.stopServiceLocked(rt, id, true); err != nil && !errors.Is(err, errInvalidTransition) {
		return err
	}
	return m.startServiceLocked(rt, gen, id)
}

// startServiceLocked implements start; the caller holds rt.opMu.
func (m *manager) startServiceLocked(rt *serviceRuntime, gen uint64, id string) error {
	m.mu.Lock()
	scPtr, _ := findService(m.st.Services, id)
	sc := ServiceConfig{}
	if scPtr != nil {
		sc = *scPtr
	}
	m.mu.Unlock()
	if scPtr == nil {
		return errServiceNotFound
	}

	in := rt.instance()
	in.mu.Lock()
	st := in.status
	in.mu.Unlock()
	switch st {
	case "running", "preparing", "restarting":
		return fmt.Errorf("%w: service %s is %s", errInvalidTransition, id, st)
	}

	if svcPortInUse(sc.Port) {
		in.mu.Lock()
		in.status = "failed"
		in.exitMsg = fmt.Sprintf("port %d is already in use", sc.Port)
		in.mu.Unlock()
		return fmt.Errorf("%w: port %d is already in use", errPortConflict, sc.Port)
	}

	ad, err := serviceEngineFor(sc.Engine)
	if err != nil {
		return err
	}

	rt.spawnGen = gen // arm the generation the exit callback must present
	in.mu.Lock()
	in.status = "preparing"
	in.exitMsg = ""
	in.mu.Unlock()

	if err := ad.start(m, sc, in); err != nil {
		rt.spawnGen = 0
		in.mu.Lock()
		in.status = "failed"
		in.exitMsg = err.Error()
		in.mu.Unlock()
		return err
	}

	if !waitServiceReady(in, sc.Port, svcReadinessTimeout) {
		// Roll back THIS attempt: stop the resource we created, keep the data.
		in.mu.Lock()
		in.exitMsg = fmt.Sprintf("readiness timeout after %s", svcReadinessTimeout)
		in.mu.Unlock()
		in.terminate()
		rt.spawnGen = 0
		return fmt.Errorf("%w: service %s did not become ready on port %d within %s",
			errReadinessTimeout, id, sc.Port, svcReadinessTimeout)
	}

	if err := m.persistDesired(id, true); err != nil {
		// Running but the desired state cannot be recorded is a half-success:
		// roll the runtime back so disk and reality agree.
		in.terminate()
		rt.spawnGen = 0
		return fmt.Errorf("%w: %v", errPersistFailed, err)
	}
	return nil
}

// stopServiceLocked implements stop; the caller holds rt.opMu.
func (m *manager) stopServiceLocked(rt *serviceRuntime, id string, preserveDesired bool) error {
	in := rt.instance()
	in.mu.Lock()
	st := in.status
	in.mu.Unlock()
	if st == "stopped" {
		return fmt.Errorf("%w: service %s is already stopped", errInvalidTransition, id)
	}

	in.terminate()
	if !waitInstanceSettled(in, svcStopTimeout) {
		return fmt.Errorf("service %s did not settle after stop", id)
	}
	if !preserveDesired {
		if err := m.persistDesired(id, false); err != nil {
			// The Service IS stopped; only the desired-state write failed.
			return fmt.Errorf("%w: %v", errPersistFailed, err)
		}
	}
	return nil
}

// persistDesired flips one Service's desiredRunning and atomically persists
// it, restoring the previous value on write failure.
func (m *manager) persistDesired(id string, desired bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, idx := findService(m.st.Services, id)
	if idx < 0 {
		return errServiceNotFound
	}
	prev := m.st.Services[idx].DesiredRunning
	m.st.Services[idx].DesiredRunning = desired
	if err := m.persist(); err != nil {
		m.st.Services[idx].DesiredRunning = prev
		return err
	}
	return nil
}

// waitServiceReady polls the readiness probe until the port is up, the child
// dies (terminal status), or the timeout elapses.
func waitServiceReady(in *instance, port int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		in.mu.Lock()
		st := in.status
		in.mu.Unlock()
		switch st {
		case "stopped", "failed", "error":
			return false // the child died during boot
		}
		if svcReadyProbe(port) {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
	return false
}

// waitInstanceSettled polls until the instance reaches a terminal status or
// the timeout elapses.
func waitInstanceSettled(in *instance, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		in.mu.Lock()
		st := in.status
		in.mu.Unlock()
		switch st {
		case "stopped", "failed", "error":
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return false
}
