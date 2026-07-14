// Playground: run a user JS (goja) or Go (yaegi) script against a running
// instance's Redis (`redis` host) or an endpoint's DynamoDB (`ddb` host), with a
// `console` for output. Both interpreters are pure-Go and sandboxed — only the
// injected host objects are reachable (no fs / net / os beyond the client) — and
// cancellable on timeout (goja.Interrupt / yaegi context). Writes re-check the
// AWS read-only guard. redimos repos are untouched.

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strconv"
	"strings"
	"time"

	"github.com/dop251/goja"
	"github.com/traefik/yaegi/interp"
)

func pgJSON(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		b = []byte(`{"ok":false,"error":"marshal failed"}`)
	}
	return C.CString(string(b))
}

// --- console host ---

type playConsole struct{ lines []string }

func sprintArgs(args []interface{}) string {
	parts := make([]string, len(args))
	for i, a := range args {
		if s, ok := a.(string); ok {
			parts[i] = s
		} else {
			b, err := json.Marshal(a)
			if err != nil {
				parts[i] = fmt.Sprintf("%v", a)
			} else {
				parts[i] = string(b)
			}
		}
	}
	return strings.Join(parts, " ")
}

func (c *playConsole) Log(args ...interface{})   { c.lines = append(c.lines, sprintArgs(args)) }
func (c *playConsole) Error(args ...interface{}) { c.lines = append(c.lines, "ERROR: "+sprintArgs(args)) }

// Table renders a map or slice as pretty JSON (a simple, language-neutral table).
func (c *playConsole) Table(v interface{}) {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		c.lines = append(c.lines, fmt.Sprintf("%v", v))
		return
	}
	c.lines = append(c.lines, string(b))
}

// --- redis host (over the minimal RESP client) ---

type redisHost struct{ conn *respConn }

func (h *redisHost) Get(key string) (interface{}, error)  { return h.conn.cmd("GET", key) }
func (h *redisHost) Set(key, val string) (interface{}, error) {
	return h.conn.cmd("SET", key, val)
}
func (h *redisHost) Del(key string) (interface{}, error)  { return h.conn.cmd("DEL", key) }
func (h *redisHost) Type(key string) (interface{}, error) { return h.conn.cmd("TYPE", key) }
func (h *redisHost) TTL(key string) (interface{}, error)  { return h.conn.cmd("TTL", key) }
func (h *redisHost) Expire(key string, seconds int) (interface{}, error) {
	return h.conn.cmd("EXPIRE", key, strconv.Itoa(seconds))
}
func (h *redisHost) HGet(key, field string) (interface{}, error) {
	return h.conn.cmd("HGET", key, field)
}
func (h *redisHost) HSet(key, field, val string) (interface{}, error) {
	return h.conn.cmd("HSET", key, field, val)
}
func (h *redisHost) HGetAll(key string) (map[string]interface{}, error) {
	r, err := h.conn.cmd("HGETALL", key)
	if err != nil {
		return nil, err
	}
	arr, _ := r.([]interface{})
	out := map[string]interface{}{}
	for i := 0; i+1 < len(arr); i += 2 {
		out[fmt.Sprintf("%v", arr[i])] = arr[i+1]
	}
	return out, nil
}
func (h *redisHost) Command(args ...string) (interface{}, error) { return h.conn.cmd(args...) }

// Scan returns {cursor, keys} for one SCAN page.
func (h *redisHost) Scan(cursor, match string, count int) (map[string]interface{}, error) {
	if match == "" {
		match = "*"
	}
	if count <= 0 {
		count = 200
	}
	r, err := h.conn.cmd("SCAN", cursor, "MATCH", match, "COUNT", strconv.Itoa(count))
	if err != nil {
		return nil, err
	}
	arr, _ := r.([]interface{})
	next := "0"
	var keys []interface{}
	if len(arr) > 0 {
		next = fmt.Sprintf("%v", arr[0])
	}
	if len(arr) > 1 {
		keys, _ = arr[1].([]interface{})
	}
	return map[string]interface{}{"cursor": next, "keys": keys}, nil
}

// Keys walks the whole keyspace with SCAN (redimos disables KEYS).
func (h *redisHost) Keys(pattern string) ([]interface{}, error) {
	var out []interface{}
	cursor := "0"
	for guard := 0; guard < 100000; guard++ {
		page, err := h.Scan(cursor, pattern, 500)
		if err != nil {
			return nil, err
		}
		if ks, ok := page["keys"].([]interface{}); ok {
			out = append(out, ks...)
		}
		cursor = page["cursor"].(string)
		if cursor == "0" {
			break
		}
	}
	return out, nil
}

// --- ddb host (over the raw SigV4 ddbCall) ---

type ddbHost struct{ cfg *Config }

func (h *ddbHost) readOnly() bool { return awsModeForEndpoint(h.cfg.Endpoint) }

func (h *ddbHost) ListTables() ([]interface{}, error) {
	resp, err := ddbCall(h.cfg, "ListTables", map[string]any{})
	if err != nil {
		return nil, err
	}
	names, _ := resp["TableNames"].([]interface{})
	return names, nil
}

func (h *ddbHost) scanPayload(table string, opts map[string]interface{}) map[string]any {
	p := map[string]any{"TableName": table}
	if opts == nil {
		return p
	}
	if lim, ok := opts["limit"]; ok {
		p["Limit"] = toInt(lim)
	}
	if proj, ok := opts["projection"].([]interface{}); ok && len(proj) > 0 {
		names := make([]string, len(proj))
		exprNames := map[string]any{}
		for i, pr := range proj {
			alias := fmt.Sprintf("#p%d", i)
			names[i] = alias
			exprNames[alias] = fmt.Sprintf("%v", pr)
		}
		p["ProjectionExpression"] = strings.Join(names, ", ")
		p["ExpressionAttributeNames"] = exprNames
	}
	if cur, ok := opts["cursor"]; ok && cur != nil {
		p["ExclusiveStartKey"] = cur // opaque LastEvaluatedKey (AV map) round-tripped
	}
	return p
}

// Scan returns {items, cursor} for one page. Pass cursor back in opts to page.
func (h *ddbHost) Scan(table string, opts map[string]interface{}) (map[string]interface{}, error) {
	resp, err := ddbCall(h.cfg, "Scan", h.scanPayload(table, opts))
	if err != nil {
		return nil, err
	}
	out := map[string]interface{}{"items": itemsFromResp(resp)}
	if lek, ok := resp["LastEvaluatedKey"]; ok && lek != nil {
		out["cursor"] = lek
	}
	return out, nil
}

// ScanAll pages internally and returns every item (bounded to ~200k items).
func (h *ddbHost) ScanAll(table string, opts map[string]interface{}) ([]interface{}, error) {
	var all []interface{}
	if opts == nil {
		opts = map[string]interface{}{}
	}
	var lek interface{}
	for {
		if lek != nil {
			opts["cursor"] = lek
		}
		resp, err := ddbCall(h.cfg, "Scan", h.scanPayload(table, opts))
		if err != nil {
			return nil, err
		}
		all = append(all, itemsFromResp(resp)...)
		lek = resp["LastEvaluatedKey"]
		if lek == nil || len(all) > 200000 {
			break
		}
	}
	return all, nil
}

func (h *ddbHost) GetItem(table string, key map[string]interface{}) (interface{}, error) {
	resp, err := ddbCall(h.cfg, "GetItem", map[string]any{"TableName": table, "Key": itemToAV(key)})
	if err != nil {
		return nil, err
	}
	if item, ok := resp["Item"].(map[string]interface{}); ok {
		return itemFromAV(item), nil
	}
	return nil, nil
}

func (h *ddbHost) PutItem(table string, item map[string]interface{}) (interface{}, error) {
	if h.readOnly() {
		return nil, errors.New("this endpoint is AWS (read-only); writes are disabled")
	}
	_, err := ddbCall(h.cfg, "PutItem", map[string]any{"TableName": table, "Item": itemToAV(item)})
	return nil, err
}

func (h *ddbHost) DeleteItem(table string, key map[string]interface{}) (interface{}, error) {
	if h.readOnly() {
		return nil, errors.New("this endpoint is AWS (read-only); writes are disabled")
	}
	_, err := ddbCall(h.cfg, "DeleteItem", map[string]any{"TableName": table, "Key": itemToAV(key)})
	return nil, err
}

// PartiQL runs one statement; on AWS a non-SELECT is refused (read-only).
func (h *ddbHost) PartiQL(stmt string, params []interface{}) ([]interface{}, error) {
	if h.readOnly() && !strings.HasPrefix(strings.ToUpper(strings.TrimSpace(stmt)), "SELECT") {
		return nil, errors.New("this endpoint is AWS (read-only); only SELECT is allowed")
	}
	payload := map[string]any{"Statement": stmt}
	if len(params) > 0 {
		av := make([]interface{}, len(params))
		for i, p := range params {
			av[i] = plainToAV(p)
		}
		payload["Parameters"] = av
	}
	resp, err := ddbCall(h.cfg, "ExecuteStatement", payload)
	if err != nil {
		return nil, err
	}
	return itemsFromResp(resp), nil
}

// Call is a raw escape hatch: any DynamoDB op with a plain payload (attribute
// values are the caller's responsibility). Write ops are refused on AWS.
func (h *ddbHost) Call(op string, payload map[string]interface{}) (interface{}, error) {
	if h.readOnly() && isDdbWriteOp(op) {
		return nil, errors.New("this endpoint is AWS (read-only); write ops are disabled")
	}
	return ddbCall(h.cfg, op, map[string]any(payload))
}

func isDdbWriteOp(op string) bool {
	switch op {
	case "PutItem", "DeleteItem", "UpdateItem", "BatchWriteItem", "CreateTable",
		"DeleteTable", "UpdateTable", "TransactWriteItems":
		return true
	}
	return false
}

func itemsFromResp(resp map[string]any) []interface{} {
	raw, _ := resp["Items"].([]interface{})
	out := make([]interface{}, 0, len(raw))
	for _, it := range raw {
		if m, ok := it.(map[string]interface{}); ok {
			out = append(out, itemFromAV(m))
		}
	}
	return out
}

func toInt(v interface{}) int {
	switch t := v.(type) {
	case int:
		return t
	case int64:
		return int(t)
	case float64:
		return int(t)
	case string:
		n, _ := strconv.Atoi(t)
		return n
	}
	return 0
}

// --- DynamoDB attribute-value <-> plain value ---

func itemFromAV(item map[string]interface{}) map[string]interface{} {
	out := make(map[string]interface{}, len(item))
	for k, v := range item {
		out[k] = avToPlain(v)
	}
	return out
}

func itemToAV(item map[string]interface{}) map[string]interface{} {
	out := make(map[string]interface{}, len(item))
	for k, v := range item {
		out[k] = plainToAV(v)
	}
	return out
}

func avToPlain(av interface{}) interface{} {
	m, ok := av.(map[string]interface{})
	if !ok {
		return av
	}
	for k, v := range m { // an AV has exactly one type key
		switch k {
		case "S", "B":
			return v
		case "N":
			s, _ := v.(string)
			if i, err := strconv.ParseInt(s, 10, 64); err == nil {
				return i
			}
			if f, err := strconv.ParseFloat(s, 64); err == nil {
				return f
			}
			return s
		case "BOOL":
			return v
		case "NULL":
			return nil
		case "M":
			mm, _ := v.(map[string]interface{})
			return itemFromAV(mm)
		case "L":
			ll, _ := v.([]interface{})
			out := make([]interface{}, len(ll))
			for i, e := range ll {
				out[i] = avToPlain(e)
			}
			return out
		case "SS", "NS", "BS":
			return v
		}
		break
	}
	return m
}

func plainToAV(v interface{}) map[string]interface{} {
	switch t := v.(type) {
	case nil:
		return map[string]interface{}{"NULL": true}
	case string:
		return map[string]interface{}{"S": t}
	case bool:
		return map[string]interface{}{"BOOL": t}
	case float64:
		return map[string]interface{}{"N": strconv.FormatFloat(t, 'g', -1, 64)}
	case float32:
		return map[string]interface{}{"N": strconv.FormatFloat(float64(t), 'g', -1, 32)}
	case int:
		return map[string]interface{}{"N": strconv.Itoa(t)}
	case int64:
		return map[string]interface{}{"N": strconv.FormatInt(t, 10)}
	case map[string]interface{}:
		return map[string]interface{}{"M": itemToAV(t)}
	case []interface{}:
		l := make([]interface{}, len(t))
		for i, e := range t {
			l[i] = plainToAV(e)
		}
		return map[string]interface{}{"L": l}
	default:
		return map[string]interface{}{"S": fmt.Sprintf("%v", t)}
	}
}

// --- interpreters ---

func runJS(script string, r *redisHost, d *ddbHost, con *playConsole, timeout time.Duration) (interface{}, error) {
	vm := goja.New()
	// goja exposes no require/process/fs by default — only the objects we Set.
	// Build them with idiomatic lowercase JS names (Go methods keep Go names for
	// the yaegi side).
	conObj := vm.NewObject()
	_ = conObj.Set("log", con.Log)
	_ = conObj.Set("error", con.Error)
	_ = conObj.Set("table", con.Table)
	_ = vm.Set("console", conObj)
	if r != nil {
		o := vm.NewObject()
		_ = o.Set("get", r.Get)
		_ = o.Set("set", r.Set)
		_ = o.Set("del", r.Del)
		_ = o.Set("type", r.Type)
		_ = o.Set("ttl", r.TTL)
		_ = o.Set("expire", r.Expire)
		_ = o.Set("hget", r.HGet)
		_ = o.Set("hset", r.HSet)
		_ = o.Set("hgetall", r.HGetAll)
		_ = o.Set("scan", r.Scan)
		_ = o.Set("keys", r.Keys)
		_ = o.Set("command", r.Command)
		_ = vm.Set("redis", o)
	}
	if d != nil {
		o := vm.NewObject()
		_ = o.Set("listTables", d.ListTables)
		_ = o.Set("scan", d.Scan)
		_ = o.Set("scanAll", d.ScanAll)
		_ = o.Set("getItem", d.GetItem)
		_ = o.Set("putItem", d.PutItem)
		_ = o.Set("deleteItem", d.DeleteItem)
		_ = o.Set("partiql", d.PartiQL)
		_ = o.Set("call", d.Call)
		_ = vm.Set("ddb", o)
	}
	timer := time.AfterFunc(timeout, func() { vm.Interrupt("script timeout") })
	defer timer.Stop()
	v, err := vm.RunString(script)
	if err != nil {
		return nil, err
	}
	if v != nil && !goja.IsUndefined(v) && !goja.IsNull(v) {
		return v.Export(), nil
	}
	return nil, nil
}

func runGo(script string, r *redisHost, d *ddbHost, con *playConsole, timeout time.Duration) (interface{}, error) {
	// No stdlib.Symbols → the script cannot import os/net/etc. Only our packages.
	i := interp.New(interp.Options{})
	exports := interp.Exports{
		"console/console": {
			"Log":   reflect.ValueOf(con.Log),
			"Error": reflect.ValueOf(con.Error),
			"Table": reflect.ValueOf(con.Table),
		},
	}
	imports := "import \"console\"\n"
	if r != nil {
		exports["redis/redis"] = map[string]reflect.Value{
			"Get": reflect.ValueOf(r.Get), "Set": reflect.ValueOf(r.Set),
			"Del": reflect.ValueOf(r.Del), "Type": reflect.ValueOf(r.Type),
			"TTL": reflect.ValueOf(r.TTL), "Expire": reflect.ValueOf(r.Expire),
			"HGet": reflect.ValueOf(r.HGet), "HSet": reflect.ValueOf(r.HSet),
			"HGetAll": reflect.ValueOf(r.HGetAll), "Scan": reflect.ValueOf(r.Scan),
			"Keys": reflect.ValueOf(r.Keys), "Command": reflect.ValueOf(r.Command),
		}
		imports += "import \"redis\"\n"
	}
	if d != nil {
		exports["ddb/ddb"] = map[string]reflect.Value{
			"ListTables": reflect.ValueOf(d.ListTables), "Scan": reflect.ValueOf(d.Scan),
			"ScanAll": reflect.ValueOf(d.ScanAll), "GetItem": reflect.ValueOf(d.GetItem),
			"PutItem": reflect.ValueOf(d.PutItem), "DeleteItem": reflect.ValueOf(d.DeleteItem),
			"PartiQL": reflect.ValueOf(d.PartiQL), "Call": reflect.ValueOf(d.Call),
		}
		imports += "import \"ddb\"\n"
	}
	if err := i.Use(exports); err != nil {
		return nil, err
	}
	if _, err := i.Eval(imports); err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	v, err := i.EvalWithContext(ctx, script)
	if err != nil {
		return nil, err
	}
	if v.IsValid() && v.CanInterface() {
		return v.Interface(), nil
	}
	return nil, nil
}

// rm_playground_run runs one script. Request:
//
//	{kind:"redis"|"ddb", lang:"js"|"go", script, port, auth, config, timeoutMs}
//
// Response: {ok, logs[], result, error, elapsedMs}.
//
//export rm_playground_run
func rm_playground_run(in *C.char) (ret *C.char) {
	defer func() {
		if rec := recover(); rec != nil {
			ret = pgJSON(map[string]any{"ok": false, "error": fmt.Sprintf("playground panic: %v", rec)})
		}
	}()

	var req struct {
		Kind      string `json:"kind"`
		Lang      string `json:"lang"`
		Script    string `json:"script"`
		Port      int    `json:"port"`
		Auth      string `json:"auth"`
		Config    Config `json:"config"`
		TimeoutMs int    `json:"timeoutMs"`
	}
	if err := json.Unmarshal([]byte(C.GoString(in)), &req); err != nil {
		return pgJSON(map[string]any{"ok": false, "error": err.Error()})
	}

	con := &playConsole{}
	var redisH *redisHost
	var ddbH *ddbHost
	if req.Kind == "redis" {
		conn, err := respDial(fmt.Sprintf("127.0.0.1:%d", req.Port), 4*time.Second)
		if err != nil {
			return pgJSON(map[string]any{"ok": false, "error": "connect: " + err.Error()})
		}
		defer conn.close()
		if strings.TrimSpace(req.Auth) != "" {
			if _, err := conn.cmd("AUTH", req.Auth); err != nil {
				return pgJSON(map[string]any{"ok": false, "error": "auth: " + err.Error()})
			}
		}
		redisH = &redisHost{conn: conn}
	} else {
		cfg := req.Config
		ddbH = &ddbHost{cfg: &cfg}
	}

	timeout := time.Duration(req.TimeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}

	start := time.Now()
	var result interface{}
	var runErr error
	if req.Lang == "go" {
		result, runErr = runGo(req.Script, redisH, ddbH, con, timeout)
	} else {
		result, runErr = runJS(req.Script, redisH, ddbH, con, timeout)
	}
	elapsed := time.Since(start).Milliseconds()

	out := map[string]any{"ok": runErr == nil, "logs": con.lines, "elapsedMs": elapsed}
	if runErr != nil {
		out["error"] = runErr.Error()
	} else {
		out["result"] = result
	}
	return pgJSON(out)
}
