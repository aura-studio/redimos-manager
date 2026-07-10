package main

// The children registry (~/.redimos/run/children.json) records every child the
// manager spawns, keyed by role, with an exact process identity. It is what
// lets a NEW session tell "our orphan from a dead session" apart from "the
// user's own copy of the same binary" — the old path-substring heuristic could
// not — and it is inherently portable (no PPID semantics, works on Windows).
//
// Lifecycle: written right after a successful spawn, refreshed on supervised
// restarts, removed on terminal exits (stopped / error / failed). Entries left
// behind by a crashed session are resolved by reconcileOnBoot(): dead or
// recycled pids are dropped, live verified ones are killed (or adopted).

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// childRec is one spawned child. (PID, StartUnixMicro, Comm) is an exact
// process identity — a recycled pid can't match the original start time.
type childRec struct {
	Role           string `json:"role"` // "config:<id>" | "ddb"
	PID            int    `json:"pid"`
	StartUnixMicro int64  `json:"startUnixMicro"`
	Comm           string `json:"comm"`
	Port           int    `json:"port"`
	Container      string `json:"container,omitempty"` // docker child: container name
	Bin            string `json:"bin,omitempty"`       // spawn-time binary path (Settings may change later)
	Session        string `json:"session,omitempty"`   // manager session that spawned it
}

type registryFile struct {
	Children []childRec `json:"children"`
}

func registryDir() string  { return filepath.Join(filepath.Dir(defaultStorePath()), "run") }
func registryPath() string { return filepath.Join(registryDir(), "children.json") }

// withRegistry runs fn on the parsed registry under an exclusive cross-process
// file lock and, when fn reports a change, writes it back atomically
// (tmp+rename: a crash mid-write leaves the old file or the new one, never a
// torn one). The lock lives on a sibling .lock file so the rename never fights
// the lock handle (Windows can't rename over an open file). Best-effort: any
// I/O failure degrades to "registry absent", which the sweeps backstop.
func withRegistry(fn func(*registryFile) bool) {
	dir := registryDir()
	_ = os.MkdirAll(dir, 0o755)
	lf, err := os.OpenFile(filepath.Join(dir, "children.lock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return
	}
	defer lf.Close()
	if err := flockExclusive(lf, true); err != nil {
		return
	}
	defer funlock(lf)

	var reg registryFile
	if b, err := os.ReadFile(registryPath()); err == nil {
		_ = json.Unmarshal(b, &reg) // unparsable → treated as empty
	}
	if !fn(&reg) {
		return
	}
	b, err := json.MarshalIndent(reg, "", " ")
	if err != nil {
		return
	}
	tmp := registryPath() + ".tmp"
	if os.WriteFile(tmp, b, 0o644) != nil {
		return
	}
	_ = os.Rename(tmp, registryPath())
}

// regUpsert records/refreshes the child for rec.Role (one live child per role).
func regUpsert(rec childRec) {
	if rec.Role == "" {
		return
	}
	withRegistry(func(r *registryFile) bool {
		for i := range r.Children {
			if r.Children[i].Role == rec.Role {
				r.Children[i] = rec
				return true
			}
		}
		r.Children = append(r.Children, rec)
		return true
	})
}

// regRemove drops the child recorded for role (no-op when absent).
func regRemove(role string) {
	if role == "" {
		return
	}
	withRegistry(func(r *registryFile) bool {
		for i := range r.Children {
			if r.Children[i].Role == role {
				r.Children = append(r.Children[:i], r.Children[i+1:]...)
				return true
			}
		}
		return false
	})
}

// regSnapshot returns a copy of the current registry contents.
func regSnapshot() []childRec {
	var out []childRec
	withRegistry(func(r *registryFile) bool {
		out = append(out, r.Children...)
		return false
	})
	return out
}
