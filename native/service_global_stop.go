package main

// Unified Stop All / Restore All over BOTH entity kinds (8.1–8.6).
//
// Stop All snapshots the live Instance and Service IDs BEFORE issuing any
// stop, persists the typed snapshot (so the restore affordance survives an app
// restart), then stops everything in parallel and reports per-entity outcomes.
// Services are stopped through the preserveDesired path: a global emergency
// stop is a TEMPORARY suppression and never rewrites a Service's long-term
// desiredRunning (8.5). Instances keep the legacy semantics: an explicit
// Stop All clears the boot AutoStart set, so they stay stopped next launch.
//
// Restore All restores EXACTLY the IDs in the most recent snapshot (8.3);
// entities that no longer exist are reported and skipped (8.4); failed
// restores stay in the snapshot for retry, successful and missing ones drop.

import (
	"errors"
	"sort"
	"sync"
	"time"
)

// Entity kinds in the unified stop/restore namespace. Instance and Service IDs
// live in separate namespaces; the snapshot keeps them apart so restore never
// confuses the two.
const (
	entityKindInstance = "instance"
	entityKindService  = "service"
)

// EntityRef names one entity in a stop/restore result.
type EntityRef struct {
	Kind string `json:"kind"` // entityKindInstance | entityKindService
	ID   string `json:"id"`
}

// EntityFailure names one entity whose stop/restore failed, with the reason.
type EntityFailure struct {
	Kind   string `json:"kind"`
	ID     string `json:"id"`
	Reason string `json:"reason"`
}

// GlobalStopResult is the per-entity outcome of one Stop All run.
type GlobalStopResult struct {
	Snapshot GlobalStopSnapshot `json:"snapshot"` // what was live; the restore source
	Stopped  []EntityRef        `json:"stopped"`
	Failed   []EntityFailure    `json:"failed,omitempty"`
}

// GlobalRestoreResult is the per-entity outcome of one Restore All run.
type GlobalRestoreResult struct {
	Restored []EntityRef     `json:"restored"`
	Failed   []EntityFailure `json:"failed,omitempty"` // kept in the snapshot for retry
	Missing  []EntityRef     `json:"missing,omitempty"` // entity no longer exists (8.4)
}

// stopAllSettleTimeout bounds how long Stop All waits for one terminated
// Instance to settle before reporting it failed. terminate() itself already
// escalates TERM→KILL; settling past this is a wedged child.
var stopAllSettleTimeout = 10 * time.Second

// stopAllUnified is the AppBar "Stop all" action for BOTH entity kinds.
// Snapshot first (8.1), persist, then stop everything, attempting every
// entity and reporting partial failures without hiding successful stops (8.2).
func (m *manager) stopAllUnified() GlobalStopResult {
	// --- 8.1: atomic snapshot of everything live, before any stop is issued ---
	var snap GlobalStopSnapshot
	liveInstances := map[string]*instance{}
	m.mu.Lock()
	for i := range m.st.Configs { // stable config order
		id := m.st.Configs[i].ID
		in, ok := m.running[id]
		if !ok {
			continue
		}
		in.mu.Lock()
		active := in.status == "running" || in.status == "restarting" || in.status == "preparing"
		in.mu.Unlock()
		if active {
			snap.Instances = append(snap.Instances, id)
			liveInstances[id] = in
		}
	}
	serviceIDs := make([]string, 0, len(m.st.Services))
	for i := range m.st.Services { // stable service order
		serviceIDs = append(serviceIDs, m.st.Services[i].ID)
	}
	// An explicit Stop All keeps Instances stopped on the next launch (legacy
	// semantics); Services resume via their untouched desiredRunning (7.5/8.5).
	m.st.AutoStart = nil
	m.mu.Unlock()

	for _, id := range serviceIDs {
		switch st, ok := m.svcStatus(id); {
		case ok && (st == "running" || st == "preparing" || st == "restarting"):
			snap.Services = append(snap.Services, id)
		}
	}

	// Persist the typed snapshot BEFORE stopping, so a crash mid-Stop-All still
	// leaves a restore source. The legacy string mirror stays in sync for
	// downgrades.
	m.mu.Lock()
	m.st.StopAllSnapshotV2 = snap
	m.st.StopAllSnapshot = append([]string(nil), snap.Instances...)
	_ = m.persist()
	m.mu.Unlock()

	// --- 8.2: attempt every entity, in parallel, collecting per-entity results ---
	res := GlobalStopResult{Snapshot: snap}
	var mu sync.Mutex
	stopped := func(kind, id string) {
		mu.Lock()
		res.Stopped = append(res.Stopped, EntityRef{Kind: kind, ID: id})
		mu.Unlock()
	}
	failed := func(kind, id, reason string) {
		mu.Lock()
		res.Failed = append(res.Failed, EntityFailure{Kind: kind, ID: id, Reason: reason})
		mu.Unlock()
	}
	var wg sync.WaitGroup
	for id, in := range liveInstances {
		wg.Add(1)
		go func(id string, in *instance) {
			defer wg.Done()
			in.terminate()
			if waitInstanceSettled(in, stopAllSettleTimeout) {
				stopped(entityKindInstance, id)
			} else {
				failed(entityKindInstance, id, "did not settle after stop")
			}
		}(id, in)
	}
	for _, id := range snap.Services {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			// preserveDesired=true: Stop All is a temporary suppression and must
			// not rewrite the long-term desiredRunning (8.5).
			err := m.stopService(id, true)
			if err == nil || errors.Is(err, errInvalidTransition) {
				// "already stopped" (a concurrent explicit stop won the race) is a
				// successful outcome, not a failure to hide (8.2).
				stopped(entityKindService, id)
				return
			}
			failed(entityKindService, id, err.Error())
		}(id)
	}
	wg.Wait()
	return res
}

// restoreAllUnified restores EXACTLY the entities recorded by the most recent
// Stop All (8.3): still-existing entities are restarted, vanished ones are
// reported and dropped (8.4), and failed restarts stay in the snapshot so the
// next Restore All retries them. Returns the per-entity outcome.
func (m *manager) restoreAllUnified() GlobalRestoreResult {
	m.mu.Lock()
	snap := m.st.StopAllSnapshotV2
	m.mu.Unlock()

	res := GlobalRestoreResult{}
	var keep GlobalStopSnapshot // failed entries stay for retry

	// Instances sequentially (legacy parity; m.start re-arms the boot set).
	for _, id := range snap.Instances {
		m.mu.Lock()
		cfg, _ := m.findConfig(id)
		m.mu.Unlock()
		if cfg == nil {
			res.Missing = append(res.Missing, EntityRef{Kind: entityKindInstance, ID: id})
			continue // 8.4: report and continue
		}
		if err := m.start(id); err != nil {
			res.Failed = append(res.Failed, EntityFailure{Kind: entityKindInstance, ID: id, Reason: err.Error()})
			keep.Instances = append(keep.Instances, id)
			continue
		}
		res.Restored = append(res.Restored, EntityRef{Kind: entityKindInstance, ID: id})
	}

	// Services in parallel — independent entities, independent locks (7.6).
	var wg sync.WaitGroup
	var mu sync.Mutex
	for _, id := range snap.Services {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			m.mu.Lock()
			sc, _ := findService(m.st.Services, id)
			m.mu.Unlock()
			if sc == nil {
				mu.Lock()
				res.Missing = append(res.Missing, EntityRef{Kind: entityKindService, ID: id})
				mu.Unlock()
				return // 8.4: report and continue
			}
			if err := m.startService(id); err != nil {
				mu.Lock()
				res.Failed = append(res.Failed, EntityFailure{Kind: entityKindService, ID: id, Reason: err.Error()})
				keep.Services = append(keep.Services, id)
				mu.Unlock()
				return
			}
			mu.Lock()
			res.Restored = append(res.Restored, EntityRef{Kind: entityKindService, ID: id})
			mu.Unlock()
		}(id)
	}
	wg.Wait()

	sort.Slice(res.Restored, func(i, j int) bool { return res.Restored[i].ID < res.Restored[j].ID })
	sort.Slice(res.Failed, func(i, j int) bool { return res.Failed[i].ID < res.Failed[j].ID })
	sort.Slice(res.Missing, func(i, j int) bool { return res.Missing[i].ID < res.Missing[j].ID })

	// Rewritten snapshot: only failed entries survive, for retry.
	m.mu.Lock()
	m.st.StopAllSnapshotV2 = keep
	m.st.StopAllSnapshot = append([]string(nil), keep.Instances...)
	_ = m.persist()
	m.mu.Unlock()
	return res
}
