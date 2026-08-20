package main

// v1.2 service monitoring tests: the sampler now covers Service runtimes
// (samplerTargets), the wire shape exposes restarts/latencyMs/ready driven by
// the per-Service probe (serviceInfoFor + probeServiceLatency), and exit
// resets the monitor baseline (serviceExited).

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// sampleServices: engine-adapter dispatch + CPU/disk delta math
// ---------------------------------------------------------------------------

func TestSampleServicesViaEngineAdapter(t *testing.T) {
	m := mkManager(t)

	// A running java Service sampling THIS process: real two-snapshot delta.
	sc := svc("aaa111", ServiceEngineJava, 9201, ServiceStorage{Mode: ServiceStorageMemory}, nil)
	plantServiceConfig(t, m, sc)
	rt, _ := m.svcRuntime(sc.ID)
	in := rt.instance()
	in.mu.Lock()
	in.status, in.pid = "running", os.Getpid()
	in.mu.Unlock()

	m.sampleServices()
	in.mu.Lock()
	mem1, prevAt := in.memBytes, in.prevSampleAt
	in.mu.Unlock()
	if mem1 == 0 || prevAt.IsZero() {
		t.Fatalf("first sample must seed memory + baseline: mem=%d prevAt=%v", mem1, prevAt)
	}

	// Burn a little CPU so the second snapshot has a non-empty delta.
	for i, acc := 0, 0; i < 2_000_000; i++ {
		acc += i
	}
	time.Sleep(20 * time.Millisecond)
	m.sampleServices()
	in.mu.Lock()
	cpu, mem2 := in.cpuPercent, in.memBytes
	baselineAdvanced := !in.prevSampleAt.Equal(prevAt)
	in.mu.Unlock()
	if mem2 == 0 {
		t.Error("second sample must keep memory")
	}
	if cpu < 0 {
		t.Errorf("cpuPercent must never go negative, got %v", cpu)
	}
	if !baselineAdvanced {
		t.Error("second sample must advance the baseline")
	}

	// gone runtime → skipped, no panic
	rt.gone = true
	m.sampleServices()
	rt.gone = false

	// stopped service → skipped, monitors untouched
	in.mu.Lock()
	in.status = "stopped"
	in.mu.Unlock()
	m.sampleServices()
	in.mu.Lock()
	if in.prevSampleAt.Equal(time.Time{}) {
		t.Error("sampling a stopped service must not reset state")
	}
	in.mu.Unlock()
}

// The java adapter's delta math in isolation: two synthetic snapshots.
func TestJavaSampleDeltaMath(t *testing.T) {
	in := &instance{status: "running", pid: os.Getpid()}
	ad := javaServiceEngine{}
	m := mkManager(t)
	sc := svc("aaa111", ServiceEngineJava, 9201, ServiceStorage{Mode: ServiceStorageMemory}, nil)

	if err := ad.sample(m, sc, in); err != nil {
		t.Fatal(err)
	}
	in.mu.Lock()
	first := in.prevSampleAt
	in.mu.Unlock()
	if first.IsZero() {
		t.Fatal("first sample must set the baseline")
	}
	if err := ad.sample(m, sc, in); err != nil {
		t.Fatal(err)
	}
	in.mu.Lock()
	negRate := in.cpuPercent < 0 || in.diskPerSec < 0
	mem := in.memBytes
	in.mu.Unlock()
	if negRate {
		t.Errorf("rates must be non-negative")
	}
	if mem == 0 {
		t.Error("memory must be sampled")
	}

	// a restarted pid invalidates the in-flight sample
	in.mu.Lock()
	in.pid = os.Getpid() + 100000
	in.mu.Unlock()
	in.memBytes = 0
	if err := ad.sample(m, sc, in); err != nil {
		t.Fatal(err)
	}
	if in.memBytes != 0 {
		t.Error("sample for a dead pid must be dropped")
	}
}

// ---------------------------------------------------------------------------
// serviceInfoFor: restarts / latencyMs / ready wire contract
// ---------------------------------------------------------------------------

func TestServiceInfoRuntimeWireFields(t *testing.T) {
	m := mkManager(t)
	sc := svc("aaa111", ServiceEngineJava, 9201, ServiceStorage{Mode: ServiceStorageMemory}, nil)
	plantServiceConfig(t, m, sc)
	rt, _ := m.svcRuntime(sc.ID)
	in := rt.instance()

	// stopped: restarts 0, latency null, ready false, healthy false
	info := m.serviceInfoFor(sc)
	if info.Runtime.State != "stopped" || info.Runtime.Ready || info.Runtime.Healthy {
		t.Errorf("stopped runtime wrong: %+v", info.Runtime)
	}
	if info.Runtime.Restarts != 0 || info.Runtime.LatencyMs != nil {
		t.Errorf("stopped runtime must have zero restarts and null latency: %+v", info.Runtime)
	}

	// running + probe OK: ready true, latency exposed, restarts pass-through
	in.mu.Lock()
	in.status, in.restarts = "running", 3
	in.ddbProbeOK, in.ddbLatencyMs = true, 12.5
	in.started, in.startMicro = time.Now(), time.Now().UnixMicro()
	in.mu.Unlock()
	info = m.serviceInfoFor(sc)
	if !info.Runtime.Ready || !info.Runtime.Healthy {
		t.Errorf("probed running service must be ready+healthy: %+v", info.Runtime)
	}
	if info.Runtime.Restarts != 3 {
		t.Errorf("restarts = %d, want 3", info.Runtime.Restarts)
	}
	if info.Runtime.LatencyMs == nil || *info.Runtime.LatencyMs != 12.5 {
		t.Errorf("latencyMs = %v, want 12.5", info.Runtime.LatencyMs)
	}

	// running + probe failing: healthy true but ready false, latency null
	in.mu.Lock()
	in.ddbProbeOK, in.ddbLatencyMs = false, 0
	in.mu.Unlock()
	info = m.serviceInfoFor(sc)
	if info.Runtime.Ready {
		t.Error("unprobed service must not be ready")
	}
	if !info.Runtime.Healthy {
		t.Error("running service stays healthy even when the probe fails")
	}
	if info.Runtime.LatencyMs != nil {
		t.Errorf("latencyMs must be null without a probe, got %v", *info.Runtime.LatencyMs)
	}

	// wire JSON carries the new fields verbatim
	b, err := json.Marshal(info.Runtime)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	if !strings.Contains(s, `"restarts":3`) || !strings.Contains(s, `"latencyMs":null`) {
		t.Errorf("wire JSON missing new fields: %s", s)
	}
}

// ---------------------------------------------------------------------------
// probeServiceLatency: real ListTables RTT against a loopback stand-in
// ---------------------------------------------------------------------------

func TestProbeServiceLatency(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/x-amz-json-1.0")
		w.Write([]byte(`{"TableNames":[]}`))
	}))
	defer ts.Close()

	u, err := url.Parse(ts.URL)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil {
		t.Fatal(err)
	}

	m := mkManager(t)
	sc := svc("aaa111", ServiceEngineJava, port, ServiceStorage{Mode: ServiceStorageMemory}, nil)
	plantServiceConfig(t, m, sc)
	rt, _ := m.svcRuntime(sc.ID)
	in := rt.instance()
	in.mu.Lock()
	in.status, in.port = "running", port
	in.startMicro = time.Now().UnixMicro()
	in.mu.Unlock()

	m.probeServiceLatency(sc, rt)
	in.mu.Lock()
	ok, lat := in.ddbProbeOK, in.ddbLatencyMs
	in.mu.Unlock()
	if !ok || lat < 0 {
		t.Fatalf("probe against live endpoint failed: ok=%v lat=%v", ok, lat)
	}

	// endpoint dies → probe flips back to not-ready
	ts.Close()
	m.probeServiceLatency(sc, rt)
	in.mu.Lock()
	ok = in.ddbProbeOK
	in.mu.Unlock()
	if ok {
		t.Error("probe must fail once the endpoint is gone")
	}

	// a stopped service is never probed
	in.mu.Lock()
	in.status = "stopped"
	in.mu.Unlock()
	m.probeServiceLatency(sc, rt) // no panic, no write
}

// ---------------------------------------------------------------------------
// serviceExited: monitor baseline reset
// ---------------------------------------------------------------------------

func TestServiceExitedZeroesMonitors(t *testing.T) {
	m := mkManager(t)
	sc := svc("aaa111", ServiceEngineJava, 9201, ServiceStorage{Mode: ServiceStorageMemory}, nil)
	plantServiceConfig(t, m, sc)
	rt, _ := m.svcRuntime(sc.ID)
	in := rt.instance()
	rt.spawnGen = 7
	in.mu.Lock()
	in.status, in.port = "running", 9201
	in.cpuPercent, in.memBytes, in.diskPerSec = 42, 1<<30, 5000
	in.prevBusy, in.prevDisk = time.Second, 12345
	in.prevSampleAt = time.Now()
	in.ddbProbeOK, in.ddbLatencyMs = true, 9.9
	in.mu.Unlock()

	m.serviceExited(sc.ID, 7, "exited", false)

	in.mu.Lock()
	defer in.mu.Unlock()
	if in.status != "stopped" {
		t.Errorf("status = %q, want stopped", in.status)
	}
	if in.cpuPercent != 0 || in.memBytes != 0 || in.diskPerSec != 0 {
		t.Error("resource sample must be zeroed on exit")
	}
	if !in.prevSampleAt.IsZero() || in.prevBusy != 0 || in.prevDisk != 0 {
		t.Error("rate baselines must be reset on exit")
	}
	if in.ddbProbeOK || in.ddbLatencyMs != 0 {
		t.Error("probe state must be cleared on exit")
	}

	// stale generation: a late callback from the old run must not touch state
	rt.spawnGen = 8
	in.status = "running"
	m.serviceExited(sc.ID, 7, "stale", true)
	if in.status != "running" {
		t.Error("stale exit callback must be dropped")
	}
}
