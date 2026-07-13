package main

// Endpoint-level table listing for the "Endpoint" tab (a dynamodb-admin-style
// landing page). Read-only: it talks to DynamoDB directly via the signed
// ddbCall plane (no running redimos proxy required), lists every table on the
// config's endpoint with DescribeTable-derived metadata, infers whether each is
// a redimos table (and which version), joins the configs that use each table,
// and synthesises "ghost" rows for tables a config is bound to but that don't
// exist on the endpoint yet.

import (
	"sort"
	"strings"
)

// endpointTables lists the tables on cfg's endpoint. Never a destructive op.
func (m *manager) endpointTables(cfg *Config) map[string]any {
	c := *cfg
	endpoint := strings.TrimSpace(c.Endpoint)
	awsMode := endpoint == ""

	// Snapshot sibling configs (same normalised endpoint) for used-by + ghosts.
	type bound struct{ id, name, table, version string }
	var siblings []bound
	key := normEndpoint(c.Endpoint)
	m.mu.Lock()
	for i := range m.st.Configs {
		sc := &m.st.Configs[i]
		if normEndpoint(sc.Endpoint) == key {
			siblings = append(siblings, bound{sc.ID, sc.Name, sc.Table, sc.Version})
		}
	}
	m.mu.Unlock()

	// ListTables (paginated, capped so a huge AWS account can't hang the UI).
	names := []string{}
	var start any
	for {
		payload := map[string]any{"Limit": float64(100)}
		if start != nil {
			payload["ExclusiveStartTableName"] = start
		}
		resp, err := ddbCall(&c, "ListTables", payload)
		if err != nil {
			return map[string]any{"ok": false, "error": err.Error(),
				"endpoint": endpoint, "awsMode": awsMode, "loopback": endpointIsLoopback(endpoint)}
		}
		if tn, ok := resp["TableNames"].([]any); ok {
			for _, n := range tn {
				if s, ok := n.(string); ok {
					names = append(names, s)
				}
			}
		}
		last, ok := resp["LastEvaluatedTableName"].(string)
		if !ok || last == "" || len(names) >= 500 {
			break
		}
		start = last
	}
	sort.Strings(names)
	exists := map[string]bool{}
	for _, n := range names {
		exists[n] = true
	}

	usedByFor := func(table string) []map[string]any {
		out := []map[string]any{}
		for _, b := range siblings {
			if b.table == table {
				out = append(out, map[string]any{
					"id": b.id, "name": b.name, "version": b.version, "running": m.isActive(b.id)})
			}
		}
		return out
	}

	tables := make([]map[string]any, 0, len(names)+len(siblings))
	for _, name := range names {
		row := map[string]any{"name": name, "usedBy": usedByFor(name), "missing": false}
		if desc, err := ddbCall(&c, "DescribeTable", map[string]any{"TableName": name}); err == nil {
			fillTableRow(row, desc)
		} else {
			row["status"] = "?"
			row["kind"] = "raw"
		}
		tables = append(tables, row)
	}

	// Ghost rows: a sibling config's table that isn't present on the endpoint.
	seenGhost := map[string]bool{}
	for _, b := range siblings {
		if b.table == "" || exists[b.table] || seenGhost[b.table] {
			continue
		}
		seenGhost[b.table] = true
		tables = append(tables, map[string]any{
			"name": b.table, "missing": true, "status": "MISSING",
			"kind": b.version, "usedBy": usedByFor(b.table),
		})
	}

	return map[string]any{
		"ok": true, "endpoint": endpoint, "awsMode": awsMode,
		"loopback": endpointIsLoopback(endpoint), "tables": tables,
	}
}

// fillTableRow decodes a DescribeTable response into the row map.
func fillTableRow(row map[string]any, desc map[string]any) {
	tbl, _ := desc["Table"].(map[string]any)
	if tbl == nil {
		row["status"] = "?"
		row["kind"] = "raw"
		return
	}
	if s, ok := tbl["TableStatus"].(string); ok {
		row["status"] = s
	}
	if n, ok := tbl["ItemCount"].(float64); ok {
		row["itemCount"] = int(n)
	}
	if n, ok := tbl["TableSizeBytes"].(float64); ok {
		row["sizeBytes"] = int64(n)
	}
	attrType := map[string]string{}
	if ads, ok := tbl["AttributeDefinitions"].([]any); ok {
		for _, e := range ads {
			if m, ok := e.(map[string]any); ok {
				an, _ := m["AttributeName"].(string)
				at, _ := m["AttributeType"].(string)
				attrType[an] = at
			}
		}
	}
	pkName, skName := "", ""
	if ks, ok := tbl["KeySchema"].([]any); ok {
		for _, e := range ks {
			if m, ok := e.(map[string]any); ok {
				switch m["KeyType"] {
				case "HASH":
					pkName, _ = m["AttributeName"].(string)
				case "RANGE":
					skName, _ = m["AttributeName"].(string)
				}
			}
		}
	}
	gsi, lsi := 0, 0
	if g, ok := tbl["GlobalSecondaryIndexes"].([]any); ok {
		gsi = len(g)
	}
	if l, ok := tbl["LocalSecondaryIndexes"].([]any); ok {
		lsi = len(l)
	}
	row["pkName"] = pkName
	row["pkType"] = attrType[pkName]
	row["skName"] = skName
	row["skType"] = attrType[skName]
	row["gsiCount"] = gsi
	row["lsiCount"] = lsi
	row["kind"] = inferKind(attrType[pkName], skName, lsi)
}

// getItem fetches one full item by key (consistent read). Used before editing so
// the editor never operates on a projection-truncated item (a subsequent PutItem
// full-replace would otherwise drop the attributes the scan projected away).
// Read-only — no endpoint gate.
func (m *manager) getItem(cfg *Config, key map[string]any) map[string]any {
	resp, err := ddbCall(cfg, "GetItem", map[string]any{
		"TableName": cfg.Table, "Key": key, "ConsistentRead": true})
	if err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	item, _ := resp["Item"].(map[string]any)
	if item == nil {
		return map[string]any{"ok": false, "error": "item not found"}
	}
	return map[string]any{"ok": true, "item": item}
}

// putItem writes one item (full replace, like DynamoDB PutItem) to cfg's table.
// Endpoint-gated: refused in AWS mode, consistent with the table-lifecycle wall.
func (m *manager) putItem(cfg *Config, item map[string]any) map[string]any {
	if strings.TrimSpace(cfg.Endpoint) == "" {
		return map[string]any{"ok": false, "error": "item writes require an explicit endpoint (AWS mode is read-only)"}
	}
	if _, err := ddbCall(cfg, "PutItem", map[string]any{"TableName": cfg.Table, "Item": item}); err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	return map[string]any{"ok": true}
}

// deleteItem removes one item by its key from cfg's table. Endpoint-gated.
func (m *manager) deleteItem(cfg *Config, key map[string]any) map[string]any {
	if strings.TrimSpace(cfg.Endpoint) == "" {
		return map[string]any{"ok": false, "error": "item writes require an explicit endpoint (AWS mode is read-only)"}
	}
	if _, err := ddbCall(cfg, "DeleteItem", map[string]any{"TableName": cfg.Table, "Key": key}); err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	return map[string]any{"ok": true}
}

// inferKind classifies a table from its key shape: a redimos table has pk+sk plus
// a local secondary index; v2 keys are Binary, v1 keys are String. Anything else
// is a raw (non-redimos) table.
func inferKind(pkType, skName string, lsiCount int) string {
	if skName != "" && lsiCount > 0 {
		switch pkType {
		case "B":
			return "v2"
		case "S":
			return "v1"
		}
	}
	return "raw"
}
