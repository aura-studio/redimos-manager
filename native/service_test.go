package main

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// Identity, naming, normalization
// ---------------------------------------------------------------------------

func TestNewServiceIDIsIndependentAndUnique(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 256; i++ {
		id := newServiceID()
		if id == "" {
			t.Fatal("empty service id")
		}
		if seen[id] {
			t.Fatalf("duplicate service id %q", id)
		}
		seen[id] = true
	}
}

func TestNormalizeServiceName(t *testing.T) {
	cases := map[string]string{
		"My Service":  "my service",
		"  PADDED  ":  "padded",
		"Ünïcode":     "ünïcode",
		"already-low": "already-low",
	}
	for in, want := range cases {
		if got := normalizeServiceName(in); got != want {
			t.Errorf("normalizeServiceName(%q)=%q want %q", in, got, want)
		}
	}
	if normalizeServiceName("Local DDB") != normalizeServiceName("local ddb") {
		t.Error("case-folded names must compare equal")
	}
}

func TestSortServicesStable(t *testing.T) {
	list := []ServiceConfig{
		{ID: "z9", Name: "beta"},
		{ID: "a1", Name: "Alpha"},
		{ID: "m5", Name: "alpha"}, // same normalized name: ID tie-break
		{ID: "b2", Name: "gamma"},
	}
	sortServices(list)
	got := []string{list[0].ID, list[1].ID, list[2].ID, list[3].ID}
	want := []string{"a1", "m5", "z9", "b2"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("sort order = %v, want %v", got, want)
	}
	// Sorting an already-sorted list must not reorder (stability).
	again := append([]ServiceConfig(nil), list...)
	sortServices(again)
	if !reflect.DeepEqual(again, list) {
		t.Errorf("second sort changed order: %+v", again)
	}
}

func TestNormalizeServiceDefaults(t *testing.T) {
	// Empty engine/storage → docker + memory; port 0 → engine default.
	c := normalizeService(ServiceConfig{ID: "abc123", Name: "s"})
	if c.Engine != ServiceEngineDockerDDB {
		t.Errorf("default engine = %q", c.Engine)
	}
	if c.Storage.Mode != ServiceStorageMemory {
		t.Errorf("default storage mode = %q", c.Storage.Mode)
	}
	if c.Port != 8000 {
		t.Errorf("default port = %d", c.Port)
	}

	// LocalStack resolves port 0 to 4566, not 8000.
	ls := normalizeService(ServiceConfig{ID: "abc123", Name: "ls", Engine: ServiceEngineLocalStack})
	if ls.Port != 4566 {
		t.Errorf("localstack default port = %d", ls.Port)
	}

	// Explicit non-zero port is preserved.
	p := normalizeService(ServiceConfig{ID: "abc123", Name: "p", Port: 9123})
	if p.Port != 9123 {
		t.Errorf("explicit port changed to %d", p.Port)
	}

	// Managed storage defaults derive from the Service ID — never a shared
	// engine-wide path.
	jm := normalizeService(ServiceConfig{ID: "id-one", Name: "j", Engine: ServiceEngineJava, Storage: ServiceStorage{Mode: ServiceStorageManaged}})
	if !strings.Contains(jm.Storage.Path, "id-one") {
		t.Errorf("managed java path %q not keyed by id", jm.Storage.Path)
	}
	dm := normalizeService(ServiceConfig{ID: "id-two", Name: "d", Engine: ServiceEngineDockerDDB, Storage: ServiceStorage{Mode: ServiceStorageManaged}})
	if !strings.Contains(dm.Storage.Volume, "id-two") {
		t.Errorf("managed docker volume %q not keyed by id", dm.Storage.Volume)
	}
	// Explicit managed locations are preserved.
	cu := normalizeService(ServiceConfig{ID: "id-x", Name: "c", Engine: ServiceEngineJava, Storage: ServiceStorage{Mode: ServiceStorageManaged, Path: "/data/mine"}})
	if cu.Storage.Path != "/data/mine" {
		t.Errorf("explicit managed path overwritten: %q", cu.Storage.Path)
	}
}

func TestServiceResourceNamingKeyedByID(t *testing.T) {
	if serviceContainerName(ServiceEngineDockerDDB, "aaa") == serviceContainerName(ServiceEngineDockerDDB, "bbb") {
		t.Error("container names collide across services")
	}
	if serviceContainerName(ServiceEngineLocalStack, "aaa") == serviceContainerName(ServiceEngineDockerDDB, "aaa") {
		t.Error("localstack and ddb container names collide")
	}
	for _, id := range []string{"aaa", "bbb"} {
		if !strings.Contains(serviceVolumeName(id), id) || !strings.Contains(serviceDataDir(id), id) {
			t.Errorf("volume/data dir not keyed by id %q", id)
		}
	}
	if serviceVolumeName("aaa") == serviceVolumeName("bbb") {
		t.Error("volumes collide across services")
	}
	if serviceRole("abc") != "service:abc" {
		t.Errorf("serviceRole = %q", serviceRole("abc"))
	}
}

// ---------------------------------------------------------------------------
// JSON round-trip and store integration
// ---------------------------------------------------------------------------

func TestServiceConfigJSONRoundTrip(t *testing.T) {
	in := ServiceConfig{
		ID:     "f00dcafe",
		Name:   "Main DDB",
		Engine: ServiceEngineJava,
		Port:   9001,
		Storage: ServiceStorage{
			Mode:   ServiceStorageCustom,
			Path:   "/tmp/ddb-data",
			Volume: "ignored-for-java",
		},
		EngineOptions:  map[string]any{"heap": "512m", "delayTransactedError": true},
		DesiredRunning: true,
	}
	b, err := json.Marshal(in)
	if err != nil {
		t.Fatal(err)
	}
	var out ServiceConfig
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(in, out) {
		t.Errorf("round trip mismatch:\n in=%+v\n out=%+v", in, out)
	}
}

func TestServiceStoreRoundTrip(t *testing.T) {
	m := mkManager(t)
	m.st.Services = []ServiceConfig{
		{ID: "s1", Name: "Alpha", Engine: ServiceEngineDockerDDB, Port: 8000, Storage: ServiceStorage{Mode: ServiceStorageMemory}, DesiredRunning: true},
		{ID: "s2", Name: "Beta", Engine: ServiceEngineLocalStack, Port: 4566, Storage: ServiceStorage{Mode: ServiceStorageManaged, Volume: "redimos-service-s2-data"}},
	}
	m.st.StopAllSnapshotV2 = GlobalStopSnapshot{Instances: []string{"i1"}, Services: []string{"s1"}}
	if err := m.persist(); err != nil {
		t.Fatal(err)
	}
	m2 := &manager{storePath: m.storePath}
	m2.load()
	if !reflect.DeepEqual(m.st.Services, m2.st.Services) {
		t.Errorf("services lost in round trip:\n before=%+v\n after =%+v", m.st.Services, m2.st.Services)
	}
	if !reflect.DeepEqual(m.st.StopAllSnapshotV2, m2.st.StopAllSnapshotV2) {
		t.Errorf("typed snapshot lost: %+v", m2.st.StopAllSnapshotV2)
	}
	if len(m2.serviceLoadErrors) != 0 {
		t.Errorf("unexpected load errors: %v", m2.serviceLoadErrors)
	}
}

func TestServicePersistAtomicAndClean(t *testing.T) {
	m := mkManager(t)
	m.st.Services = []ServiceConfig{{ID: "s1", Name: "a", Engine: ServiceEngineDockerDDB}}
	if err := m.persist(); err != nil {
		t.Fatal(err)
	}
	// The atomic write must not leave its temporary file behind.
	dir := m.storePath[:strings.LastIndex(m.storePath, "/")]
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Errorf("leftover temp file %q", e.Name())
		}
	}
}

// ---------------------------------------------------------------------------
// Legacy store behavior (1.5 smoke: legacy singleton input)
// ---------------------------------------------------------------------------

const legacySingletonStore = `{
  "configs": [
    {"id":"a","name":"prod","version":"v1","port":6379,"table":"t1","region":"us-east-1"}
  ],
  "settings": {"redimosV1Path":"/bin/v1"},
  "localDdb": {"engine":"docker","port":8000,"storage":"memory"},
  "ddbAutoStart": true,
  "autoStart": ["a"],
  "stopAllSnapshot": ["a"]
}`

func TestLegacySingletonFieldsIgnored(t *testing.T) {
	m := mkManager(t)
	if err := os.WriteFile(m.storePath, []byte(legacySingletonStore), 0o644); err != nil {
		t.Fatal(err)
	}
	m.load()

	// Legacy singleton input produces an EMPTY Service collection and no
	// legacy lifecycle state.
	if len(m.st.Services) != 0 {
		t.Errorf("legacy store must produce no services, got %+v", m.st.Services)
	}
	if m.st.DdbAutoStart || m.st.LocalDdb.Engine != "" {
		t.Errorf("legacy singleton state must be ignored: %+v %+v", m.st.LocalDdb, m.st.DdbAutoStart)
	}
	// Other entities survive.
	if len(m.st.Configs) != 1 || m.st.Settings.RedimosV1Path != "/bin/v1" || len(m.st.AutoStart) != 1 {
		t.Errorf("legacy load lost other entities: %+v", m.st)
	}
	// Legacy string-array snapshot migrates read-only into the typed snapshot.
	if !reflect.DeepEqual(m.st.StopAllSnapshotV2.Instances, []string{"a"}) || len(m.st.StopAllSnapshotV2.Services) != 0 {
		t.Errorf("snapshot migration wrong: %+v", m.st.StopAllSnapshotV2)
	}

	// The next write drops the legacy singleton fields entirely.
	if err := m.persist(); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(m.storePath)
	if err != nil {
		t.Fatal(err)
	}
	var disk map[string]json.RawMessage
	if err := json.Unmarshal(raw, &disk); err != nil {
		t.Fatalf("rewritten store is not valid JSON: %v", err)
	}
	for _, banned := range []string{"localDdb", "ddbAutoStart"} {
		if _, ok := disk[banned]; ok {
			t.Errorf("rewritten store still contains legacy field %q", banned)
		}
	}
	if _, ok := disk["stopAllSnapshotV2"]; !ok {
		t.Errorf("rewritten store is missing the typed snapshot key")
	}
	if _, ok := disk["settings"]; !ok {
		t.Errorf("rewritten store lost settings")
	}

	// Reload keeps everything alive without the legacy fields.
	m2 := &manager{storePath: m.storePath}
	m2.load()
	if !reflect.DeepEqual(m.st.Configs, m2.st.Configs) {
		t.Errorf("reload lost configs")
	}
	if !reflect.DeepEqual(m.st.StopAllSnapshotV2, m2.st.StopAllSnapshotV2) {
		t.Errorf("reload lost typed snapshot: %+v", m2.st.StopAllSnapshotV2)
	}
}

func TestTypedSnapshotWinsOverLegacy(t *testing.T) {
	file := `{
	  "settings": {},
	  "stopAllSnapshot": ["old-instance"],
	  "stopAllSnapshotV2": {"services": ["svc-1"]}
	}`
	m := mkManager(t)
	if err := os.WriteFile(m.storePath, []byte(file), 0o644); err != nil {
		t.Fatal(err)
	}
	m.load()
	// When both keys exist the typed snapshot is used verbatim — no merge.
	if !reflect.DeepEqual(m.st.StopAllSnapshotV2, GlobalStopSnapshot{Services: []string{"svc-1"}}) {
		t.Errorf("typed snapshot not preferred verbatim: %+v", m.st.StopAllSnapshotV2)
	}
}

// ---------------------------------------------------------------------------
// Corrupt / hostile persisted data
// ---------------------------------------------------------------------------

func TestMalformedStoreFileFallsBackToEmpty(t *testing.T) {
	m := mkManager(t)
	if err := os.WriteFile(m.storePath, []byte("{this is not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	m.load() // must not panic
	if len(m.st.Configs) != 0 || len(m.st.Services) != 0 {
		t.Errorf("malformed file must yield an empty store")
	}
	// The store is usable afterwards.
	m.st.Services = []ServiceConfig{{ID: "s1", Name: "a", Engine: ServiceEngineDockerDDB}}
	if err := m.persist(); err != nil {
		t.Fatal(err)
	}
}

// A corrupt services collection must not wipe the other entities, and the next
// persist must keep them intact.
func TestCorruptServicesFieldPreservesOtherEntities(t *testing.T) {
	file := `{
	  "endpoints": [{"id":"ep1","name":"local","kind":"local","endpoint":"http://localhost:8079"}],
	  "instances": [{"id":"i1","name":"inst","version":"v1","port":6379,"table":"t","endpointId":"ep1"}],
	  "settings": {"redimosV1Path":"/bin/v1"},
	  "services": "definitely-not-an-array"
	}`
	m := mkManager(t)
	if err := os.WriteFile(m.storePath, []byte(file), 0o644); err != nil {
		t.Fatal(err)
	}
	m.load()
	if len(m.st.Services) != 0 {
		t.Errorf("corrupt services must load empty, got %+v", m.st.Services)
	}
	if len(m.serviceLoadErrors) == 0 {
		t.Error("corrupt services must be reported")
	}
	if len(m.st.Configs) != 1 || m.st.Settings.RedimosV1Path != "/bin/v1" {
		t.Errorf("other entities lost: %+v", m.st)
	}

	// Next persist must NOT wipe the healthy entities.
	if err := m.persist(); err != nil {
		t.Fatal(err)
	}
	m2 := &manager{storePath: m.storePath}
	m2.load()
	if len(m2.st.Configs) != 1 || m2.st.Settings.RedimosV1Path != "/bin/v1" {
		t.Errorf("persist after corrupt services wiped entities: %+v", m2.st)
	}
}

// Bad entries inside an otherwise readable array are skipped individually;
// healthy siblings survive.
func TestPartiallyCorruptServicesArray(t *testing.T) {
	file := `{
	  "settings": {},
	  "services": [
	    {"id":"good1","name":"ok","engine":"docker","port":8000},
	    {"id":12345},
	    {"id":"good2","name":"also-ok","engine":"java","port":9000}
	  ]
	}`
	m := mkManager(t)
	if err := os.WriteFile(m.storePath, []byte(file), 0o644); err != nil {
		t.Fatal(err)
	}
	m.load()
	if len(m.st.Services) != 2 || m.st.Services[0].ID != "good1" || m.st.Services[1].ID != "good2" {
		t.Errorf("healthy entries lost: %+v", m.st.Services)
	}
	if len(m.serviceLoadErrors) == 0 {
		t.Error("bad entry must be reported")
	}
}

func TestDuplicateAndInvalidServiceEntriesRejected(t *testing.T) {
	file := `{
	  "settings": {},
	  "services": [
	    {"id":"s1","name":"alpha","engine":"java","port":9001},
	    {"id":"s1","name":"beta","engine":"docker","port":9002},
	    {"id":"s2","name":"ALPHA ","engine":"docker","port":9003},
	    {"id":"s3","name":"gamma","engine":"localstack","port":9001},
	    {"id":"s4","name":"delta","engine":"podman","port":9004},
	    {"id":"","name":"noid","engine":"docker","port":9006},
	    {"id":"s5","name":"","engine":"docker","port":9007},
	    {"id":"s6","name":"epsilon","engine":"docker","port":70000},
	    {"id":"s7","name":"zeta","engine":"docker","port":9005}
	  ]
	}`
	m := mkManager(t)
	if err := os.WriteFile(m.storePath, []byte(file), 0o644); err != nil {
		t.Fatal(err)
	}
	m.load()
	var ids []string
	for _, s := range m.st.Services {
		ids = append(ids, s.ID)
	}
	// Only s1 (first holder of the id/name/port) and s7 survive.
	if !reflect.DeepEqual(ids, []string{"s1", "s7"}) {
		t.Errorf("survivors = %v, want [s1 s7]; errors=%v", ids, m.serviceLoadErrors)
	}
	if len(m.serviceLoadErrors) != 7 {
		t.Errorf("want 7 diagnostics, got %d: %v", len(m.serviceLoadErrors), m.serviceLoadErrors)
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func TestFindService(t *testing.T) {
	all := []ServiceConfig{{ID: "a"}, {ID: "b"}, {ID: "a"}} // duplicate id: first wins
	sc, idx := findService(all, "a")
	if sc == nil || idx != 0 {
		t.Errorf("findService(a) = %+v,%d", sc, idx)
	}
	if sc, idx := findService(all, "zz"); sc != nil || idx != -1 {
		t.Errorf("findService(zz) = %+v,%d", sc, idx)
	}
}

func TestGlobalStopSnapshotEmpty(t *testing.T) {
	if !(GlobalStopSnapshot{}).empty() {
		t.Error("zero snapshot must be empty")
	}
	if (GlobalStopSnapshot{Instances: []string{"x"}}).empty() {
		t.Error("instance snapshot reported empty")
	}
	if (GlobalStopSnapshot{Services: []string{"y"}}).empty() {
		t.Error("service snapshot reported empty")
	}
}
