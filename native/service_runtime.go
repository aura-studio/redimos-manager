package main

// Multi-Service runtime registry.
//
// Every ServiceConfig has exactly one serviceRuntime, keyed by the immutable
// Service ID. The registry gives each lifecycle operation three guarantees:
//
//   - isolation: two Services never share a runtime, lock, status, log, or
//     generation;
//   - serialization: operations on the SAME Service are strictly ordered by a
//     per-ID operation lock, while operations on DIFFERENT Services proceed
//     independently (the global store lock is never held across slow process
//     work);
//   - staleness detection: every lifecycle transition bumps a generation, and
//     exit callbacks carry the generation they were armed with — a callback
//     from a superseded or killed process is dropped instead of corrupting the
//     new run.
//
// Lock discipline:
//
//   - m.mu      — store / desired state, short holds only
//   - m.svcMu   — runtime-map membership, short holds only
//   - rt.opMu   — one Service's lifecycle operation, may be held across slow
//     process work. An opMu holder may take m.mu for short store reads/writes
//     (config lookup, desired-state persist) but MUST NOT take m.svcMu —
//     svcRetire is the single documented exception. No path may acquire opMu
//     while holding m.mu or m.svcMu (svcBeginOp releases svcMu before locking
//     opMu), so the opMu→m.mu order can never form a cycle.

import (
	"errors"
	"sync"
)

// Sentinel errors for the ID-addressed lifecycle surface.
var (
	errServiceNotFound = errors.New("service not found")
	errServiceGone     = errors.New("service is being deleted")
)

// serviceRuntime is the per-Service runtime carrier. inst holds the process
// state (status, pid, logs, metrics) using the same shape as redimos proxy
// instances; it is allocated lazily by the first start.
type serviceRuntime struct {
	opMu sync.Mutex // serializes lifecycle ops for this Service ID

	inst *instance // process state; nil until the Service is started once

	// gen is bumped by every lifecycle transition while opMu is held. spawnGen
	// is the generation the currently-armed process was started under; an exit
	// callback proves it belongs to the current run by presenting it.
	gen      uint64
	spawnGen uint64

	gone bool // set on delete while opMu is held; further ops fail closed
}

// instance returns the process-state carrier. The pointer is allocated once,
// when the runtime is created, and never reassigned — so readers that do not
// hold opMu (status polling) can dereference it safely; the fields inside are
// guarded by inst.mu.
func (rt *serviceRuntime) instance() *instance { return rt.inst }

// svcEnsureRuntime returns the runtime for id, creating it if absent. Called
// when a ServiceConfig comes into existence (create / boot load / reconcile).
func (m *manager) svcEnsureRuntime(id string) *serviceRuntime {
	m.svcMu.Lock()
	defer m.svcMu.Unlock()
	if m.svc == nil {
		m.svc = map[string]*serviceRuntime{}
	}
	rt, ok := m.svc[id]
	if !ok {
		rt = &serviceRuntime{inst: &instance{status: "stopped"}}
		m.svc[id] = rt
	}
	return rt
}

// svcRuntime looks up the runtime for a live Service.
func (m *manager) svcRuntime(id string) (*serviceRuntime, bool) {
	m.svcMu.Lock()
	defer m.svcMu.Unlock()
	rt, ok := m.svc[id]
	return rt, ok && !rt.gone
}

// svcBeginOp starts a lifecycle operation for id: it resolves the runtime,
// acquires that Service's operation lock (serializing same-ID requests), fails
// closed on unknown or deleted Services, and bumps the generation. The caller
// MUST pair every successful begin with svcEndOp.
func (m *manager) svcBeginOp(id string) (*serviceRuntime, uint64, error) {
	m.svcMu.Lock()
	rt, ok := m.svc[id]
	m.svcMu.Unlock()
	if !ok {
		return nil, 0, errServiceNotFound
	}
	rt.opMu.Lock()
	if rt.gone {
		rt.opMu.Unlock()
		return nil, 0, errServiceGone
	}
	rt.gen++
	return rt, rt.gen, nil
}

// svcEndOp finishes a lifecycle operation started by svcBeginOp.
func (m *manager) svcEndOp(rt *serviceRuntime) { rt.opMu.Unlock() }

// svcRetire removes a Service's runtime from the registry. It must be called
// while the caller holds rt.opMu (so any in-flight lifecycle operation for
// this ID has completed); the gone flag keeps stragglers failing closed.
func (m *manager) svcRetire(id string, rt *serviceRuntime) {
	rt.gone = true
	m.svcMu.Lock()
	delete(m.svc, id)
	m.svcMu.Unlock()
}

// serviceExited records a Service process exit. gen is the generation captured
// when the process was armed; if the runtime has moved on (restart, delete, a
// newer start) the callback is stale and dropped — it must never mark a newer
// run failed, nor another Service.
func (m *manager) serviceExited(id string, gen uint64, msg string, failed bool) {
	m.svcMu.Lock()
	rt, ok := m.svc[id]
	m.svcMu.Unlock()
	if !ok || rt.gone {
		return
	}
	rt.opMu.Lock()
	defer rt.opMu.Unlock()
	if rt.gone || gen != rt.spawnGen || rt.inst == nil {
		return // stale callback or nothing running
	}
	in := rt.inst
	in.mu.Lock()
	if failed {
		in.status = "failed"
	} else {
		in.status = "stopped"
	}
	in.exitMsg = msg
	in.mu.Unlock()
}

// svcStatus reports the runtime status of a Service: "stopped" when it has no
// live runtime state, "" when the ID is unknown.
func (m *manager) svcStatus(id string) (string, bool) {
	m.svcMu.Lock()
	rt, ok := m.svc[id]
	m.svcMu.Unlock()
	if !ok || rt.gone {
		return "", false
	}
	if rt.inst == nil {
		return "stopped", true
	}
	rt.inst.mu.Lock()
	defer rt.inst.mu.Unlock()
	if rt.inst.status == "" {
		return "stopped", true
	}
	return rt.inst.status, true
}
