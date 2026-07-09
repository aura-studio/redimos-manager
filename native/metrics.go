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

// resolveMetricsAddr finds the host:port the manager can reach the child's
// metrics listener on. Docker maps the container's :9121 to a random host port
// (read via `docker port`); a native child prints its bound address in the
// startup log line "... metrics=<bind> ...".
func resolveMetricsAddr(bin, container string, logs []string) string {
	if container != "" {
		out, err := exec.Command(bin, "port", container, "9121").Output()
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
	healthy := probe(base + "/healthz")
	ready := probe(base + "/readyz")

	body, ok := fetch(base + "/metrics")
	now := time.Now()
	in.mu.Lock()
	defer in.mu.Unlock()
	in.mtxHealthy, in.mtxReady = healthy, ready
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

func probe(url string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false
	}
	resp, err := metricsHTTP.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
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
