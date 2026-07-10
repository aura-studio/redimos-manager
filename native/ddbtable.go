package main

// Read-only DynamoDB table browser backing the manager's "Table" tab — a
// redimos-flavoured take on the AWS console's Explore-items page. Reuses the
// hand-rolled SigV4 client in ddbinspect.go (ddbCall) so the native module stays
// dependency-free.
//
// Two entry points:
//   tableMeta  — DescribeTable → the selectable targets (base table + each LSI/
//                GSI) with their pk/sk attribute name+type, for the Scan/Query UI.
//   tablePage  — one Scan or Query page: projection, sort-key condition, filter
//                expression, DynamoDB-style LastEvaluatedKey pagination. Values
//                come back both as a display "repr" (Binary decoded to UTF-8 when
//                printable — redimos keys like "0:ci:6404" are readable) and, for
//                Binary, the raw base64, plus the item's DynamoDB JSON for the
//                detail dialog.
//
// v1 is read-only: no PutItem/DeleteItem here by design.

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// ---- meta -----------------------------------------------------------------

type keyRef struct {
	Name string `json:"name"`
	Type string `json:"type"` // S | N | B
}

type tableTarget struct {
	Name string  `json:"name"` // table name or index name
	Kind string  `json:"kind"` // "table" | "LSI" | "GSI"
	PK   keyRef  `json:"pk"`
	SK   *keyRef `json:"sk,omitempty"`
}

// attrTypeMap indexes AttributeDefinitions by attribute name.
func attrTypeMap(tbl map[string]any) map[string]string {
	out := map[string]string{}
	if ads, ok := tbl["AttributeDefinitions"].([]any); ok {
		for _, e := range ads {
			m, _ := e.(map[string]any)
			if m == nil {
				continue
			}
			n, _ := m["AttributeName"].(string)
			t, _ := m["AttributeType"].(string)
			if n != "" {
				out[n] = t
			}
		}
	}
	return out
}

// keysFromSchema turns a KeySchema array into pk + optional sk keyRefs.
func keysFromSchema(schema []any, types map[string]string) (pk keyRef, sk *keyRef) {
	for _, e := range schema {
		m, _ := e.(map[string]any)
		if m == nil {
			continue
		}
		n, _ := m["AttributeName"].(string)
		role, _ := m["KeyType"].(string)
		ref := keyRef{Name: n, Type: types[n]}
		if role == "HASH" {
			pk = ref
		} else if role == "RANGE" {
			r := ref
			sk = &r
		}
	}
	return
}

// tableMeta returns the base table + every secondary index as selectable targets.
func tableMeta(cfg *Config) map[string]any {
	desc, err := ddbCall(cfg, "DescribeTable", map[string]any{"TableName": cfg.Table})
	if err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	tbl, _ := desc["Table"].(map[string]any)
	if tbl == nil {
		return map[string]any{"ok": false, "error": "no table in DescribeTable response"}
	}
	types := attrTypeMap(tbl)

	var targets []tableTarget
	if ks, ok := tbl["KeySchema"].([]any); ok {
		pk, sk := keysFromSchema(ks, types)
		targets = append(targets, tableTarget{Name: cfg.Table, Kind: "table", PK: pk, SK: sk})
	}
	addIdx := func(list any, kind string) {
		arr, _ := list.([]any)
		for _, e := range arr {
			m, _ := e.(map[string]any)
			if m == nil {
				continue
			}
			name, _ := m["IndexName"].(string)
			ks, _ := m["KeySchema"].([]any)
			pk, sk := keysFromSchema(ks, types)
			targets = append(targets, tableTarget{Name: name, Kind: kind, PK: pk, SK: sk})
		}
	}
	addIdx(tbl["LocalSecondaryIndexes"], "LSI")
	addIdx(tbl["GlobalSecondaryIndexes"], "GSI")

	return map[string]any{"ok": true, "table": cfg.Table, "targets": targets}
}

// ---- page (scan/query) ----------------------------------------------------

type skCond struct {
	Op string `json:"op"` // eq|le|lt|ge|gt|between|begins_with
	V1 string `json:"v1"`
	V2 string `json:"v2"`
}

type tableFilter struct {
	Attr string `json:"attr"`
	Type string `json:"type"` // S|N|B|BOOL|NULL
	Op   string `json:"op"`   // eq|ne|le|lt|ge|gt|between|exists|not_exists|contains|not_contains|begins_with
	V1   string `json:"v1"`
	V2   string `json:"v2"`
}

type tablePageReq struct {
	Config       Config         `json:"config"`
	Op           string         `json:"op"`    // "scan" | "query"
	Index        string         `json:"index"` // "" = base table
	Projection   string         `json:"projection"`
	ProjectAttrs []string       `json:"projectAttrs"`
	PKValue      string         `json:"pkValue"`
	SKCond       *skCond        `json:"skCond"`
	ScanForward  bool           `json:"scanForward"`
	Filters      []tableFilter  `json:"filters"`
	Limit        int            `json:"limit"`
	StartKey     map[string]any `json:"startKey"`
}

// encodeAV builds a DynamoDB AttributeValue from a typed plain-text value.
// Binary takes UTF-8 plaintext and base64-encodes it (so a user types the
// readable key, not base64).
func encodeAV(typ, v string) map[string]any {
	switch typ {
	case "N":
		return map[string]any{"N": v}
	case "B":
		return map[string]any{"B": base64.StdEncoding.EncodeToString([]byte(v))}
	case "BOOL":
		return map[string]any{"BOOL": strings.EqualFold(strings.TrimSpace(v), "true")}
	case "NULL":
		return map[string]any{"NULL": true}
	default: // S
		return map[string]any{"S": v}
	}
}

func cmpExpr(op string) string {
	switch op {
	case "le":
		return "<="
	case "lt":
		return "<"
	case "ge":
		return ">="
	case "gt":
		return ">"
	case "ne":
		return "<>"
	default: // eq
		return "="
	}
}

func tablePage(req *tablePageReq) map[string]any {
	cfg := &req.Config
	// Authoritative key schema for the chosen target (base or index).
	desc, err := ddbCall(cfg, "DescribeTable", map[string]any{"TableName": cfg.Table})
	if err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	tbl, _ := desc["Table"].(map[string]any)
	if tbl == nil {
		return map[string]any{"ok": false, "error": "no table in DescribeTable response"}
	}
	types := attrTypeMap(tbl)
	schema, _ := tbl["KeySchema"].([]any)
	if req.Index != "" {
		schema = indexSchema(tbl, req.Index)
		if schema == nil {
			return map[string]any{"ok": false, "error": "index not found: " + req.Index}
		}
	}
	pk, sk := keysFromSchema(schema, types)

	names := map[string]any{}
	values := map[string]any{}
	payload := map[string]any{"TableName": cfg.Table}
	if req.Index != "" {
		payload["IndexName"] = req.Index
	}
	if req.Limit > 0 {
		payload["Limit"] = req.Limit
	}
	if len(req.StartKey) > 0 {
		payload["ExclusiveStartKey"] = req.StartKey
	}

	// Projection.
	if req.Projection == "specific" && len(req.ProjectAttrs) > 0 {
		var parts []string
		for i, a := range req.ProjectAttrs {
			ph := fmt.Sprintf("#p%d", i)
			names[ph] = a
			parts = append(parts, ph)
		}
		payload["ProjectionExpression"] = strings.Join(parts, ", ")
	}

	// Filters (Scan and Query both).
	if fe := buildFilter(req.Filters, names, values); fe != "" {
		payload["FilterExpression"] = fe
	}

	target := "Scan"
	if req.Op == "query" {
		target = "Query"
		if strings.TrimSpace(req.PKValue) == "" {
			return map[string]any{"ok": false, "error": "The partition key value cannot be empty."}
		}
		names["#pk"] = pk.Name
		values[":pk"] = encodeAV(pk.Type, req.PKValue)
		kce := "#pk = :pk"
		if req.SKCond != nil && sk != nil && strings.TrimSpace(req.SKCond.V1) != "" {
			names["#sk"] = sk.Name
			switch req.SKCond.Op {
			case "between":
				values[":sk1"] = encodeAV(sk.Type, req.SKCond.V1)
				values[":sk2"] = encodeAV(sk.Type, req.SKCond.V2)
				kce += " AND #sk BETWEEN :sk1 AND :sk2"
			case "begins_with":
				values[":sk"] = encodeAV(sk.Type, req.SKCond.V1)
				kce += " AND begins_with(#sk, :sk)"
			default:
				values[":sk"] = encodeAV(sk.Type, req.SKCond.V1)
				kce += " AND #sk " + cmpExpr(req.SKCond.Op) + " :sk"
			}
		}
		payload["KeyConditionExpression"] = kce
		payload["ScanIndexForward"] = req.ScanForward
	}
	if len(names) > 0 {
		payload["ExpressionAttributeNames"] = names
	}
	if len(values) > 0 {
		payload["ExpressionAttributeValues"] = values
	}

	t0 := time.Now()
	out, err := ddbCall(cfg, target, payload)
	if err != nil {
		return map[string]any{"ok": false, "error": err.Error()}
	}
	elapsed := time.Since(t0).Milliseconds()

	items, _ := out["Items"].([]any)
	rows := make([]map[string]any, 0, len(items))
	seen := map[string]bool{}
	var extra []string
	for _, it := range items {
		m, _ := it.(map[string]any)
		cells := map[string]any{}
		for attr, av := range m {
			avm, _ := av.(map[string]any)
			cells[attr] = cellFromAV(avm)
			if !seen[attr] {
				seen[attr] = true
				extra = append(extra, attr)
			}
		}
		ddbJSON, _ := json.Marshal(m)
		rows = append(rows, map[string]any{"cells": cells, "ddbJson": string(ddbJSON)})
	}

	// Column order: pk, sk, then the rest alphabetically.
	sort.Strings(extra)
	var cols []string
	keyset := map[string]bool{}
	if pk.Name != "" {
		cols = append(cols, pk.Name)
		keyset[pk.Name] = true
	}
	if sk != nil && sk.Name != "" && !keyset[sk.Name] {
		cols = append(cols, sk.Name)
		keyset[sk.Name] = true
	}
	for _, a := range extra {
		if !keyset[a] {
			cols = append(cols, a)
		}
	}

	res := map[string]any{
		"ok":       true,
		"cols":     cols,
		"rows":     rows,
		"returned": numOr(out["Count"]),
		"scanned":  numOr(out["ScannedCount"]),
		"timeMs":   elapsed,
	}
	if lek, ok := out["LastEvaluatedKey"].(map[string]any); ok && len(lek) > 0 {
		res["lastKey"] = lek
	}
	return res
}

func indexSchema(tbl map[string]any, name string) []any {
	for _, key := range []string{"LocalSecondaryIndexes", "GlobalSecondaryIndexes"} {
		arr, _ := tbl[key].([]any)
		for _, e := range arr {
			m, _ := e.(map[string]any)
			if m != nil && m["IndexName"] == name {
				ks, _ := m["KeySchema"].([]any)
				return ks
			}
		}
	}
	return nil
}

// buildFilter assembles a FilterExpression (filters AND-ed) and registers the
// name/value placeholders. Returns "" when there are no usable filters.
func buildFilter(filters []tableFilter, names, values map[string]any) string {
	var parts []string
	for i, f := range filters {
		if strings.TrimSpace(f.Attr) == "" {
			continue
		}
		na := fmt.Sprintf("#fa%d", i)
		names[na] = f.Attr
		va := fmt.Sprintf(":fv%d", i)
		switch f.Op {
		case "exists":
			parts = append(parts, fmt.Sprintf("attribute_exists(%s)", na))
			continue
		case "not_exists":
			parts = append(parts, fmt.Sprintf("attribute_not_exists(%s)", na))
			continue
		case "contains":
			values[va] = encodeAV(f.Type, f.V1)
			parts = append(parts, fmt.Sprintf("contains(%s, %s)", na, va))
			continue
		case "not_contains":
			values[va] = encodeAV(f.Type, f.V1)
			parts = append(parts, fmt.Sprintf("NOT contains(%s, %s)", na, va))
			continue
		case "begins_with":
			values[va] = encodeAV(f.Type, f.V1)
			parts = append(parts, fmt.Sprintf("begins_with(%s, %s)", na, va))
			continue
		case "between":
			vb := fmt.Sprintf(":fw%d", i)
			values[va] = encodeAV(f.Type, f.V1)
			values[vb] = encodeAV(f.Type, f.V2)
			parts = append(parts, fmt.Sprintf("%s BETWEEN %s AND %s", na, va, vb))
			continue
		default: // eq ne le lt ge gt
			values[va] = encodeAV(f.Type, f.V1)
			parts = append(parts, fmt.Sprintf("%s %s %s", na, cmpExpr(f.Op), va))
		}
	}
	return strings.Join(parts, " AND ")
}

// cellFromAV converts one AttributeValue to a display cell. Binary is decoded to
// UTF-8 when printable (readable redimos keys), else shown as base64.
func cellFromAV(av map[string]any) map[string]any {
	for t, v := range av {
		switch t {
		case "S":
			s, _ := v.(string)
			return map[string]any{"t": "S", "repr": s}
		case "N":
			s, _ := v.(string)
			return map[string]any{"t": "N", "repr": s}
		case "BOOL":
			return map[string]any{"t": "BOOL", "repr": fmt.Sprintf("%v", v)}
		case "NULL":
			return map[string]any{"t": "NULL", "repr": "null"}
		case "B":
			b64, _ := v.(string)
			raw, err := base64.StdEncoding.DecodeString(b64)
			if err == nil && isPrintable(raw) {
				return map[string]any{"t": "B", "b64": b64, "repr": string(raw), "printable": true}
			}
			return map[string]any{"t": "B", "b64": b64, "repr": b64, "printable": false}
		default:
			// SS/NS/BS/L/M — show the compact DynamoDB JSON of just this value.
			j, _ := json.Marshal(av)
			return map[string]any{"t": t, "repr": string(j)}
		}
	}
	return map[string]any{"t": "?", "repr": ""}
}

// isPrintable reports whether b is valid UTF-8 with no control characters
// (tab excepted), i.e. safe to show as text rather than base64.
func isPrintable(b []byte) bool {
	if len(b) == 0 || !utf8.Valid(b) {
		return false
	}
	for _, r := range string(b) {
		if r == utf8.RuneError || (r < 0x20 && r != '\t') || r == 0x7f {
			return false
		}
	}
	return true
}

func numOr(v any) int {
	if f, ok := v.(float64); ok {
		return int(f)
	}
	return 0
}
