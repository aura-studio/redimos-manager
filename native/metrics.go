package main

// redimos /metrics scraping. Each redimos child serves a Prometheus endpoint
// (prefix redimos_) plus /healthz and /readyz. The scraper loop discovers the
// endpoint's reachable host:port, polls it every few seconds, and derives a few
// headline numbers (ops/s, average command latency, throttle count, health) that
// rm_status surfaces to the monitor panel.
//
// Metric shapes used (see cmd/redimos):
//   redimos_commands_total{command,family}            Counter  -> ops/s via rate
//   redimos_command_duration_seconds_sum{...}         Counter  -> avg latency num
//   redimos_command_duration_seconds_count{...}       Counter  -> avg latency den
//   redimos_dynamodb_throttled_total                  Counter  -> cumulative
// There is deliberately no connection-count metric to scrape.

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

var metricsHTTP = &http.Client{Timeout: 2 * time.Second}

// scraperLoop polls every running child's /metrics + health endpoints.
func (m *manager) scraperLoop() {
	t := time.NewTicker(3 * time.Second)
	for range t.C {
		m.mu.Lock()
		ins := make([]*instance, 0, len(m.running))
		for _, in := range m.running {
			ins = append(ins, in)
		}
		m.mu.Unlock()
		for _, in := range ins {
			in.mu.Lock()
			running := in.status == "running"
			addr, cont, bin := in.metricsAddr, in.container, in.bin
			logs := in.logs
			in.mu.Unlock()
			if !running {
				continue
			}
			if addr == "" {
				addr = resolveMetricsAddr(bin, cont, logs)
				if addr == "" {
					continue // endpoint not announced yet; try again next tick
				}
				in.mu.Lock()
				in.metricsAddr = addr
				in.mu.Unlock()
			}
			scrapeInstance(in, addr)
		}
	}
}

// probeDdbLoop runs on its own ticker rather than riding scraperLoop: ddbCall's
// client allows 6s, more than scraperLoop's whole 3s period, so a wedged engine
// (a paused container answers the TCP handshake and then nothing) would drop the
// scraper's ticks and stall every unrelated redimos child's health tiles behind
// a subsystem they have nothing to do with.
func (m *manager) probeDdbLoop() {
	t := time.NewTicker(3 * time.Second)
	for range t.C {
		m.probeDdbLatency()
	}
}

// probeDdbLatency measures the Local DynamoDB's request round-trip time. This is
// NOT the same quantity as a redimos child's avgLatencyMs: neither DynamoDB Local
// nor LocalStack exposes any metrics endpoint, so there is nothing to scrape and
// no server-side histogram to average. This number is the wall-clock RTT of ONE
// synthetic request issued from this process — it includes our own SigV4 signing
// and the loopback hop, and it says nothing about the traffic the proxies send.
func (m *manager) probeDdbLatency() {
	m.mu.Lock()
	in := m.ddb
	m.mu.Unlock()
	if in == nil {
		return
	}
	in.mu.Lock()
	running, port, startMicro := in.status == "running", in.port, in.startMicro
	in.mu.Unlock()
	if !running || port <= 0 {
		return
	}
	// Endpoint is CONSTRUCTED from in.port, never taken from a config: ddbCall
	// treats a blank Endpoint as real AWS, so a user-sourced endpoint here would
	// bill a real account every 3s. in.port is the LIVE child's binding — the
	// configured port can point at nothing, since rm_ddb_set persists a new port
	// while the child keeps its old one until restarted.
	cfg := &Config{Endpoint: fmt.Sprintf("http://127.0.0.1:%d", port)}
	// ListTables{Limit:1} is the cheapest call both engines are proven to answer
	// (it is what the endpoint Browser and the playground host already use).
	start := time.Now()
	_, err := ddbCall(cfg, "ListTables", map[string]any{"Limit": float64(1)})
	ms := float64(time.Since(start).Microseconds()) / 1000
	in.mu.Lock()
	defer in.mu.Unlock()
	// The child may have restarted during the unlocked I/O; a sample timed against
	// the previous process would be attributed to the new one, silently undoing
	// spawn()'s reset. Compare startMicro, not port: autoRestart re-spawns in
	// place on this same instance and never changes port, so a port check would
	// pass for exactly the restart it is meant to catch.
	if in.status != "running" || in.startMicro != startMicro {
		return
	}
	if err != nil {
		in.ddbProbeOK = false
		return
	}
	in.ddbProbeOK, in.ddbLatencyMs = true, ms
}

// resolveMetricsAddr finds the host:port the manager can reach the child's
// metrics listener on. Docker maps the container's :9121 to a random host port
// (read via `docker port`); a native child prints its bound address in the
// startup log line "... metrics=<bind> ...".
func resolveMetricsAddr(bin, container string, logs []string) string {
	if container != "" {
		portCmd := exec.Command(bin, "port", container, "9121")
		hideWindow(portCmd)
		out, err := portCmd.Output()
		if err != nil {
			return ""
		}
		// Lines look like "0.0.0.0:57406" or "[::]:57406"; take the first usable.
		for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			if a := hostFromBind(strings.TrimSpace(line)); a != "" {
				return a
			}
		}
		return ""
	}
	// Native: scan logs (newest first) for the startup line's metrics= token.
	for i := len(logs) - 1; i >= 0; i-- {
		idx := strings.Index(logs[i], "metrics=")
		if idx < 0 {
			continue
		}
		tok := logs[i][idx+len("metrics="):]
		if sp := strings.IndexAny(tok, " \t"); sp >= 0 {
			tok = tok[:sp]
		}
		if a := hostFromBind(strings.TrimSpace(tok)); a != "" {
			return a
		}
	}
	return ""
}

// hostFromBind turns a listener bind address into a loopback-reachable
// host:port. Wildcard hosts ([::], 0.0.0.0, empty) become 127.0.0.1.
func hostFromBind(bind string) string {
	if bind == "" {
		return ""
	}
	host, port, err := net.SplitHostPort(bind)
	if err != nil || port == "" || port == "0" {
		return ""
	}
	if host == "" || host == "::" || host == "0.0.0.0" || host == "[::]" {
		host = "127.0.0.1"
	}
	return net.JoinHostPort(host, port)
}

func scrapeInstance(in *instance, addr string) {
	base := "http://" + addr
	// Identify the incarnation this sample belongs to BEFORE the unlocked I/O
	// below, so the write-back can recognise a sample that outlived its process.
	in.mu.Lock()
	startMicro := in.startMicro
	in.mu.Unlock()

	healthy, _ := probe(base + "/healthz")
	ready, readyBody := probe(base + "/readyz")
	// redimos's own reported cause for the failing backend check. Read here but
	// attributed under the lock below with everything else in this sample.
	backendErr := readyzBackendError(readyBody)

	body, ok := fetch(base + "/metrics")
	now := time.Now()
	in.mu.Lock()
	defer in.mu.Unlock()
	// This sample spent up to ~6s in unlocked I/O, over which the child can have
	// exited and been re-spawned in place: autoRestart reuses this same instance and
	// keeps its port, so only the process identity moves. Attributing the sample to
	// the new incarnation would silently undo spawn()'s reset — and for backendError
	// that means a dead generation's cause reappearing beneath a live proxy's amber
	// dot, a wrong reason being worse than the generic wording it replaces. Compare
	// startMicro, mirroring probeDdbLatency; addr is compared too because a docker
	// child's startMicro can be 0 (unknown, so it cannot differ across a restart),
	// while spawn always clears metricsAddr for the rediscovery a new run requires.
	if in.status != "running" || in.startMicro != startMicro || in.metricsAddr != addr {
		return
	}
	in.mtxHealthy, in.mtxReady, in.backendError = healthy, ready, backendErr
	if !ok {
		in.mtxOK = false
		return
	}
	in.mtxOK = true
	cmdTotal := sumPromMetric(body, "redimos_commands_total")
	durSum := sumPromMetric(body, "redimos_command_duration_seconds_sum")
	durCount := sumPromMetric(body, "redimos_command_duration_seconds_count")
	in.throttled = int64(sumPromMetric(body, "redimos_dynamodb_throttled_total"))

	if !in.prevMtxAt.IsZero() {
		if wall := now.Sub(in.prevMtxAt).Seconds(); wall > 0 && cmdTotal >= in.prevCmdTotal {
			in.opsPerSec = (cmdTotal - in.prevCmdTotal) / wall
		}
		if dc := durCount - in.prevDurCount; dc > 0 && durSum >= in.prevDurSum {
			in.avgLatencyMs = (durSum - in.prevDurSum) / dc * 1000
		}
	}
	in.prevCmdTotal, in.prevDurSum, in.prevDurCount, in.prevMtxAt = cmdTotal, durSum, durCount, now
}

// probe issues one GET against a health endpoint, reporting whether it answered
// 200 and returning the body it answered with. The body is read on EVERY status,
// not just 200: /readyz answers 503 in exactly the situation worth explaining (the
// backend check is failing) and carries the cause in that 503's body, so a
// 200-only read would discard the reason precisely when it exists.
func probe(url string) (bool, string) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, ""
	}
	resp, err := metricsHTTP.Do(req)
	if err != nil {
		return false, ""
	}
	defer resp.Body.Close()
	// Bounded read: the body is a small fixed JSON object, but it arrives over a
	// socket, so cap it rather than trust the responder to be the redimos we think
	// it is. A read error yields a short/empty body, which parses to no cause —
	// the same graceful degradation as an older redimos.
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	return resp.StatusCode == http.StatusOK, string(b)
}

// maxBackendErrLen bounds the cause string threaded to the UI. Real AWS error
// strings run ~150 chars; this is a guard against an unbounded string crossing the
// FFI boundary into a tooltip, not a display preference.
const maxBackendErrLen = 300

// readyzBackendError extracts redimos's own reported cause for a failing backend
// check from a /readyz body:
//
//	{"ready":false,"backend_healthy":false,"backend_error":"…", …}
//
// It returns "" when the body is not that shape — an older redimos with no such
// field, a body that never arrived, or some other responder on the port — so the
// caller falls back to the generic wording instead of showing something invented.
// A ready proxy reports backend_error:"" itself, so the empty result also covers
// the healthy case without a special path.
//
// Tolerant of an unparseable body on purpose: redimos writes this JSON with
// fmt.Fprintf and %q, not encoding/json, and %q emits escapes JSON does not accept
// (\x…, \a, \v) for an error string carrying such a byte. That costs the cause
// string, which is an extra — it must never cost the health signal that came with
// it, so parsing is kept off the mtxHealthy/mtxReady path entirely.
func readyzBackendError(body string) string {
	var v struct {
		BackendError string `json:"backend_error"`
	}
	if err := json.Unmarshal([]byte(body), &v); err != nil {
		return ""
	}
	msg := strings.TrimSpace(v.BackendError)
	if len(msg) > maxBackendErrLen {
		return truncateUTF8(msg, maxBackendErrLen) + "…"
	}
	return msg
}

func fetch(url string) (string, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", false
	}
	resp, err := metricsHTTP.Do(req)
	if err != nil {
		return "", false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", false
	}
	var sb strings.Builder
	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		sb.WriteString(sc.Text())
		sb.WriteByte('\n')
	}
	return sb.String(), true
}

// sumPromMetric sums the value of every sample whose metric name (the token
// before any '{' label set) exactly equals name, skipping # HELP/# TYPE lines.
func sumPromMetric(text, name string) float64 {
	var total float64
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || line[0] == '#' {
			continue
		}
		// Split "<name>[{labels}] <value>" — the metric name is up to the first
		// '{' or whitespace.
		metric := line
		if b := strings.IndexByte(line, '{'); b >= 0 {
			metric = line[:b]
		} else if s := strings.IndexAny(line, " \t"); s >= 0 {
			metric = line[:s]
		}
		if metric != name {
			continue
		}
		// Value is the last whitespace-separated field.
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		if v, err := strconv.ParseFloat(fields[len(fields)-1], 64); err == nil {
			total += v
		}
	}
	return total
}
