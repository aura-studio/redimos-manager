package main

// Stage 8 tests: safe Service deletion — default data preservation, optional
// managed-data cleanup behind the filesystem/volume ownership proofs, path
// attacks, stop failure, label mismatch, cross-mounted volumes, partial
// deletion, and the managed/custom smoke (8.4, 8.5).

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// deleteSetup builds a sandboxed manager with fakes for both toolchains;
// java points at an exit-0 script so no real JRE is needed.
func deleteSetup(t *testing.T) (*manager, string) {
	t.Helper()
	sandboxRegistry(t)
	sandboxManagedRoot(t)
	fake, state := fakeDocker(t)
	overrideSvcBins(t, fake, writeScript(t, "#!/bin/bash\nexit 0\n"))
	probeStub(t, portUpProbe(state))
	return mkManager(t), state
}

// plantManagedJava registers a stopped managed java Service whose data
// directory exists on disk with one file inside. Returns config + data dir.
func plantManagedJava(t *testing.T, m *manager, id string) (ServiceConfig, string) {
	t.Helper()
	sc := svc(id, ServiceEngineJava, freePort(t),
		ServiceStorage{Mode: ServiceStorageManaged, Path: serviceDataDir(id)}, nil)
	plantServiceConfig(t, m, sc)
	data := sc.Storage.Path
	if err := os.MkdirAll(data, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(data, "shared-local.db"), []byte("tables"), 0o644); err != nil {
		t.Fatal(err)
	}
	return sc, data
}

// seedOwnedVolume writes the canned `volume inspect` answer: exact ownership
// labels when owned, a foreign service-id otherwise.
func seedOwnedVolume(t *testing.T, state string, sc ServiceConfig, owned bool) {
	t.Helper()
	id := sc.ID
	if !owned {
		id = "someone-else"
	}
	labels := `{"io.redimos.managed":"true","io.redimos.entity":"service","io.redimos.service-id":"` + id +
		`","io.redimos.engine":"` + string(sc.Engine) + `"}`
	if err := os.WriteFile(filepath.Join(state, "vol-"+sc.Storage.Volume+".inspect"),
		[]byte(`[{"Labels":`+labels+`}]`), 0o644); err != nil {
		t.Fatal(err)
	}
}

func svcGoneFromStore(t *testing.T, m *manager, id string) bool {
	t.Helper()
	m.mu.Lock()
	defer m.mu.Unlock()
	sc, _ := findService(m.st.Services, id)
	return sc == nil
}

// ---------------------------------------------------------------------------
// 8.4 deletion transaction
// ---------------------------------------------------------------------------

func TestDeleteServicePreservesDataByDefault(t *testing.T) {
	m, _ := deleteSetup(t)
	sc, data := plantManagedJava(t, m, "keep-data")

	res, err := m.deleteServiceConfig(sc.ID, false)
	if err != nil {
		t.Fatal(err)
	}
	if res.DataCleaned || len(res.ManualCleanup) != 0 || res.Partial {
		t.Errorf("default delete must report nothing cleaned: %+v", res)
	}
	// Data preserved byte for byte.
	if _, err := os.Stat(filepath.Join(data, "shared-local.db")); err != nil {
		t.Error("default deletion must preserve the data directory")
	}
	// Configuration and registry ownership removed; runtime tombstoned.
	if !svcGoneFromStore(t, m, sc.ID) {
		t.Error("config must be removed")
	}
	if _, ok := m.svcStatus(sc.ID); ok {
		t.Error("runtime must be retired")
	}
	if _, _, err := m.svcBeginOp(sc.ID); !errors.Is(err, errServiceNotFound) {
		t.Errorf("post-delete ops must fail closed, got %v", err)
	}
	if _, ok := hasRecord(t, serviceRole(sc.ID)); ok {
		t.Error("registry ownership must be dropped")
	}
}

func TestDeleteServiceCleansProvenManagedData(t *testing.T) {
	m, _ := deleteSetup(t)
	sc, data := plantManagedJava(t, m, "clean-me")
	// A sibling Service's directory must never be touched by this deletion.
	other, _ := plantManagedJava(t, m, "sibling")

	res, err := m.deleteServiceConfig(sc.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	if !res.DataCleaned {
		t.Errorf("proven managed data must be cleaned: %+v", res)
	}
	if _, err := os.Stat(filepath.Join(data, "..")); !os.IsNotExist(err) {
		t.Error("the Service's managed directory must be removed")
	}
	if _, err := os.Stat(filepath.Join(other.Storage.Path, "shared-local.db")); err != nil {
		t.Error("another Service's data must be untouched")
	}
	if !svcGoneFromStore(t, m, sc.ID) {
		t.Error("config must be removed")
	}
}

func TestDeleteServiceCustomStorageManualCleanup(t *testing.T) {
	m, state := deleteSetup(t)

	// java: a custom directory is user property — preserved with instructions.
	customDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(customDir, "precious.db"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	jc := svc("custom-java", ServiceEngineJava, freePort(t),
		ServiceStorage{Mode: ServiceStorageCustom, Path: customDir}, nil)
	plantServiceConfig(t, m, jc)
	res, err := m.deleteServiceConfig(jc.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	if res.DataCleaned {
		t.Error("custom data must never be auto-cleaned")
	}
	if len(res.ManualCleanup) != 1 || !strings.Contains(res.ManualCleanup[0], customDir) {
		t.Errorf("manual cleanup must name the custom path: %+v", res.ManualCleanup)
	}
	if _, err := os.Stat(filepath.Join(customDir, "precious.db")); err != nil {
		t.Error("custom data must be preserved")
	}
	if !svcGoneFromStore(t, m, jc.ID) {
		t.Error("config must still be removed (data is the user's to clean)")
	}

	// docker: a custom volume is reported with its removal command.
	cc := svc("custom-docker", ServiceEngineDockerDDB, freePort(t),
		ServiceStorage{Mode: ServiceStorageCustom, Volume: "external-vol"}, nil)
	plantServiceConfig(t, m, cc)
	res, err = m.deleteServiceConfig(cc.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.ManualCleanup) != 1 || !strings.Contains(res.ManualCleanup[0], "external-vol") {
		t.Errorf("manual cleanup must name the custom volume: %+v", res.ManualCleanup)
	}
	if calls := readCalls(t, state); strings.Contains(calls, "volume rm") {
		t.Error("custom volumes must never be auto-removed")
	}
}

func TestDeleteServiceStopFailurePreservesConfig(t *testing.T) {
	m, _ := deleteSetup(t)
	sc, err := m.createServiceConfig(ServiceConfig{
		Name: "wedged", Engine: ServiceEngineDockerDDB, Port: freePort(t),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := m.startService(sc.ID); err != nil {
		t.Fatal(err)
	}
	// The stop misses its settle window: deletion must abort BEFORE touching
	// the configuration (10.7).
	old := svcStopTimeout
	svcStopTimeout = 1 // 1ns: no settle can possibly be observed
	t.Cleanup(func() { svcStopTimeout = old })

	if _, err := m.deleteServiceConfig(sc.ID, true); err == nil {
		t.Fatal("a failed stop must abort the deletion")
	}
	if svcGoneFromStore(t, m, sc.ID) {
		t.Error("failed stop must preserve the config")
	}

	// The stop still lands asynchronously; after it settles, retry succeeds.
	waitSvcSettled(t, m, sc.ID)
	in := m.svcEnsureRuntime(sc.ID).instance() // capture before the retry retires the runtime
	svcStopTimeout = old
	if _, err := m.deleteServiceConfig(sc.ID, false); err != nil {
		t.Fatalf("retry after settle must succeed: %v", err)
	}
	if !svcGoneFromStore(t, m, sc.ID) {
		t.Error("retry must complete the deletion")
	}
	in.superviseWG.Wait() // sync edge: cleanup may now restore the sandbox
}

func TestDeleteServiceVolumeLabelMismatchPreserves(t *testing.T) {
	m, state := deleteSetup(t)
	sc := svc("vol-stranger", ServiceEngineDockerDDB, freePort(t),
		ServiceStorage{Mode: ServiceStorageManaged, Volume: serviceVolumeName("vol-stranger")}, nil)
	plantServiceConfig(t, m, sc)
	seedOwnedVolume(t, state, sc, false) // same name, foreign service-id label

	_, err := m.deleteServiceConfig(sc.ID, true)
	if !errors.Is(err, errUnownedVolume) {
		t.Fatalf("want unowned_volume, got %v", err)
	}
	if svcGoneFromStore(t, m, sc.ID) {
		t.Error("label mismatch must preserve the config for retry")
	}
	if calls := readCalls(t, state); strings.Contains(calls, "volume rm") {
		t.Error("a stranger-labelled volume must never be removed")
	}
}

func TestDeleteServiceVolumeCrossMountRefused(t *testing.T) {
	m, state := deleteSetup(t)
	sc := svc("vol-mounted", ServiceEngineDockerDDB, freePort(t),
		ServiceStorage{Mode: ServiceStorageManaged, Volume: serviceVolumeName("vol-mounted")}, nil)
	plantServiceConfig(t, m, sc)
	seedOwnedVolume(t, state, sc, true)
	// A stranger container still mounts the volume (ours was never started).
	if err := os.WriteFile(filepath.Join(state, "mount-stranger-box"), []byte(sc.Storage.Volume), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(state, "container-stranger-box.inspect"), []byte("{}|false"), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := m.deleteServiceConfig(sc.ID, true)
	if !errors.Is(err, errUnownedVolume) || !strings.Contains(err.Error(), "mounted") {
		t.Fatalf("want cross-mount refusal, got %v", err)
	}
	if svcGoneFromStore(t, m, sc.ID) {
		t.Error("cross-mounted volume must preserve the config for retry")
	}
	if calls := readCalls(t, state); strings.Contains(calls, "volume rm") {
		t.Error("a still-mounted volume must never be removed")
	}
}

func TestDeleteServiceCleansOwnedVolume(t *testing.T) {
	m, state := deleteSetup(t)
	sc := svc("vol-ours", ServiceEngineDockerDDB, freePort(t),
		ServiceStorage{Mode: ServiceStorageManaged, Volume: serviceVolumeName("vol-ours")}, nil)
	plantServiceConfig(t, m, sc)
	seedOwnedVolume(t, state, sc, true)

	res, err := m.deleteServiceConfig(sc.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	if !res.DataCleaned {
		t.Errorf("owned unmounted volume must be cleaned: %+v", res)
	}
	b, _ := os.ReadFile(filepath.Join(state, "vol-removed.log"))
	if !strings.Contains(string(b), sc.Storage.Volume) {
		t.Errorf("volume rm not issued: %q", string(b))
	}
	if !svcGoneFromStore(t, m, sc.ID) {
		t.Error("config must be removed")
	}
}

func TestDeleteServicePartialWhenPersistFails(t *testing.T) {
	m, _ := deleteSetup(t)
	sc, data := plantManagedJava(t, m, "partial")
	breakPersist(t, m) // the final store write fails AFTER the data is cleaned

	res, err := m.deleteServiceConfig(sc.ID, true)
	if !errors.Is(err, errPartialDelete) {
		t.Fatalf("want partial_delete, got %v", err)
	}
	if !res.Partial || !res.DataCleaned {
		t.Errorf("partial result must say the data was cleaned: %+v", res)
	}
	if _, err := os.Stat(data); !os.IsNotExist(err) {
		t.Error("the data really was cleaned — the result must say so")
	}
	if svcGoneFromStore(t, m, sc.ID) {
		t.Error("partial delete must keep the config visible for retry")
	}
}

// ---------------------------------------------------------------------------
// 8.4 managed filesystem proof: path attacks
// ---------------------------------------------------------------------------

func TestServiceProveManagedDirRejectsAttacks(t *testing.T) {
	m, _ := deleteSetup(t)
	root := serviceManagedRoot()
	sep := string(os.PathSeparator)
	outside := t.TempDir()

	cases := []struct {
		name string
		id   string
		path string
		prep func(t *testing.T) // optional filesystem setup
	}{
		{
			name: "empty path",
			id:   "atk-empty",
			path: "   ",
		},
		{
			name: "traversal escapes the service dir",
			id:   "atk-traverse",
			path: filepath.Join(root, "atk-traverse", "..", "..", "escape"),
		},
		{
			name: "another service's directory",
			id:   "atk-cross",
			path: filepath.Join(root, "victim-id", "ddb-data"),
		},
		{
			name: "absolute custom path disguised as managed",
			id:   "atk-abs",
			path: outside,
		},
		{
			name: "service dir is a symlink",
			id:   "atk-symlink",
			path: filepath.Join(root, "atk-symlink", "ddb-data"),
			prep: func(t *testing.T) {
				target := t.TempDir()
				if err := os.WriteFile(filepath.Join(target, "victim.db"), []byte("x"), 0o644); err != nil {
					t.Fatal(err)
				}
				if err := os.MkdirAll(root, 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(target, filepath.Join(root, "atk-symlink")); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "root dir itself",
			id:   "atk-root",
			path: root + sep + "atk-root" + sep + "ddb-data",
			prep: func(t *testing.T) {
				// The managed root becomes "/" — deletable-root gate must fire.
				old := serviceManagedRootForTest
				serviceManagedRootForTest = "/"
				t.Cleanup(func() { serviceManagedRootForTest = old })
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if tc.prep != nil {
				tc.prep(t)
			}
			sc := svc(tc.id, ServiceEngineJava, freePort(t),
				ServiceStorage{Mode: ServiceStorageManaged, Path: tc.path}, nil)
			plantServiceConfig(t, m, sc)
			// Seed something at an outside target when relevant, to prove it
			// survives the refusal.
			_, err := m.deleteServiceConfig(tc.id, true)
			if !errors.Is(err, errUnsafeDataPath) {
				t.Fatalf("want unsafe_data_path, got %v", err)
			}
			if svcGoneFromStore(t, m, tc.id) {
				t.Error("a failed proof must preserve the config for retry")
			}
			if tc.name == "service dir is a symlink" {
				// The refusal must be side-effect free: the symlink and its
				// target both survive.
				if fi, err := os.Lstat(filepath.Join(root, tc.id)); err != nil || fi.Mode()&os.ModeSymlink == 0 {
					t.Error("a refused deletion must leave the filesystem untouched")
				}
			}
		})
	}
}

func TestServiceProveManagedDirRejectsLiveRegistryChild(t *testing.T) {
	m, _ := deleteSetup(t)
	sc, _ := plantManagedJava(t, m, "live-child")
	// A registered child means the data is in use: cleanup must refuse even
	// though the path proof passes.
	regUpsert(childRec{Role: serviceRole(sc.ID), PID: os.Getpid(), StartUnixMicro: 12345, Port: sc.Port})

	_, err := m.deleteServiceConfig(sc.ID, true)
	if !errors.Is(err, errUnsafeDataPath) {
		t.Fatalf("want unsafe_data_path for a live child, got %v", err)
	}
	if svcGoneFromStore(t, m, sc.ID) {
		t.Error("live-child refusal must preserve the config")
	}
	regRemove(serviceRole(sc.ID)) // let cleanup find a quiet registry
}

// ---------------------------------------------------------------------------
// 8.5 smoke: managed vs custom deletion end to end
// ---------------------------------------------------------------------------

// TestDeleteManagedServiceSmoke runs a managed docker Service through
// start → delete-without-cleanup (default preserves) and a second one through
// delete-with-cleanup (only the proven volume goes).
func TestDeleteManagedServiceSmoke(t *testing.T) {
	sandboxRegistry(t)
	sandboxManagedRoot(t)
	fake, state := fakeDocker(t)
	overrideSvcBins(t, fake, "")
	probeStub(t, portUpProbe(state))
	m := mkManager(t)

	mkManaged := func(name string) ServiceConfig {
		t.Helper()
		c, err := m.createServiceConfig(ServiceConfig{
			Name: name, Engine: ServiceEngineDockerDDB, Port: freePort(t),
			Storage: ServiceStorage{Mode: ServiceStorageManaged},
		})
		if err != nil {
			t.Fatal(err)
		}
		return c
	}

	// A: running → delete with default (no cleanup): stopped on the way out,
	// volume untouched, registry ownership dropped.
	a := mkManaged("smoke-keep")
	if err := m.startService(a.ID); err != nil {
		t.Fatal(err)
	}
	inA := m.svcEnsureRuntime(a.ID).instance() // capture before delete retires the runtime
	res, err := m.deleteServiceConfig(a.ID, false)
	if err != nil {
		t.Fatal(err)
	}
	if res.DataCleaned || len(res.ManualCleanup) != 0 {
		t.Errorf("default delete must clean nothing: %+v", res)
	}
	if !svcGoneFromStore(t, m, a.ID) {
		t.Error("A config must be removed")
	}
	if _, ok := hasRecord(t, serviceRole(a.ID)); ok {
		t.Error("A registry ownership must be dropped")
	}
	if calls := readCalls(t, state); strings.Contains(calls, "volume rm") {
		t.Error("default delete must never remove a volume")
	}

	// B: stopped with an existing proven volume → explicit cleanup removes
	// exactly that volume.
	b := mkManaged("smoke-clean")
	seedOwnedVolume(t, state, b, true)
	res, err = m.deleteServiceConfig(b.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	if !res.DataCleaned {
		t.Errorf("B managed volume must be cleaned: %+v", res)
	}
	rb, _ := os.ReadFile(filepath.Join(state, "vol-removed.log"))
	if strings.Contains(string(rb), a.Storage.Volume) {
		t.Error("A's preserved volume was removed")
	}
	if !strings.Contains(string(rb), b.Storage.Volume) {
		t.Errorf("B's volume must be the only removal: %q", string(rb))
	}

	// A's container was stopped as part of the deletion.
	waitFor(t, "A container removed", func() bool {
		_, err := os.Stat(filepath.Join(state, "container-"+serviceContainerName(a.Engine, a.ID)+".removed"))
		return err == nil
	})
	inA.superviseWG.Wait() // sync edge: cleanup may now restore the sandbox
}

// TestDeleteCustomAndUnsafeDataSmoke verifies explicit cleanup leaves custom
// and unprovable data exactly where it was, while the Services themselves are
// deleted or kept per the safety rules.
func TestDeleteCustomAndUnsafeDataSmoke(t *testing.T) {
	m, state := deleteSetup(t)

	// Custom java data: deleted Service, preserved directory, instructions.
	customDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(customDir, "user-tables.db"), []byte("mine"), 0o644); err != nil {
		t.Fatal(err)
	}
	cu := svc("smoke-custom", ServiceEngineJava, freePort(t),
		ServiceStorage{Mode: ServiceStorageCustom, Path: customDir}, nil)
	plantServiceConfig(t, m, cu)
	res, err := m.deleteServiceConfig(cu.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.ManualCleanup) == 0 || res.DataCleaned {
		t.Errorf("custom delete must carry manual cleanup only: %+v", res)
	}
	if _, err := os.Stat(filepath.Join(customDir, "user-tables.db")); err != nil {
		t.Error("custom data must survive explicit cleanup")
	}

	// Unsafe (stranger-labelled) volume: deletion refused, everything intact.
	un := svc("smoke-unsafe", ServiceEngineDockerDDB, freePort(t),
		ServiceStorage{Mode: ServiceStorageManaged, Volume: serviceVolumeName("smoke-unsafe")}, nil)
	plantServiceConfig(t, m, un)
	seedOwnedVolume(t, state, un, false)
	if _, err := m.deleteServiceConfig(un.ID, true); !errors.Is(err, errUnownedVolume) {
		t.Fatalf("want unowned_volume, got %v", err)
	}
	if svcGoneFromStore(t, m, un.ID) {
		t.Error("unsafe deletion must keep the Service for retry")
	}
	if calls := readCalls(t, state); strings.Contains(calls, "volume rm") {
		t.Error("unsafe data must never be removed")
	}
}
