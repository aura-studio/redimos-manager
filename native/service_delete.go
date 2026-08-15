package main

// Safe Service deletion (10.1–10.8).
//
// Deletion is a transaction ordered so the destructive steps can never outrun
// their proofs:
//
//  1. take the Service's operation lock (the tombstone gate: concurrent
//     lifecycle ops for the ID fail closed from now on);
//  2. stop the Service if it is still up — a failed stop preserves the config;
//  3. with deleteData, prove ownership of each managed resource and clean ONLY
//     what is provably this Service's; anything unprovable is preserved and
//     reported as manual cleanup (custom storage never auto-cleans);
//  4. remove the configuration and persist — the LAST step; a failed write
//     rolls back in memory and keeps the config (or reports partial_delete when
//     data was already cleaned);
//  5. retire the runtime and drop registry ownership.
//
// Ownership proofs: managed filesystem paths pass a symlink-free, canonicalized
// containment proof under the managed root (serviceProveManagedDir); managed
// volumes must carry the exact ownership label quartet and be unmounted by any
// container (removeOwnedServiceVolume). Both fail closed and preserve the data.

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Deletion sentinels. The ABI layer maps these onto error codes (stage 9).
var (
	// errUnsafeDataPath: the managed data path failed the filesystem proof;
	// the data was preserved and the config kept for retry.
	errUnsafeDataPath = errors.New("unsafe_data_path")
	// errUnownedVolume: the volume exists but its labels don't prove this
	// Service owns it (or another container still mounts it); preserved.
	errUnownedVolume = errors.New("unowned_volume")
	// errPartialDelete: managed data was cleaned but the final store write
	// failed; the config is kept and the UI must say the data may be gone.
	errPartialDelete = errors.New("partial_delete")
)

// ServiceDeleteResult reports what one safe deletion actually did.
type ServiceDeleteResult struct {
	ID            string   `json:"id"`
	DataCleaned   bool     `json:"dataCleaned"`             // managed data actually removed
	ManualCleanup []string `json:"manualCleanup,omitempty"` // preserved data the user must clean
	Partial       bool     `json:"partial,omitempty"`       // data cleaned, store write failed
}

// deleteServiceConfig removes one Service safely. deleteData=false only
// removes configuration and registry ownership, preserving every byte of data
// (the default). deleteData=true additionally cleans resources proven to be
// this Service's managed data; anything unprovable is preserved and returned
// as manual-cleanup instructions instead.
func (m *manager) deleteServiceConfig(id string, deleteData bool) (ServiceDeleteResult, error) {
	rt, _, err := m.svcBeginOp(id) // per-ID lock; gone gate rejects post-delete stragglers
	if err != nil {
		return ServiceDeleteResult{}, err
	}

	m.mu.Lock()
	scPtr, _ := findService(m.st.Services, id)
	sc := ServiceConfig{}
	if scPtr != nil {
		sc = *scPtr
	}
	m.mu.Unlock()
	if scPtr == nil {
		m.svcEndOp(rt)
		return ServiceDeleteResult{}, errServiceNotFound
	}

	res := ServiceDeleteResult{ID: id}

	// 2. Stop if necessary. preserveDesired=true: the deletion itself removes
	// the config, so no desired-state write belongs to the stop half. A failed
	// stop preserves the config for retry (10.7).
	if err := m.stopServiceLocked(rt, id, true); err != nil && !errors.Is(err, errInvalidTransition) {
		m.svcEndOp(rt)
		return res, fmt.Errorf("stop service before delete: %w", err)
	}

	// 3. Optional managed-data cleanup, engine-blind through the adapter.
	if deleteData {
		switch sc.Storage.Mode {
		case ServiceStorageMemory:
			// Nothing is persisted on disk or in a volume; nothing to clean.
		case ServiceStorageCustom:
			// User property: auto-deletion is always refused (10.6).
			res.ManualCleanup = append(res.ManualCleanup, manualCleanupHint(sc))
		default: // managed
			ad, aerr := serviceEngineFor(sc.Engine)
			if aerr != nil {
				m.svcEndOp(rt)
				return res, aerr
			}
			if err := ad.deleteManagedData(m, sc); err != nil {
				// Proof or cleanup failed: data AND config preserved (10.7).
				m.svcEndOp(rt)
				return res, err
			}
			res.DataCleaned = true
		}
	}

	// 4. Configuration removal is the LAST step. A failed store write rolls the
	// in-memory removal back; if data was already cleaned the result is the
	// explicit partial-delete state rather than a silent success.
	m.mu.Lock()
	_, idx := findService(m.st.Services, id)
	if idx < 0 {
		m.mu.Unlock()
		m.svcEndOp(rt)
		return res, errServiceNotFound
	}
	removed := m.st.Services[idx]
	m.st.Services = append(m.st.Services[:idx], m.st.Services[idx+1:]...)
	if perr := m.persist(); perr != nil {
		m.st.Services = append(m.st.Services, removed) // roll back
		m.mu.Unlock()
		m.svcEndOp(rt)
		if res.DataCleaned {
			res.Partial = true
			return res, fmt.Errorf("%w: data cleaned but the store write failed: %v", errPartialDelete, perr)
		}
		return res, fmt.Errorf("persist deletion: %w", perr)
	}
	m.mu.Unlock()

	// 5. Retire the runtime (tombstone) and drop registry ownership.
	m.svcRetire(id, rt) // documented opMu-holder exception for m.svcMu
	regRemove(serviceRole(id))
	m.svcEndOp(rt)
	return res, nil
}

// manualCleanupHint is the structured instruction for data the app refuses to
// auto-clean: the exact location, keyed by engine.
func manualCleanupHint(sc ServiceConfig) string {
	switch sc.Engine {
	case ServiceEngineJava:
		return fmt.Sprintf("remove the custom data directory %q", sc.Storage.Path)
	default:
		return fmt.Sprintf("remove the custom volume %q (docker volume rm %s)", sc.Storage.Volume, sc.Storage.Volume)
	}
}

// ---------------------------------------------------------------------------
// Managed filesystem proof (10.4)
// ---------------------------------------------------------------------------

// serviceProveManagedDir proves a managed Java Service's data directory is
// safe to delete and returns the Service's own directory under the managed
// root (the deletion target). Every gate fails closed with errUnsafeDataPath:
//
//  1. storage mode must be managed;
//  2. the managed root is absolute, cleaned, and neither "/", ".", nor the
//     user's home;
//  3. the Service directory root/<id> sits strictly below the root (empty or
//     traversal-bearing IDs are rejected);
//  4. the configured data path canonicalizes INTO that Service directory —
//     other Services' directories, custom paths, and escapes all fail;
//  5. no component from the root down to (and including) the Service
//     directory is a symlink;
//  6. the children registry carries no live child for the Service — deleting
//     data out from under a running process is never allowed.
func serviceProveManagedDir(sc ServiceConfig) (string, error) {
	unsafe := func(why string) error {
		return fmt.Errorf("%w: %s", errUnsafeDataPath, why)
	}
	if sc.Storage.Mode != ServiceStorageManaged {
		return "", unsafe(fmt.Sprintf("storage mode %q is not managed", sc.Storage.Mode))
	}

	root, err := filepath.Abs(serviceManagedRoot())
	if err != nil {
		return "", unsafe("managed root cannot be absolutized")
	}
	root = filepath.Clean(root)
	if root == "" || root == string(os.PathSeparator) || root == "." {
		return "", unsafe(fmt.Sprintf("managed root %q is not deletable", root))
	}
	if home, herr := os.UserHomeDir(); herr == nil && home != "" && root == filepath.Clean(home) {
		return "", unsafe("managed root is the user home directory")
	}

	sep := string(os.PathSeparator)
	own := filepath.Join(root, sc.ID)
	if own == root || !strings.HasPrefix(own, root+sep) || strings.Contains(sc.ID, "..") {
		return "", unsafe(fmt.Sprintf("service directory %q escapes the managed root", own))
	}
	if home, herr := os.UserHomeDir(); herr == nil && home != "" && own == filepath.Clean(home) {
		return "", unsafe("service directory is the user home directory")
	}

	if strings.TrimSpace(sc.Storage.Path) == "" {
		return "", unsafe("managed storage has no data path")
	}
	cand, err := filepath.Abs(sc.Storage.Path)
	if err != nil {
		return "", unsafe("data path cannot be absolutized")
	}
	cand = filepath.Clean(cand)
	if cand != own && !strings.HasPrefix(cand, own+sep) {
		// Covers custom paths, other Services' directories, and any
		// normalization escape (the path is cleaned before comparison).
		return "", unsafe(fmt.Sprintf("data path %q is outside %q", cand, own))
	}

	// Symlink-free containment: walk every component from the root down to the
	// Service directory; a symlink anywhere in the chain could redirect the
	// deletion outside the managed root. An absent component means there is
	// nothing left to delete.
	rel, err := filepath.Rel(root, own)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+sep) {
		return "", unsafe("service directory is not reachable from the managed root")
	}
	cur := root
	for _, part := range strings.Split(rel, sep) {
		cur = filepath.Join(cur, part)
		fi, lerr := os.Lstat(cur)
		if lerr != nil {
			if os.IsNotExist(lerr) {
				break // nothing on disk to delete
			}
			return "", unsafe(fmt.Sprintf("cannot inspect %q", cur))
		}
		if fi.Mode()&os.ModeSymlink != 0 {
			return "", unsafe(fmt.Sprintf("%q is a symlink", cur))
		}
	}

	// No live child may be registered for this Service: its data must not be
	// deleted out from under a running process.
	for _, rec := range regSnapshot() {
		if rec.Role == serviceRole(sc.ID) {
			return "", unsafe("the children registry still lists a live child for this service")
		}
	}
	return own, nil
}
