package main

// Destructive DynamoDB table lifecycle: recreate (delete + rebuild), gated so it
// can only ever touch an explicit endpoint (Local / LocalStack / custom). In AWS
// mode (no endpoint) the operation is refused here as a defense-in-depth backstop
// behind the UI, which doesn't render the button at all — the manager cannot tell
// a test AWS account from a production one, so table lifecycle on real AWS is
// simply not offered. (A delete-without-recreate action was intentionally dropped:
// for an AutoCreate config it wasn't durable anyway, and it left clients stranded.)

import (
	"fmt"
	"net/url"
	"strings"
	"time"
)

// normEndpoint reduces an endpoint URL to scheme://host:port with loopback host
// aliases collapsed, so two configs that point at the same local DynamoDB (via
// localhost vs 127.0.0.1 vs host.docker.internal) compare equal.
func normEndpoint(ep string) string {
	ep = strings.TrimSpace(ep)
	if ep == "" {
		return ""
	}
	u, err := url.Parse(ep)
	if err != nil || u.Host == "" {
		return strings.ToLower(ep)
	}
	host := strings.ToLower(u.Hostname())
	if isLoopbackHost(host) {
		host = "localhost"
	}
	port := u.Port()
	if port != "" {
		host += ":" + port
	}
	return strings.ToLower(u.Scheme) + "://" + host
}

func isLoopbackHost(host string) bool {
	host = strings.ToLower(strings.TrimSpace(host))
	switch host {
	case "localhost", "127.0.0.1", "::1", "0.0.0.0", "host.docker.internal":
		return true
	}
	return strings.HasPrefix(host, "127.")
}

// endpointIsLoopback reports whether an endpoint targets the local machine.
func endpointIsLoopback(ep string) bool {
	u, err := url.Parse(strings.TrimSpace(ep))
	if err != nil {
		return false
	}
	return isLoopbackHost(u.Hostname())
}

// tableDependents returns every saved config that targets the SAME table on the
// SAME (normalised) endpoint as cfg — including cfg itself. Caller holds m.mu.
func (m *manager) tableDependents(cfg *Config) []*Config {
	key := normEndpoint(cfg.Endpoint) + "\x00" + cfg.Table
	var out []*Config
	for i := range m.st.Configs {
		c := &m.st.Configs[i]
		if normEndpoint(c.Endpoint)+"\x00"+c.Table == key {
			out = append(out, c)
		}
	}
	return out
}

func (m *manager) isActive(id string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	in, ok := m.running[id]
	if !ok {
		return false
	}
	in.mu.Lock()
	defer in.mu.Unlock()
	return in.status == "running" || in.status == "restarting" || in.status == "preparing"
}

// deleteTableAndWait issues DeleteTable and polls until the table is gone (or a
// short timeout). Loopback DynamoDB deletes near-instantly; the poll mainly
// smooths over eventual consistency. Assumes cfg.Endpoint is non-empty.
func deleteTableAndWait(cfg *Config) error {
	if _, err := ddbCall(cfg, "DeleteTable", map[string]any{"TableName": cfg.Table}); err != nil {
		// A missing table is a success for our purposes (idempotent reset).
		if strings.Contains(err.Error(), "ResourceNotFound") {
			return nil
		}
		return err
	}
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		_, err := ddbCall(cfg, "DescribeTable", map[string]any{"TableName": cfg.Table})
		if err != nil { // DescribeTable on a missing table errors → gone
			return nil
		}
		time.Sleep(300 * time.Millisecond)
	}
	return nil // best-effort; the table was accepted for deletion
}

// waitTableActive polls DescribeTable until the table exists and is ACTIVE.
func waitTableActive(cfg *Config, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		desc, err := ddbCall(cfg, "DescribeTable", map[string]any{"TableName": cfg.Table})
		if err == nil {
			if tbl, ok := desc["Table"].(map[string]any); ok {
				if s, _ := tbl["TableStatus"].(string); s == "ACTIVE" {
					return true
				}
			}
		}
		time.Sleep(400 * time.Millisecond)
	}
	return false
}

// tablePrecheck gathers everything the confirmation dialog needs. Read-only.
func (m *manager) tablePrecheck(id string) map[string]any {
	m.mu.Lock()
	cfg, _ := m.findConfig(id)
	if cfg == nil {
		m.mu.Unlock()
		return map[string]any{"ok": false, "error": "config not found"}
	}
	c := *cfg // copy for use outside the lock
	deps := m.tableDependents(cfg)
	type dep struct {
		ID, Name string
		Running  bool
	}
	var depInfos []dep
	for _, d := range deps {
		depInfos = append(depInfos, dep{ID: d.ID, Name: d.Name})
	}
	m.mu.Unlock()

	// AWS target (empty endpoint OR an explicit AWS host) == table lifecycle not allowed.
	endpoint := strings.TrimSpace(c.Endpoint)
	if awsModeForEndpoint(endpoint) {
		return map[string]any{
			"ok":      true,
			"allowed": false,
			"reason":  "AWS mode — table lifecycle operations are disabled for real AWS targets.",
			"table":   c.Table,
		}
	}

	depsOut := make([]map[string]any, 0, len(depInfos))
	for i := range depInfos {
		depInfos[i].Running = m.isActive(depInfos[i].ID)
		depsOut = append(depsOut, map[string]any{
			"id": depInfos[i].ID, "name": depInfos[i].Name, "running": depInfos[i].Running,
		})
	}

	// Best-effort item count + age for the "blast-radius" friction step.
	itemCount, ageDays := -1, -1
	if desc, err := ddbCall(&c, "DescribeTable", map[string]any{"TableName": c.Table}); err == nil {
		if tbl, ok := desc["Table"].(map[string]any); ok {
			if n, ok := tbl["ItemCount"].(float64); ok {
				itemCount = int(n)
			}
			if cd, ok := tbl["CreationDateTime"].(float64); ok && cd > 0 {
				ageDays = int(time.Since(time.Unix(int64(cd), 0)).Hours() / 24)
			}
		}
	}

	return map[string]any{
		"ok":        true,
		"allowed":   true,
		"table":     c.Table,
		"endpoint":  endpoint,
		"loopback":  endpointIsLoopback(endpoint),
		"version":   c.Version,
		"itemCount": itemCount,
		"ageDays":   ageDays,
		"dependents": depsOut,
	}
}

// recreateTable rebuilds the table from scratch while its dependents are down:
// it stops every running config that uses this table, deletes the table, then
// restarts them — starting the CLICKED config FIRST with a one-shot
// -auto-create-table so redimos rebuilds the table with THAT config's
// authoritative schema (matching the version the confirmation dialog promised),
// even when several configs of differing versions share the table. The other
// previously-running dependents are then restored. If the clicked config was not
// itself running, it is started only long enough to recreate the table and then
// returned to its prior stopped state. Endpoint-gated (L2 backstop). Transactional:
// if the delete fails, the stopped configs are restarted to restore prior state.
func (m *manager) recreateTable(id string) map[string]any {
	m.mu.Lock()
	cfg, _ := m.findConfig(id)
	if cfg == nil {
		m.mu.Unlock()
		return map[string]any{"ok": false, "error": "config not found"}
	}
	c := *cfg
	deps := m.tableDependents(cfg)
	depIDs := make([]string, 0, len(deps))
	for _, d := range deps {
		depIDs = append(depIDs, d.ID)
	}
	m.mu.Unlock()

	// L2 backstop: never touch a table lifecycle on a real AWS target (empty endpoint
	// or an explicit AWS host).
	if awsModeForEndpoint(c.Endpoint) {
		return map[string]any{"ok": false,
			"error": "destructive table ops require an explicit non-AWS endpoint (real AWS is read-only for table lifecycle)"}
	}

	// Snapshot which dependents are running now — these get stopped and restored.
	var wasRunning []string
	idWasRunning := false
	for _, did := range depIDs {
		if m.isActive(did) {
			wasRunning = append(wasRunning, did)
			if did == id {
				idWasRunning = true
			}
		}
	}

	steps := []string{}
	for _, did := range wasRunning {
		_ = m.stop(did)
	}
	if len(wasRunning) > 0 {
		steps = append(steps, fmt.Sprintf("stopped %d config(s)", len(wasRunning)))
	}
	// Let the ports actually free before deleting/restarting.
	time.Sleep(500 * time.Millisecond)

	if err := deleteTableAndWait(&c); err != nil {
		// Restore: bring the stopped configs back so we don't leave a half state.
		for _, did := range wasRunning {
			_ = m.start(did)
		}
		return map[string]any{"ok": false,
			"error": "delete table failed: " + err.Error(),
			"steps": append(steps, "restored stopped configs")}
	}
	steps = append(steps, "deleted table "+c.Table)

	// The clicked config authors the rebuilt schema: start it FIRST with the
	// one-shot auto-create so the table comes back with THIS config's version.
	m.mu.Lock()
	if m.forceAC == nil {
		m.forceAC = map[string]bool{}
	}
	m.forceAC[id] = true
	m.mu.Unlock()
	if err := m.start(id); err != nil {
		// Clear the one-shot auto-create: a start that failed before buildLaunch
		// consumed it would otherwise leak the flag into an unrelated later start of
		// this config. The table is already gone, so recovery is to re-run Recreate
		// (which re-arms the flag) — not a plain manual Start, which wouldn't create it.
		m.mu.Lock()
		delete(m.forceAC, id)
		m.mu.Unlock()
		return map[string]any{"ok": false,
			"error": fmt.Sprintf("table deleted but restart of %q failed: %v — click Recreate again to rebuild the table", c.Name, err),
			"steps": steps, "recreated": false, "restartFailed": true}
	}

	// Confirm redimos rebuilt the table BEFORE bringing up the other dependents:
	// they have no auto-create and would crash-loop against a not-yet-created table.
	tableBack := waitTableActive(&c, 12*time.Second)

	restored := 1 // the clicked config
	for _, did := range wasRunning {
		if did == id {
			continue
		}
		if err := m.start(did); err == nil {
			restored++
		}
	}

	// If the clicked config wasn't running before, it was started only to rebuild
	// the table — return it to its prior stopped state and drop it from restore.
	if !idWasRunning {
		_ = m.stop(id)
		m.rememberConfigAutoStart(id, false)
		restored--
		steps = append(steps, "left "+c.Name+" stopped (it was not running)")
	}
	steps = append(steps, fmt.Sprintf("restarted %d config(s)", restored))

	if tableBack {
		return map[string]any{"ok": true, "recreated": true, "steps": append(steps, "table is ACTIVE")}
	}
	return map[string]any{"ok": true, "recreated": true,
		"steps":   append(steps, "restart done; table not yet ACTIVE (still creating)"),
		"warning": "table not ACTIVE yet — check the Logs tab"}
}

// depsForTable returns every saved config on cfg's (normalised) endpoint bound to
// the given table name (which may differ from cfg.Table — the Endpoint tab acts on
// an arbitrary row). Caller must NOT hold m.mu.
func (m *manager) depsForTable(cfg *Config, table string) []map[string]any {
	key := normEndpoint(cfg.Endpoint) + "\x00" + table
	out := []map[string]any{}
	m.mu.Lock()
	for i := range m.st.Configs {
		c := &m.st.Configs[i]
		if normEndpoint(c.Endpoint)+"\x00"+c.Table == key {
			out = append(out, map[string]any{"id": c.ID, "name": c.Name})
		}
	}
	m.mu.Unlock()
	for _, d := range out {
		d["running"] = m.isActive(d["id"].(string))
	}
	return out
}

// inspectTable gathers the blast-radius info (endpoint, loopback, item count, age,
// bound running dependents) that the Purge / Delete confirmation dialogs need for an
// arbitrary table on cfg's endpoint. Read-only. Endpoint-gated: AWS mode returns
// allowed:false so the UI can hard-disable the destructive actions.
func (m *manager) inspectTable(cfg *Config, table string) map[string]any {
	endpoint := strings.TrimSpace(cfg.Endpoint)
	if strings.TrimSpace(table) == "" {
		return map[string]any{"ok": false, "error": "no table specified"}
	}
	if awsModeForEndpoint(endpoint) {
		return map[string]any{"ok": true, "allowed": false,
			"reason": "AWS mode — table lifecycle operations are disabled for real AWS targets.",
			"table":  table}
	}
	deps := m.depsForTable(cfg, table)
	itemCount, ageDays := -1, -1
	if desc, err := ddbCall(cfg, "DescribeTable", map[string]any{"TableName": table}); err == nil {
		if tbl, ok := desc["Table"].(map[string]any); ok {
			if n, ok := tbl["ItemCount"].(float64); ok {
				itemCount = int(n)
			}
			if cd, ok := tbl["CreationDateTime"].(float64); ok && cd > 0 {
				ageDays = int(time.Since(time.Unix(int64(cd), 0)).Hours() / 24)
			}
		}
	}
	return map[string]any{"ok": true, "allowed": true, "table": table,
		"endpoint": endpoint, "loopback": endpointIsLoopback(endpoint),
		"itemCount": itemCount, "ageDays": ageDays, "dependents": deps}
}

// deleteTableOnly drops `table` on cfg's endpoint WITHOUT recreating it. Any running
// config bound to it is stopped first and left stopped with auto-start cleared — a
// running proxy against a deleted table serves errors and would crash-loop on the
// next restart. Endpoint-gated (L2 backstop). Transactional: if the delete fails the
// stopped configs are restarted to restore prior state.
func (m *manager) deleteTableOnly(cfg *Config, table string) map[string]any {
	if awsModeForEndpoint(cfg.Endpoint) {
		return map[string]any{"ok": false,
			"error": "destructive table ops require an explicit non-AWS endpoint (real AWS is read-only for table lifecycle)"}
	}
	if strings.TrimSpace(table) == "" {
		return map[string]any{"ok": false, "error": "no table specified"}
	}

	deps := m.depsForTable(cfg, table)
	var wasRunning []string
	for _, d := range deps {
		if d["running"] == true {
			wasRunning = append(wasRunning, d["id"].(string))
		}
	}
	steps := []string{}
	for _, did := range wasRunning {
		_ = m.stop(did) // don't touch auto-start yet — restore cleanly if the delete fails
	}
	if len(wasRunning) > 0 {
		steps = append(steps, fmt.Sprintf("stopped %d config(s)", len(wasRunning)))
	}
	time.Sleep(500 * time.Millisecond) // let ports/handles free before the delete

	dc := *cfg
	dc.Table = table // delete the row's table via cfg's endpoint/creds (cfg.Table may differ)
	if err := deleteTableAndWait(&dc); err != nil {
		for _, did := range wasRunning { // restore prior state on failure (auto-start untouched)
			_ = m.start(did)
		}
		return map[string]any{"ok": false,
			"error": "delete table failed: " + err.Error(),
			"steps": append(steps, "restored stopped configs")}
	}
	// Delete succeeded: clear auto-start for EVERY bound config — not just the ones
	// that were running. A bound-but-inactive config left with auto-start would
	// relaunch into the now-missing table on the next boot (or, with AutoCreate on,
	// silently recreate it and undo this delete).
	for _, d := range deps {
		if id, ok := d["id"].(string); ok {
			m.rememberConfigAutoStart(id, false)
		}
	}
	steps = append(steps, "deleted table "+table)
	if len(wasRunning) > 0 {
		steps = append(steps, fmt.Sprintf("left %d config(s) stopped", len(wasRunning)))
	}
	return map[string]any{"ok": true, "steps": steps}
}
