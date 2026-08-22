package main

// Stage 9 tests: the Service C ABI contract — symbol consistency against the
// header, request decode, success/error envelopes, error-code mapping, unknown
// IDs, invalid transitions, delete result fields, recovery errors in the list,
// and the legacy singleton stubs' zero side effects (9.4).

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
)

// abiSetup is the deleteSetup equivalent: sandboxed manager + fake engines.
func abiSetup(t *testing.T) *manager {
	t.Helper()
	m, _ := deleteSetup(t)
	return m
}

// jsonGet walks a decoded envelope for a top-level value.
func envHas(t *testing.T, env map[string]any, key string) bool {
	t.Helper()
	_, ok := env[key]
	return ok
}

// countErrorLines must bucket exactly like logs_page.dart's parseLogLevel:
// the FIRST word-bounded severity token decides; error/err/fatal count, and
// lines whose first token is another level (or none) never count — even when
// they mention "error" later on.
func TestCountErrorLines(t *testing.T) {
	logs := []string{
		"08:00:01 ERROR boom",            // error token first → counts
		"err: connection reset",          // err → counts
		"FATAL out of memory",            // fatal → counts
		"08:00:02 INFO all good",         // info first → no
		"08:00:03 WARN slow",             // warn first → no
		"INFO recovered after error",     // first token info → no
		"plain line without severity",    // no token → no
		"ERRORS are not a bounded token", // no word boundary → no
		"",                               // empty → no
	}
	if got := countErrorLines(logs); got != 3 {
		t.Fatalf("countErrorLines = %d, want 3", got)
	}
	if got := countErrorLines(nil); got != 0 {
		t.Fatalf("countErrorLines(nil) = %d, want 0", got)
	}
}

// ---------------------------------------------------------------------------
// Error-code taxonomy
// ---------------------------------------------------------------------------

func TestSvcErrorCodeTaxonomy(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		// Sentinel wrapping (errors.Is path).
		{errServiceNotFound, "service_not_found"},
		{errServiceGone, "service_not_found"},
		{fmt.Errorf("wrap: %w", errInvalidTransition), "invalid_transition"},
		{fmt.Errorf("wrap: %w", errPortConflict), "port_conflict"},
		{fmt.Errorf("wrap: %w", errReadinessTimeout), "readiness_timeout"},
		{fmt.Errorf("wrap: %w", errPersistFailed), "persist_failed"},
		{fmt.Errorf("wrap: %w", errUnsafeDataPath), "unsafe_data_path"},
		{fmt.Errorf("wrap: %w", errUnownedVolume), "unowned_volume"},
		{fmt.Errorf("wrap: %w", errPartialDelete), "partial_delete"},
		{fmt.Errorf("wrap: %w", errResourceUnowned), "resource_unowned"},
		// Message fallbacks (runtime exit messages survive only as strings).
		{errors.New(`name "x" is already in use by Service abc`), "duplicate_name"},
		{errors.New("port 8000 is already configured by Service abc"), "port_conflict"},
		{errors.New("port 8000 is already in use"), "port_conflict"},
		{errors.New("invalid transition: service s is running"), "invalid_transition"},
		{errors.New("readiness timeout after 30s"), "readiness_timeout"},
		{errors.New("java not available (install a JRE)"), "engine_unavailable"},
		{errors.New("docker not available"), "engine_unavailable"},
		{errors.New("service abc not found"), "service_not_found"},
		{errors.New("service is being deleted"), "service_not_found"},
		{errors.New("totally unexpected"), "invalid_request"},
		{nil, ""},
	}
	for _, tc := range cases {
		if got := svcErrorCode(tc.err); got != tc.want {
			t.Errorf("svcErrorCode(%v) = %q, want %q", tc.err, got, tc.want)
		}
	}
}

// ---------------------------------------------------------------------------
// List envelope + recovery errors
// ---------------------------------------------------------------------------

func TestAbiServicesEnvelope(t *testing.T) {
	m := abiSetup(t)
	plantServiceConfig(t, m, svc("b-second", ServiceEngineJava, freePort(t), ServiceStorage{}, nil))
	plantServiceConfig(t, m, svc("a-first", ServiceEngineJava, freePort(t), ServiceStorage{}, nil))

	env := m.abiServices()
	if env["ok"] != true {
		t.Fatalf("list must succeed: %+v", env)
	}
	list, ok := env["services"].([]serviceInfo)
	if !ok || len(list) != 2 {
		t.Fatalf("want 2 services, got %+v", env["services"])
	}
	if list[0].Config.Name != "svc-a-first" || list[1].Config.Name != "svc-b-second" {
		t.Errorf("list order must be the stable display order: %+v", list)
	}
	if list[0].Runtime.State != "stopped" {
		t.Errorf("a Service that never started reports stopped, got %q", list[0].Runtime.State)
	}
	errs, ok := env["errors"].([]string)
	if !ok || len(errs) != 0 {
		t.Errorf("errors must be a present, empty array, got %#v", env["errors"])
	}

	// Recovery failures land in errors[] (7.6).
	m.recordRecoveryError("broken", errors.New("engine blew up"))
	env = m.abiServices()
	errs = env["errors"].([]string)
	if len(errs) != 1 || !strings.Contains(errs[0], "broken") {
		t.Errorf("recovery errors must surface: %+v", errs)
	}

	// The legacy migration notice rides along as a warning when set.
	m.mu.Lock()
	m.legacyDdbMigrationNotice = "legacy backend stopped"
	m.mu.Unlock()
	env = m.abiServices()
	warns, _ := env["warnings"].([]string)
	if len(warns) != 1 || warns[0] != "legacy backend stopped" {
		t.Errorf("migration notice must surface as a warning: %#v", env["warnings"])
	}
}

// ---------------------------------------------------------------------------
// Save: create / update / rejections
// ---------------------------------------------------------------------------

func TestAbiServiceSaveCreateUpdate(t *testing.T) {
	m := abiSetup(t)

	// Create: empty id → new Service with a generated ID.
	env := m.abiServiceSave(`{"service":{"name":"ddb-a","engine":"docker","port":0}}`)
	if env["ok"] != true {
		t.Fatalf("create must succeed: %+v", env)
	}
	id, _ := env["id"].(string)
	if id == "" {
		t.Fatal("create must return the generated id")
	}
	info, _ := env["service"].(serviceInfo)
	if info.Config.ID != id || info.Config.Name != "ddb-a" || info.Runtime.State != "stopped" {
		t.Errorf("create envelope must carry the saved service: %+v", env)
	}

	// Duplicate name → duplicate_name.
	env = m.abiServiceSave(`{"service":{"name":"ddb-a","engine":"docker"}}`)
	if env["ok"] != false || env["code"] != "duplicate_name" {
		t.Errorf("duplicate name must map to duplicate_name: %+v", env)
	}

	// Update: same id, new display name.
	env = m.abiServiceSave(`{"service":{"id":"` + id + `","name":"ddb-b","engine":"docker"}}`)
	if env["ok"] != true {
		t.Fatalf("update must succeed: %+v", env)
	}
	info, _ = env["service"].(serviceInfo)
	if info.Config.Name != "ddb-b" || info.Config.ID != id {
		t.Errorf("update envelope must carry the renamed service: %+v", env)
	}

	// Unknown id → service_not_found.
	env = m.abiServiceSave(`{"service":{"id":"nope","name":"x","engine":"docker"}}`)
	if env["ok"] != false || env["code"] != "service_not_found" || env["id"] != "nope" {
		t.Errorf("unknown id must map to service_not_found with the id: %+v", env)
	}

	// Invalid config (empty name) → invalid_request.
	env = m.abiServiceSave(`{"service":{"engine":"docker"}}`)
	if env["ok"] != false || env["code"] != "invalid_request" {
		t.Errorf("invalid config must map to invalid_request: %+v", env)
	}

	// Malformed JSON → invalid_request, nothing created.
	before := len(m.serviceInfos())
	env = m.abiServiceSave(`{"service":`)
	if env["ok"] != false || env["code"] != "invalid_request" {
		t.Errorf("malformed request must map to invalid_request: %+v", env)
	}
	if len(m.serviceInfos()) != before {
		t.Error("a malformed request must have zero side effects")
	}
}

// ---------------------------------------------------------------------------
// Lifecycle envelopes + transitions
// ---------------------------------------------------------------------------

func TestAbiServiceLifecycleTransitions(t *testing.T) {
	m := abiSetup(t)
	sc, err := m.createServiceConfig(ServiceConfig{
		Name: "lifecycle", Engine: ServiceEngineDockerDDB, Port: freePort(t),
	})
	if err != nil {
		t.Fatal(err)
	}
	idJSON := `{"id":"` + sc.ID + `"}`

	// start → ok + running snapshot.
	env := m.abiServiceStart(idJSON)
	if env["ok"] != true {
		t.Fatalf("start must succeed: %+v", env)
	}
	info, _ := env["service"].(serviceInfo)
	if info.Runtime.State != "running" || !info.Runtime.Healthy {
		t.Errorf("post-start envelope must show running/healthy: %+v", info.Runtime)
	}
	// Ready is proven by the ListTables probe, not by the lifecycle state: a
	// freshly started Service is healthy but not yet ready.
	if info.Runtime.Ready {
		t.Errorf("ready must stay false until a probe proves it: %+v", info.Runtime)
	}
	rt, _ := m.svcRuntime(sc.ID)
	in := rt.instance()
	in.mu.Lock()
	in.ddbProbeOK = true
	in.mu.Unlock()
	if got := m.serviceInfoFor(sc); !got.Runtime.Ready {
		t.Errorf("ready must flip once the probe proves the service: %+v", got.Runtime)
	}

	// start while running → invalid_transition.
	env = m.abiServiceStart(idJSON)
	if env["ok"] != false || env["code"] != "invalid_transition" {
		t.Errorf("start-while-running must map to invalid_transition: %+v", env)
	}

	// stop → ok, desired state persisted false.
	env = m.abiServiceStop(idJSON)
	if env["ok"] != true {
		t.Fatalf("stop must succeed: %+v", env)
	}
	if desiredOf(t, m, sc.ID) {
		t.Error("explicit stop must persist desiredRunning=false")
	}
	waitSvcSettled(t, m, sc.ID)

	// stop again → invalid_transition.
	env = m.abiServiceStop(idJSON)
	if env["ok"] != false || env["code"] != "invalid_transition" {
		t.Errorf("stop-while-stopped must map to invalid_transition: %+v", env)
	}

	// restart from stopped → ok (stop half is a tolerated no-op).
	env = m.abiServiceRestart(idJSON)
	if env["ok"] != true {
		t.Fatalf("restart must succeed from stopped: %+v", env)
	}
	info, _ = env["service"].(serviceInfo)
	if info.Runtime.State != "running" {
		t.Errorf("post-restart envelope must show running: %+v", info.Runtime)
	}

	// Unknown / missing / malformed IDs.
	env = m.abiServiceStart(`{"id":"ghost"}`)
	if env["ok"] != false || env["code"] != "service_not_found" {
		t.Errorf("unknown id must map to service_not_found: %+v", env)
	}
	env = m.abiServiceStop(`{}`)
	if env["ok"] != false || env["code"] != "invalid_request" {
		t.Errorf("missing id must map to invalid_request: %+v", env)
	}
	env = m.abiServiceRestart(`not json`)
	if env["ok"] != false || env["code"] != "invalid_request" {
		t.Errorf("malformed request must map to invalid_request: %+v", env)
	}

	// Settle + teardown sync edge.
	if err := m.stopService(sc.ID, true); err != nil && !errors.Is(err, errInvalidTransition) {
		t.Fatal(err)
	}
	waitSvcSettled(t, m, sc.ID)
	m.svcEnsureRuntime(sc.ID).instance().superviseWG.Wait()
}

// ---------------------------------------------------------------------------
// Logs envelope
// ---------------------------------------------------------------------------

func TestAbiServiceLogs(t *testing.T) {
	m := abiSetup(t)
	sc, err := m.createServiceConfig(ServiceConfig{
		Name: "logger", Engine: ServiceEngineDockerDDB, Port: freePort(t),
	})
	if err != nil {
		t.Fatal(err)
	}

	// Never started: ok with an empty (present) lines array.
	env := m.abiServiceLogs(`{"id":"` + sc.ID + `"}`)
	if env["ok"] != true {
		t.Fatalf("logs must succeed for a never-started Service: %+v", env)
	}
	lines, ok := env["lines"].([]string)
	if !ok || lines == nil {
		t.Errorf("lines must be a present array: %#v", env["lines"])
	}

	// Unknown id / missing id / malformed.
	env = m.abiServiceLogs(`{"id":"ghost"}`)
	if env["ok"] != false || env["code"] != "service_not_found" {
		t.Errorf("unknown id must map to service_not_found: %+v", env)
	}
	env = m.abiServiceLogs(`{}`)
	if env["ok"] != false || env["code"] != "invalid_request" {
		t.Errorf("missing id must map to invalid_request: %+v", env)
	}
	env = m.abiServiceLogs(`###`)
	if env["ok"] != false || env["code"] != "invalid_request" {
		t.Errorf("malformed request must map to invalid_request: %+v", env)
	}
}

// ---------------------------------------------------------------------------
// Delete envelope (including partial)
// ---------------------------------------------------------------------------

func TestAbiServiceDeleteEnvelope(t *testing.T) {
	m := abiSetup(t)
	sc, data := plantManagedJava(t, m, "abi-del")

	// Default: preserve data, report nothing cleaned.
	env := m.abiServiceDelete(`{"id":"` + sc.ID + `"}`)
	if env["ok"] != true || env["dataCleaned"] != false || env["partial"] != false {
		t.Fatalf("default delete envelope wrong: %+v", env)
	}
	if _, ok := env["manualCleanup"].([]string); !ok {
		t.Errorf("manualCleanup must be a present array: %#v", env["manualCleanup"])
	}
	if !envHas(t, env, "id") || env["id"] != sc.ID {
		t.Errorf("delete envelope must carry the affected id: %+v", env)
	}

	// Explicit cleanup on a fresh managed Service: data goes, reported true.
	sc2, _ := plantManagedJava(t, m, "abi-clean")
	env = m.abiServiceDelete(`{"id":"` + sc2.ID + `","deleteData":true}`)
	if env["ok"] != true || env["dataCleaned"] != true {
		t.Fatalf("managed cleanup envelope wrong: %+v", env)
	}
	if _, err := os.Stat(data); err != nil {
		t.Error("the first Service's data must be untouched by the second's cleanup")
	}

	// Unknown / missing id.
	env = m.abiServiceDelete(`{"id":"ghost"}`)
	if env["ok"] != false || env["code"] != "service_not_found" {
		t.Errorf("unknown id must map to service_not_found: %+v", env)
	}
	env = m.abiServiceDelete(`{"deleteData":true}`)
	if env["ok"] != false || env["code"] != "invalid_request" {
		t.Errorf("missing id must map to invalid_request: %+v", env)
	}

	// Partial deletion: data cleaned, persist failed — the failure envelope
	// still reports exactly what landed.
	sc3, data3 := plantManagedJava(t, m, "abi-partial")
	breakPersist(t, m)
	env = m.abiServiceDelete(`{"id":"` + sc3.ID + `","deleteData":true}`)
	if env["ok"] != false || env["code"] != "partial_delete" {
		t.Fatalf("persist failure after cleanup must map to partial_delete: %+v", env)
	}
	if env["partial"] != true || env["dataCleaned"] != true {
		t.Errorf("partial envelope must report the cleaned data: %+v", env)
	}
	if _, err := os.Stat(data3); !os.IsNotExist(err) {
		t.Error("the data really was cleaned — the filesystem must agree")
	}
}

// ---------------------------------------------------------------------------
// Legacy singleton stubs: fixed envelope, zero side effects (11.4, 11.5)
// ---------------------------------------------------------------------------

func TestLegacyDdbStubsZeroSideEffects(t *testing.T) {
	m := abiSetup(t)
	m.mu.Lock()
	m.st.LocalDdb = LocalDdbConfig{Engine: "java", Port: 8123}
	m.mu.Unlock()

	env := legacyUnsupported()
	if env["ok"] != false || env["code"] != "legacy_api_unsupported" {
		t.Fatalf("legacy envelope wrong: %+v", env)
	}
	if msg, _ := env["error"].(string); !strings.Contains(msg, "Service APIs") {
		t.Errorf("legacy error must point at the Service APIs: %+v", env)
	}

	// Nothing about the store or the singleton child may change shape because
	// of the stubbed surface (the exports are one-line shells around this map).
	m.mu.Lock()
	ddb := m.st.LocalDdb
	child := m.ddb
	m.mu.Unlock()
	if ddb.Engine != "java" || ddb.Port != 8123 {
		t.Errorf("stubbed legacy surface must not touch the store: %+v", ddb)
	}
	if child != nil {
		t.Error("stubbed legacy surface must not create the singleton child")
	}
}

// ---------------------------------------------------------------------------
// Symbol consistency: every //export in service_abi.go has a header extern,
// and the legacy symbols keep theirs (the Dart side still resolves them).
// ---------------------------------------------------------------------------

func TestServiceAbiSymbolConsistency(t *testing.T) {
	abiSrc, err := os.ReadFile("service_abi.go")
	if err != nil {
		t.Fatal(err)
	}
	legacySrc, err := os.ReadFile("localddb.go")
	if err != nil {
		t.Fatal(err)
	}
	header, err := os.ReadFile("redimos_core.h")
	if err != nil {
		t.Fatal(err)
	}
	h := string(header)

	wantNew := []string{
		"rm_services", "rm_service_save", "rm_service_delete",
		"rm_service_start", "rm_service_stop", "rm_service_restart", "rm_service_logs",
	}
	for _, sym := range wantNew {
		if !strings.Contains(string(abiSrc), "//export "+sym) {
			t.Errorf("service_abi.go must export %s", sym)
		}
		if !strings.Contains(h, "extern char* "+sym+"(") {
			t.Errorf("redimos_core.h must declare %s", sym)
		}
	}
	// Legacy symbols stay linked (the old Dart bindings still look them up
	// until stage 15 removes them).
	for _, sym := range []string{"rm_ddb_get", "rm_ddb_set", "rm_ddb_start", "rm_ddb_stop", "rm_ddb_logs", "rm_shutdown"} {
		if !strings.Contains(string(legacySrc), "//export "+sym) {
			t.Errorf("localddb.go must keep exporting %s until stage 15", sym)
		}
		if !strings.Contains(h, "extern char* "+sym+"(") {
			t.Errorf("redimos_core.h must keep declaring %s until stage 15", sym)
		}
	}
}
