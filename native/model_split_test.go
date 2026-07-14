package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestEndpointKind(t *testing.T) {
	cases := map[string]string{
		"":                                       "aws",
		"   ":                                     "aws",
		"http://localhost:8079":                   "local",
		"http://127.0.0.1:8000":                   "local",
		"http://[::1]:8000":                       "local",
		"https://dynamodb.us-east-1.amazonaws.com": "url",
		"http://10.0.0.5:8000":                    "url",
	}
	for in, want := range cases {
		if got := endpointKind(in); got != want {
			t.Errorf("endpointKind(%q)=%q want %q", in, got, want)
		}
	}
}

func sampleConfigs() []Config {
	return []Config{
		// aws (empty endpoint), region us-east-1
		{ID: "a", Name: "prod-v1", Version: "v1", Port: 6379, Table: "t1",
			Region: "us-east-1", AccessKeyID: "AK", SecretKey: "SK",
			AutoRestart: true, RunMode: "native"},
		// SAME aws backend (dedups with the first), different instance/table
		{ID: "b", Name: "prod-v2", Version: "v2", Port: 6380, Table: "t2",
			Region: "us-east-1", AccessKeyID: "AK", SecretKey: "SK",
			MultiDB: true},
		// local endpoint
		{ID: "c", Name: "local", Version: "v1", Port: 6381, Table: "t3",
			Endpoint: "http://localhost:8079", PartitionID: "aws",
			ExtraFlags: []FlagKV{{Key: "metrics-addr", Value: ":0"}}},
		// custom url endpoint
		{ID: "d", Name: "staging", Version: "v2", Port: 6382, Table: "t4",
			Endpoint: "http://dynamo.staging.internal:8000", Region: "us-west-2"},
	}
}

func TestSplitMergeRoundTrip(t *testing.T) {
	orig := sampleConfigs()
	eps, insts := splitConfigs(orig)
	got := mergeToConfigs(eps, insts)
	if !reflect.DeepEqual(orig, got) {
		t.Fatalf("round trip changed configs:\n orig=%+v\n got =%+v", orig, got)
	}
	if len(insts) != 4 {
		t.Errorf("want 4 instances, got %d", len(insts))
	}
	// a & b share the same aws backend => 3 distinct endpoints, not 4.
	if len(eps) != 3 {
		t.Errorf("want 3 deduped endpoints, got %d: %+v", len(eps), eps)
	}
	// every instance references an existing endpoint
	ids := map[string]bool{}
	for _, e := range eps {
		ids[e.ID] = true
	}
	for _, in := range insts {
		if !ids[in.EndpointID] {
			t.Errorf("instance %s references missing endpoint %s", in.ID, in.EndpointID)
		}
	}
}

func TestEndpointKindsAndNamesUnique(t *testing.T) {
	eps, _ := splitConfigs(sampleConfigs())
	kinds := map[string]int{}
	names := map[string]bool{}
	for _, e := range eps {
		kinds[e.Kind]++
		if names[e.Name] {
			t.Errorf("duplicate endpoint name %q", e.Name)
		}
		names[e.Name] = true
	}
	if kinds["aws"] != 1 || kinds["local"] != 1 || kinds["url"] != 1 {
		t.Errorf("unexpected kind histogram: %+v", kinds)
	}
}

func TestEndpointIDStableAcrossSplits(t *testing.T) {
	// The same backend tuple must hash to the same endpoint id on every split,
	// so instance.endpointId stays valid across saves.
	e1, _ := splitConfigs(sampleConfigs())
	e2, _ := splitConfigs(sampleConfigs())
	if !reflect.DeepEqual(e1, e2) {
		t.Errorf("endpoint ids not stable across splits")
	}
}

// mkManager builds a bare manager just for load/persist (they only touch
// storePath and st).
func mkManager(t *testing.T) *manager {
	t.Helper()
	dir := t.TempDir()
	return &manager{storePath: filepath.Join(dir, "store.json")}
}

func TestLegacyMigration(t *testing.T) {
	// A pre-1.2 store.json with the old configs[] shape.
	legacy := `{
	  "configs": [
	    {"id":"a","name":"prod-v1","version":"v1","port":6379,"table":"t1","region":"us-east-1","accessKeyId":"AK","secretKey":"SK","autoRestart":true,"runMode":"native"},
	    {"id":"c","name":"local","version":"v1","port":6381,"table":"t3","endpoint":"http://localhost:8079","partitionID":"aws"}
	  ],
	  "settings": {"redimosV1Path":"/bin/v1"},
	  "autoStart": ["a"],
	  "ddbAutoStart": true
	}`
	m := mkManager(t)
	if err := os.WriteFile(m.storePath, []byte(legacy), 0o644); err != nil {
		t.Fatal(err)
	}
	m.load()

	if len(m.st.Configs) != 2 {
		t.Fatalf("legacy load: want 2 configs, got %d", len(m.st.Configs))
	}
	if m.st.Configs[0].Region != "us-east-1" || m.st.Configs[1].Endpoint != "http://localhost:8079" {
		t.Errorf("legacy load lost backend fields: %+v", m.st.Configs)
	}
	if m.st.Settings.RedimosV1Path != "/bin/v1" || !m.st.DdbAutoStart || len(m.st.AutoStart) != 1 {
		t.Errorf("legacy load lost settings/autostart: %+v %+v", m.st.Settings, m.st.AutoStart)
	}

	// Persist rewrites in the split shape.
	if err := m.persist(); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(m.storePath)
	var disk map[string]json.RawMessage
	if err := json.Unmarshal(raw, &disk); err != nil {
		t.Fatal(err)
	}
	if _, ok := disk["endpoints"]; !ok {
		t.Errorf("persisted file has no endpoints[]: %s", raw)
	}
	if _, ok := disk["instances"]; !ok {
		t.Errorf("persisted file has no instances[]: %s", raw)
	}
	// configs[] is kept as a downgrade mirror (load still prefers the split form).
	if _, ok := disk["configs"]; !ok {
		t.Errorf("persisted file is missing the legacy configs[] mirror: %s", raw)
	}

	// Reload the new-shape file → same configs.
	m2 := &manager{storePath: m.storePath}
	m2.load()
	if !reflect.DeepEqual(m.st.Configs, m2.st.Configs) {
		t.Errorf("reload mismatch:\n before=%+v\n after =%+v", m.st.Configs, m2.st.Configs)
	}
	if strings.TrimSpace(string(raw)) == "" {
		t.Error("empty persisted file")
	}
}
