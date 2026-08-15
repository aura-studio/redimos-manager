package main

// Stage 9: the ID-addressed Service C ABI.
//
// Seven symbols, all JSON-in / JSON-out (requirement 11.1, 11.2):
//
//	rm_services()                     list all Services + recovery errors
//	rm_service_save(json)             create (empty id) or update (known id)
//	rm_service_delete(json)           {"id","deleteData"} — safe delete (stage 8)
//	rm_service_start(json)            {"id"}
//	rm_service_stop(json)             {"id"} — explicit stop persists desired=false
//	rm_service_restart(json)          {"id"}
//	rm_service_logs(json)             {"id"} → {"ok","id","lines"}
//
// Envelopes (11.3): success carries ok/id/service/warnings, failure carries
// ok:false/id/code/error — the code is the stable machine token from the
// design's error taxonomy, the error text is the human sentence. The legacy
// rm_ddb_* symbols stay linked but answer with a fixed unsupported envelope
// (11.4): Local DynamoDB is now a Service, and the singleton surface must not
// grow a second writer.
//
// The Go-level abi* functions are the testable surface; the //export wrappers
// only cross the cgo boundary.

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// ---------------------------------------------------------------------------
// Error taxonomy (design §Error taxonomy): one stable code per failure class.
// ---------------------------------------------------------------------------

// svcErrorCode maps a Core error onto the taxonomy code the UI switches on.
// Sentinels match by wrapping (errors.Is); the message fallbacks also cover
// runtime exit messages, which survive only as strings.
func svcErrorCode(err error) string {
	if err == nil {
		return ""
	}
	switch {
	case errors.Is(err, errServiceNotFound), errors.Is(err, errServiceGone):
		return "service_not_found"
	case errors.Is(err, errInvalidTransition):
		return "invalid_transition"
	case errors.Is(err, errPortConflict):
		return "port_conflict"
	case errors.Is(err, errReadinessTimeout):
		return "readiness_timeout"
	case errors.Is(err, errPersistFailed):
		return "persist_failed"
	case errors.Is(err, errUnsafeDataPath):
		return "unsafe_data_path"
	case errors.Is(err, errUnownedVolume):
		return "unowned_volume"
	case errors.Is(err, errPartialDelete):
		return "partial_delete"
	case errors.Is(err, errResourceUnowned):
		return "resource_unowned"
	}
	msg := err.Error()
	switch {
	case strings.Contains(msg, "already in use by Service"):
		return "duplicate_name"
	case strings.Contains(msg, "already configured by Service"):
		return "port_conflict"
	case strings.HasPrefix(msg, "port conflict"), strings.Contains(msg, "is already in use"):
		return "port_conflict"
	case strings.HasPrefix(msg, "invalid transition"):
		return "invalid_transition"
	case strings.HasPrefix(msg, "readiness timeout"):
		return "readiness_timeout"
	case strings.HasPrefix(msg, "persist failed"), strings.Contains(msg, "persist"):
		return "persist_failed"
	case strings.HasPrefix(msg, "resource_unowned"):
		return "resource_unowned"
	case strings.HasPrefix(msg, "unsafe_data_path"):
		return "unsafe_data_path"
	case strings.HasPrefix(msg, "unowned_volume"):
		return "unowned_volume"
	case strings.HasPrefix(msg, "partial_delete"):
		return "partial_delete"
	case strings.Contains(msg, "not available"):
		return "engine_unavailable"
	case msg == "service not found", strings.Contains(msg, "service is being deleted"),
		strings.Contains(msg, "not found"):
		return "service_not_found"
	}
	return "invalid_request"
}

// ---------------------------------------------------------------------------
// Wire shapes: ServiceInfo = persisted config + live runtime (design §Data
// Models). Runtime mirrors the redimos proxy instance shape, trimmed to what
// a Service exposes.
// ---------------------------------------------------------------------------

// serviceMetricsInfo is the live resource sample of a running Service.
type serviceMetricsInfo struct {
	CPUPercent      float64 `json:"cpuPercent"`
	MemBytes        uint64  `json:"memBytes"`
	DiskBytesPerSec float64 `json:"diskBytesPerSec"`
}

// serviceRuntimeInfo is the transient half of a Service: rebuilt by
// reconcile/probes, never persisted.
type serviceRuntimeInfo struct {
	State       string              `json:"state"`
	PID         int                 `json:"pid,omitempty"`
	ContainerID string              `json:"containerId,omitempty"`
	StartedAt   string              `json:"startedAt,omitempty"`
	Ready       bool                `json:"ready"`
	Healthy     bool                `json:"healthy"`
	ErrorCode   string              `json:"errorCode,omitempty"`
	Error       string              `json:"error,omitempty"`
	Metrics     *serviceMetricsInfo `json:"metrics,omitempty"`
}

// serviceInfo is the full list/detail payload: config + runtime.
type serviceInfo struct {
	Config  ServiceConfig      `json:"config"`
	Runtime serviceRuntimeInfo `json:"runtime"`
}

// serviceInfoFor assembles one Service's wire shape. The runtime half is a
// best-effort snapshot: a Service with no runtime yet reports stopped.
func (m *manager) serviceInfoFor(sc ServiceConfig) serviceInfo {
	info := serviceInfo{Config: sc, Runtime: serviceRuntimeInfo{State: "stopped"}}
	rt, ok := m.svcRuntime(sc.ID)
	if !ok {
		return info
	}
	in := rt.instance()
	if in == nil {
		return info
	}
	in.mu.Lock()
	defer in.mu.Unlock()
	st := in.status
	if st == "" {
		st = "stopped"
	}
	info.Runtime.State = st
	info.Runtime.PID = in.pid
	info.Runtime.ContainerID = in.container
	if !in.started.IsZero() {
		info.Runtime.StartedAt = in.started.Format(time.RFC3339)
	}
	info.Runtime.Error = in.exitMsg
	if in.exitMsg != "" {
		info.Runtime.ErrorCode = svcErrorCode(errors.New(in.exitMsg))
	}
	// Readiness is proven at start (the port accepted connections); a running
	// Service IS the healthy/ready state — the local engines expose no richer
	// health signal.
	info.Runtime.Ready = st == "running"
	info.Runtime.Healthy = st == "running"
	if st == "running" {
		info.Runtime.Metrics = &serviceMetricsInfo{
			CPUPercent:      in.cpuPercent,
			MemBytes:        in.memBytes,
			DiskBytesPerSec: in.diskPerSec,
		}
	}
	return info
}

// serviceInfos lists every Service in stable display order (design: the list
// order is presentation, never identity).
func (m *manager) serviceInfos() []serviceInfo {
	m.mu.Lock()
	cfgs := append([]ServiceConfig(nil), m.st.Services...)
	m.mu.Unlock()
	sortServices(cfgs)
	infos := make([]serviceInfo, 0, len(cfgs))
	for _, sc := range cfgs {
		infos = append(infos, m.serviceInfoFor(sc))
	}
	return infos
}

// recoveryErrors is the boot-phase failure ledger: load diagnostics plus
// auto-start failures, one entry per affected Service (7.6). Always a present
// (possibly empty) slice — the wire contract says errors:[], never null.
func (m *manager) recoveryErrors() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := append([]string{}, m.serviceLoadErrors...)
	out = append(out, m.svcRecoveryErrs...)
	return out
}

// recordRecoveryError appends one auto-start failure to the ledger.
func (m *manager) recordRecoveryError(id string, err error) {
	m.mu.Lock()
	m.svcRecoveryErrs = append(m.svcRecoveryErrs, fmt.Sprintf("service %s: %v", id, err))
	m.mu.Unlock()
}

// ---------------------------------------------------------------------------
// Envelope helpers
// ---------------------------------------------------------------------------

func svcOK(extra map[string]any) map[string]any {
	m := map[string]any{"ok": true, "warnings": []string{}}
	for k, v := range extra {
		m[k] = v
	}
	return m
}

func svcErr(id, code string, err error) map[string]any {
	m := map[string]any{"ok": false, "code": code, "error": err.Error()}
	if id != "" {
		m["id"] = id
	}
	return m
}

// ---------------------------------------------------------------------------
// Go-level ABI (the //export wrappers below are thin cgo shells)
// ---------------------------------------------------------------------------

func (m *manager) abiServices() map[string]any {
	out := svcOK(map[string]any{
		"services": m.serviceInfos(),
		"errors":   m.recoveryErrors(),
	})
	m.mu.Lock()
	notice := m.legacyDdbMigrationNotice
	m.mu.Unlock()
	if notice != "" {
		out["warnings"] = []string{notice}
	}
	return out
}

func (m *manager) abiServiceSave(request string) map[string]any {
	var req struct {
		Service ServiceConfig `json:"service"`
	}
	if err := json.Unmarshal([]byte(request), &req); err != nil {
		return svcErr("", "invalid_request", fmt.Errorf("malformed request: %v", err))
	}
	if req.Service.ID == "" {
		saved, err := m.createServiceConfig(req.Service)
		if err != nil {
			return svcErr("", svcErrorCode(err), err)
		}
		return svcOK(map[string]any{"id": saved.ID, "service": m.serviceInfoFor(saved)})
	}
	// Update: the ID must exist, and a running Service only accepts the
	// restart-free field subset (decided inside updateServiceConfig).
	m.mu.Lock()
	_, idx := findService(m.st.Services, req.Service.ID)
	m.mu.Unlock()
	if idx < 0 {
		return svcErr(req.Service.ID, "service_not_found", errServiceNotFound)
	}
	st, _ := m.svcStatus(req.Service.ID)
	isRunning := st == "running" || st == "preparing" || st == "restarting"
	saved, err := m.updateServiceConfig(req.Service.ID, req.Service, isRunning)
	if err != nil {
		return svcErr(req.Service.ID, svcErrorCode(err), err)
	}
	return svcOK(map[string]any{"id": saved.ID, "service": m.serviceInfoFor(saved)})
}

func (m *manager) abiServiceDelete(request string) map[string]any {
	var req struct {
		ID         string `json:"id"`
		DeleteData bool   `json:"deleteData"`
	}
	if err := json.Unmarshal([]byte(request), &req); err != nil {
		return svcErr("", "invalid_request", fmt.Errorf("malformed request: %v", err))
	}
	if strings.TrimSpace(req.ID) == "" {
		return svcErr("", "invalid_request", fmt.Errorf("id is required"))
	}
	res, err := m.deleteServiceConfig(req.ID, req.DeleteData)
	cleanup := res.ManualCleanup
	if cleanup == nil {
		cleanup = []string{}
	}
	if err != nil {
		m := svcErr(req.ID, svcErrorCode(err), err)
		if errors.Is(err, errPartialDelete) {
			// The data half landed: report it even though the delete failed,
			// so the UI never claims data survived when it did not.
			m["dataCleaned"] = res.DataCleaned
			m["manualCleanup"] = cleanup
			m["partial"] = true
		}
		return m
	}
	return svcOK(map[string]any{
		"id":            req.ID,
		"dataCleaned":   res.DataCleaned,
		"manualCleanup": cleanup,
		"partial":       res.Partial,
	})
}

// abiServiceLifecycle is the shared body of start/stop/restart: decode the ID,
// run the transition, answer with the Service's fresh wire shape.
func (m *manager) abiServiceLifecycle(request string, op func(id string) error) map[string]any {
	var req struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(request), &req); err != nil {
		return svcErr("", "invalid_request", fmt.Errorf("malformed request: %v", err))
	}
	if strings.TrimSpace(req.ID) == "" {
		return svcErr("", "invalid_request", fmt.Errorf("id is required"))
	}
	if err := op(req.ID); err != nil {
		return svcErr(req.ID, svcErrorCode(err), err)
	}
	out := svcOK(map[string]any{"id": req.ID})
	m.mu.Lock()
	scPtr, _ := findService(m.st.Services, req.ID)
	sc := ServiceConfig{}
	if scPtr != nil {
		sc = *scPtr
	}
	m.mu.Unlock()
	if scPtr != nil {
		out["service"] = m.serviceInfoFor(sc)
	}
	return out
}

func (m *manager) abiServiceStart(request string) map[string]any {
	return m.abiServiceLifecycle(request, m.startService)
}

func (m *manager) abiServiceStop(request string) map[string]any {
	// Explicit user stop persists desiredRunning=false: the Service stays down
	// across restarts until started again.
	return m.abiServiceLifecycle(request, func(id string) error { return m.stopService(id, false) })
}

func (m *manager) abiServiceRestart(request string) map[string]any {
	return m.abiServiceLifecycle(request, m.restartService)
}

func (m *manager) abiServiceLogs(request string) map[string]any {
	var req struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(request), &req); err != nil {
		return svcErr("", "invalid_request", fmt.Errorf("malformed request: %v", err))
	}
	if strings.TrimSpace(req.ID) == "" {
		return svcErr("", "invalid_request", fmt.Errorf("id is required"))
	}
	m.mu.Lock()
	scPtr, _ := findService(m.st.Services, req.ID)
	sc := ServiceConfig{}
	if scPtr != nil {
		sc = *scPtr
	}
	m.mu.Unlock()
	if scPtr == nil {
		return svcErr(req.ID, "service_not_found", errServiceNotFound)
	}
	ad, err := serviceEngineFor(sc.Engine)
	if err != nil {
		return svcErr(req.ID, "engine_unavailable", err)
	}
	var in *instance
	if rt, ok := m.svcRuntime(req.ID); ok {
		in = rt.instance()
	}
	lines, err := ad.logs(m, sc, in)
	if err != nil {
		return svcErr(req.ID, svcErrorCode(err), err)
	}
	if lines == nil {
		lines = []string{}
	}
	return svcOK(map[string]any{"id": req.ID, "lines": lines})
}

// legacyUnsupported is the fixed answer of the retired singleton symbols:
// zero side effects, one stable code (11.4).
func legacyUnsupported() map[string]any {
	return map[string]any{
		"ok":    false,
		"code":  "legacy_api_unsupported",
		"error": "Local DynamoDB is managed through Service APIs",
	}
}

// ---------------------------------------------------------------------------
// Exported C ABI
// ---------------------------------------------------------------------------

//export rm_services
func rm_services() *C.char { return cjson(mgr.abiServices()) }

//export rm_service_save
func rm_service_save(requestJSON *C.char) *C.char {
	return cjson(mgr.abiServiceSave(C.GoString(requestJSON)))
}

//export rm_service_delete
func rm_service_delete(requestJSON *C.char) *C.char {
	return cjson(mgr.abiServiceDelete(C.GoString(requestJSON)))
}

//export rm_service_start
func rm_service_start(requestJSON *C.char) *C.char {
	return cjson(mgr.abiServiceStart(C.GoString(requestJSON)))
}

//export rm_service_stop
func rm_service_stop(requestJSON *C.char) *C.char {
	return cjson(mgr.abiServiceStop(C.GoString(requestJSON)))
}

//export rm_service_restart
func rm_service_restart(requestJSON *C.char) *C.char {
	return cjson(mgr.abiServiceRestart(C.GoString(requestJSON)))
}

//export rm_service_logs
func rm_service_logs(requestJSON *C.char) *C.char {
	return cjson(mgr.abiServiceLogs(C.GoString(requestJSON)))
}
