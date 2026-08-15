package main

import (
	"os"
	"reflect"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Validation boundaries (2.4)
// ---------------------------------------------------------------------------

func TestValidateServiceFieldBoundaries(t *testing.T) {
	base := func() ServiceConfig {
		return ServiceConfig{ID: "x1", Name: "ok", Engine: ServiceEngineDockerDDB, Port: 8000, Storage: ServiceStorage{Mode: ServiceStorageMemory}}
	}
	cases := []struct {
		name    string
		mutate  func(*ServiceConfig)
		wantErr bool
	}{
		{"valid baseline", func(c *ServiceConfig) {}, false},
		{"port 0 = engine default", func(c *ServiceConfig) { c.Port = 0 }, false},
		{"port 1", func(c *ServiceConfig) { c.Port = 1 }, false},
		{"port 65535", func(c *ServiceConfig) { c.Port = 65535 }, false},
		{"port negative", func(c *ServiceConfig) { c.Port = -1 }, true},
		{"port above range", func(c *ServiceConfig) { c.Port = 65536 }, true},
		{"empty name", func(c *ServiceConfig) { c.Name = "" }, true},
		{"whitespace name", func(c *ServiceConfig) { c.Name = "   " }, true},
		{"unknown engine", func(c *ServiceConfig) { c.Engine = "podman" }, true},
		{"java engine ok", func(c *ServiceConfig) { c.Engine = ServiceEngineJava }, false},
		{"localstack engine ok", func(c *ServiceConfig) { c.Engine = ServiceEngineLocalStack; c.Port = 4566 }, false},
		{"bad storage mode", func(c *ServiceConfig) { c.Storage.Mode = "cloud" }, true},
		{"managed storage ok", func(c *ServiceConfig) { c.Storage.Mode = ServiceStorageManaged }, false},
		{"custom java without path", func(c *ServiceConfig) {
			c.Engine = ServiceEngineJava
			c.Storage = ServiceStorage{Mode: ServiceStorageCustom}
		}, true},
		{"custom java with path", func(c *ServiceConfig) {
			c.Engine = ServiceEngineJava
			c.Storage = ServiceStorage{Mode: ServiceStorageCustom, Path: "/data/ddb"}
		}, false},
		{"custom docker without volume", func(c *ServiceConfig) { c.Storage = ServiceStorage{Mode: ServiceStorageCustom} }, true},
		{"custom docker with volume", func(c *ServiceConfig) { c.Storage = ServiceStorage{Mode: ServiceStorageCustom, Volume: "my-vol"} }, false},
		{"engine option scalar ok", func(c *ServiceConfig) {
			c.EngineOptions = map[string]any{"heap": "512m", "n": float64(3), "flag": true}
		}, false},
		{"engine option nested rejected", func(c *ServiceConfig) {
			c.EngineOptions = map[string]any{"bad": map[string]any{"a": 1}}
		}, true},
		{"engine option empty key rejected", func(c *ServiceConfig) {
			c.EngineOptions = map[string]any{" ": "v"}
		}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := base()
			tc.mutate(&c)
			err := validateServiceConfig(&c, nil)
			if (err != nil) != tc.wantErr {
				t.Errorf("validate err=%v, wantErr=%v", err, tc.wantErr)
			}
		})
	}
}

func TestValidateConflictDiagnosticsIncludeIdentities(t *testing.T) {
	existing := []ServiceConfig{
		{ID: "ex1", Name: "Taken", Engine: ServiceEngineDockerDDB, Port: 9000, Storage: ServiceStorage{Mode: ServiceStorageMemory}},
	}
	// Duplicate normalized name: diagnostic names the conflicting Service.
	dup := ServiceConfig{ID: "new1", Name: "  TAKEN ", Engine: ServiceEngineDockerDDB, Port: 9100, Storage: ServiceStorage{Mode: ServiceStorageMemory}}
	err := validateServiceConfig(&dup, existing)
	if err == nil || !strings.Contains(err.Error(), "ex1") {
		t.Errorf("name conflict must identify ex1, got %v", err)
	}
	// Duplicate port: diagnostic names the conflicting Service.
	dp := ServiceConfig{ID: "new2", Name: "Fresh", Engine: ServiceEngineDockerDDB, Port: 9000, Storage: ServiceStorage{Mode: ServiceStorageMemory}}
	err = validateServiceConfig(&dp, existing)
	if err == nil || !strings.Contains(err.Error(), "ex1") {
		t.Errorf("port conflict must identify ex1, got %v", err)
	}
	// Same Service is not a conflict with itself.
	self := existing[0]
	if err := validateServiceConfig(&self, existing); err != nil {
		t.Errorf("self-conflict false positive: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Create / update behavior (2.3, 2.5)
// ---------------------------------------------------------------------------

func TestCreateServiceAssignsIDNormalizesAndPersists(t *testing.T) {
	m := mkManager(t)
	got, err := m.createServiceConfig(ServiceConfig{Name: "Alpha", Engine: ServiceEngineJava})
	if err != nil {
		t.Fatal(err)
	}
	if got.ID == "" {
		t.Fatal("create must assign an ID")
	}
	if got.Port != 8000 || got.Storage.Mode != ServiceStorageMemory {
		t.Errorf("defaults not applied: %+v", got)
	}
	// Persisted atomically: a fresh load sees the same Service.
	m2 := &manager{storePath: m.storePath}
	m2.load()
	if len(m2.st.Services) != 1 || !reflect.DeepEqual(m2.st.Services[0], got) {
		t.Errorf("reload mismatch: %+v", m2.st.Services)
	}
}

func TestCreateInvalidZeroSideEffects(t *testing.T) {
	m := mkManager(t)
	if _, err := m.createServiceConfig(ServiceConfig{Name: "Alpha", Engine: ServiceEngineDockerDDB}); err != nil {
		t.Fatal(err)
	}
	// Duplicate name → rejected with zero side effects.
	if _, err := m.createServiceConfig(ServiceConfig{Name: "alpha", Engine: ServiceEngineDockerDDB}); err == nil {
		t.Fatal("duplicate name must be rejected")
	}
	// Invalid engine → rejected.
	if _, err := m.createServiceConfig(ServiceConfig{Name: "Beta", Engine: "podman"}); err == nil {
		t.Fatal("invalid engine must be rejected")
	}
	if len(m.st.Services) != 1 {
		t.Errorf("failed creates mutated the collection: %+v", m.st.Services)
	}
	// Reload confirms nothing leaked to disk.
	m2 := &manager{storePath: m.storePath}
	m2.load()
	if len(m2.st.Services) != 1 {
		t.Errorf("failed creates leaked to disk: %+v", m2.st.Services)
	}
}

// breakPersist makes the next persist fail by occupying the temp path with a
// directory (os.WriteFile refuses to overwrite a directory).
func breakPersist(t *testing.T, m *manager) {
	t.Helper()
	if err := os.MkdirAll(m.storePath+".tmp", 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestCreatePersistFailureRollsBack(t *testing.T) {
	m := mkManager(t)
	breakPersist(t, m)
	if _, err := m.createServiceConfig(ServiceConfig{Name: "Alpha", Engine: ServiceEngineDockerDDB}); err == nil {
		t.Fatal("persist failure must surface")
	}
	if len(m.st.Services) != 0 {
		t.Errorf("failed persist left the Service in memory: %+v", m.st.Services)
	}
}

func TestUpdateRejectsIDTamperAndUnknownID(t *testing.T) {
	m := mkManager(t)
	created, err := m.createServiceConfig(ServiceConfig{Name: "Alpha", Engine: ServiceEngineDockerDDB})
	if err != nil {
		t.Fatal(err)
	}
	// A payload claiming a different ID is rejected.
	tampered := created
	tampered.ID = "attacker"
	tampered.Name = "Renamed"
	if _, err := m.updateServiceConfig(created.ID, tampered, false); err == nil {
		t.Fatal("id tamper must be rejected")
	}
	// Unknown target ID is rejected (fail closed).
	if _, err := m.updateServiceConfig("nope", created, false); err == nil {
		t.Fatal("unknown id must be rejected")
	}
	if m.st.Services[0].Name != "Alpha" {
		t.Errorf("rejected update mutated the store: %+v", m.st.Services)
	}
}

func TestUpdateRunningIdentityLock(t *testing.T) {
	m := mkManager(t)
	created, err := m.createServiceConfig(ServiceConfig{
		Name: "Alpha", Engine: ServiceEngineJava, Port: 9001,
		Storage: ServiceStorage{Mode: ServiceStorageCustom, Path: "/data/a"},
	})
	if err != nil {
		t.Fatal(err)
	}

	// While running: engine, port, and storage are locked.
	eng := created
	eng.Engine = ServiceEngineDockerDDB
	if _, err := m.updateServiceConfig(created.ID, eng, true); err == nil {
		t.Error("engine change while running must be rejected")
	}
	p := created
	p.Port = 9002
	if _, err := m.updateServiceConfig(created.ID, p, true); err == nil {
		t.Error("port change while running must be rejected")
	}
	st := created
	st.Storage = ServiceStorage{Mode: ServiceStorageMemory}
	if _, err := m.updateServiceConfig(created.ID, st, true); err == nil {
		t.Error("storage change while running must be rejected")
	}

	// Display name stays editable while running.
	renamed := created
	renamed.Name = "Alpha Prime"
	got, err := m.updateServiceConfig(created.ID, renamed, true)
	if err != nil {
		t.Fatalf("name change while running must be allowed: %v", err)
	}
	if got.Name != "Alpha Prime" {
		t.Errorf("rename lost: %+v", got)
	}

	// Stopped: identity fields can change again.
	eng.Engine = ServiceEngineDockerDDB
	eng.Storage = ServiceStorage{Mode: ServiceStorageCustom, Volume: "vol-a"}
	if _, err := m.updateServiceConfig(created.ID, eng, false); err != nil {
		t.Errorf("engine change while stopped must be allowed: %v", err)
	}
}

func TestUpdatePersistFailureRollsBack(t *testing.T) {
	m := mkManager(t)
	created, err := m.createServiceConfig(ServiceConfig{Name: "Alpha", Engine: ServiceEngineDockerDDB})
	if err != nil {
		t.Fatal(err)
	}
	breakPersist(t, m)
	edit := created
	edit.Name = "Beta"
	if _, err := m.updateServiceConfig(created.ID, edit, false); err == nil {
		t.Fatal("persist failure must surface")
	}
	if m.st.Services[0].Name != "Alpha" {
		t.Errorf("failed persist left a partial update: %+v", m.st.Services)
	}
}

// create→create→create keeps insertion order; reload must return the same
// stable order (no silent re-sorting or merging).
func TestServiceListOrderStable(t *testing.T) {
	m := mkManager(t)
	var ids []string
	for i, name := range []string{"zeta", "Alpha", "mid"} {
		c, err := m.createServiceConfig(ServiceConfig{Name: name, Engine: ServiceEngineDockerDDB, Port: 9100 + i})
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, c.ID)
	}
	m2 := &manager{storePath: m.storePath}
	m2.load()
	var got []string
	for _, s := range m2.st.Services {
		got = append(got, s.ID)
	}
	if !reflect.DeepEqual(got, ids) {
		t.Errorf("order not stable: got %v want %v", got, ids)
	}
}
