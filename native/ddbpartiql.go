package main

// PartiQL statement execution backing the manager's "PartiQL" tab — the
// console's PartiQL-editor equivalent, over the same hand-rolled SigV4 client
// (ddbCall in ddbinspect.go). One statement per call via ExecuteStatement, with
// NextToken pagination. Result cells reuse cellFromAV (ddbtable.go) so Binary
// values render as readable UTF-8 where printable, base64 otherwise.

import (
	"encoding/json"
	"sort"
	"strings"
	"time"
)

type partiqlReq struct {
	Config    Config `json:"config"`
	Statement string `json:"statement"`
	Limit     int    `json:"limit"`
	NextToken string `json:"nextToken"`
}

// partiqlExec runs one PartiQL statement. SELECTs return rows/cols; write
// statements return ok with zero rows (the guard/confirmation lives in the UI).
func partiqlExec(req *partiqlReq) map[string]any {
	stmt := strings.TrimSpace(req.Statement)
	if stmt == "" {
		return map[string]any{"ok": false, "error": "ValidationException: statement is empty"}
	}
	payload := map[string]any{"Statement": stmt}
	if req.Limit > 0 {
		payload["Limit"] = req.Limit
	}
	if req.NextToken != "" {
		payload["NextToken"] = req.NextToken
	}

	t0 := time.Now()
	out, err := ddbCall(&req.Config, "ExecuteStatement", payload)
	elapsed := time.Since(t0).Milliseconds()
	if err != nil {
		// Surface the AWS exception type alongside the message, console-style.
		msg := err.Error()
		if out != nil {
			if t, ok := out["__type"].(string); ok {
				if i := strings.LastIndex(t, "#"); i >= 0 {
					t = t[i+1:]
				}
				if m, ok := out["message"].(string); ok {
					msg = t + ": " + m
				} else if m, ok := out["Message"].(string); ok {
					msg = t + ": " + m
				} else {
					msg = t
				}
			}
		}
		return map[string]any{"ok": false, "error": msg, "timeMs": elapsed}
	}

	items, _ := out["Items"].([]any)
	rows := make([]map[string]any, 0, len(items))
	seen := map[string]bool{}
	var cols []string
	for _, it := range items {
		m, _ := it.(map[string]any)
		cells := map[string]any{}
		for attr, av := range m {
			avm, _ := av.(map[string]any)
			cells[attr] = cellFromAV(avm)
			if !seen[attr] {
				seen[attr] = true
				cols = append(cols, attr)
			}
		}
		ddbJSON, _ := json.Marshal(m)
		rows = append(rows, map[string]any{"cells": cells, "ddbJson": string(ddbJSON)})
	}
	sort.Strings(cols)

	res := map[string]any{
		"ok":       true,
		"cols":     cols,
		"rows":     rows,
		"returned": len(rows),
		"timeMs":   elapsed,
	}
	if nt, ok := out["NextToken"].(string); ok && nt != "" {
		res["nextToken"] = nt
	}
	return res
}
