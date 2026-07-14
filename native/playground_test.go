package main

import (
	"reflect"
	"strings"
	"testing"
	"time"
)

// --- console: both interpreters collect output ---

func TestJSConsole(t *testing.T) {
	con := &playConsole{}
	if _, err := runJS(`console.log("hi", 42, {a:1})`, nil, nil, con, 2*time.Second); err != nil {
		t.Fatal(err)
	}
	if len(con.lines) != 1 || !strings.Contains(con.lines[0], "hi 42") {
		t.Errorf("JS console: %v", con.lines)
	}
}

func TestGoConsole(t *testing.T) {
	con := &playConsole{}
	if _, err := runGo(`console.Log("hi", 42)`, nil, nil, con, 2*time.Second); err != nil {
		t.Fatal(err)
	}
	if len(con.lines) != 1 || !strings.Contains(con.lines[0], "hi 42") {
		t.Errorf("Go console: %v", con.lines)
	}
}

// --- sandbox: no fs/net/os beyond the injected hosts ---

func TestJSSandbox(t *testing.T) {
	con := &playConsole{}
	// require / process / fs are not defined in a bare goja runtime.
	if _, err := runJS(`require("fs")`, nil, nil, con, 2*time.Second); err == nil {
		t.Error("JS: require should be undefined (sandbox)")
	}
	if _, err := runJS(`process.exit(0)`, nil, nil, con, 2*time.Second); err == nil {
		t.Error("JS: process should be undefined (sandbox)")
	}
}

func TestGoSandbox(t *testing.T) {
	con := &playConsole{}
	// os / net etc. are not injected (no stdlib.Symbols), so importing fails.
	if _, err := runGo(`import "os"`, nil, nil, con, 2*time.Second); err == nil {
		t.Error("Go: import \"os\" should fail (sandbox)")
	}
}

// --- timeout: a runaway loop is cancelled ---

func TestJSTimeout(t *testing.T) {
	con := &playConsole{}
	start := time.Now()
	_, err := runJS(`while(true){}`, nil, nil, con, 300*time.Millisecond)
	if err == nil {
		t.Error("JS: infinite loop should be interrupted")
	}
	if time.Since(start) > 3*time.Second {
		t.Errorf("JS timeout too slow: %v", time.Since(start))
	}
}

func TestGoTimeout(t *testing.T) {
	con := &playConsole{}
	start := time.Now()
	// A loop with a body statement (yaegi checks the context at statement
	// boundaries).
	_, err := runGo(`x := 0
for { x++ }`, nil, nil, con, 300*time.Millisecond)
	if err == nil {
		t.Error("Go: infinite loop should be cancelled")
	}
	if time.Since(start) > 3*time.Second {
		t.Errorf("Go timeout too slow: %v", time.Since(start))
	}
}

// --- attribute-value round trip ---

func TestAVRoundTrip(t *testing.T) {
	item := map[string]interface{}{
		"pk":   "user#1",
		"age":  int64(30),
		"ok":   true,
		"none": nil,
		"tags": []interface{}{"a", "b"},
		"meta": map[string]interface{}{"n": int64(5)},
	}
	av := itemToAV(item)
	// spot-check encoding
	if s := av["pk"].(map[string]interface{})["S"]; s != "user#1" {
		t.Errorf("pk encode: %v", av["pk"])
	}
	if n := av["age"].(map[string]interface{})["N"]; n != "30" {
		t.Errorf("age encode: %v", av["age"])
	}
	back := itemFromAV(av)
	if !reflect.DeepEqual(item, back) {
		t.Errorf("AV round trip:\n in =%+v\n out=%+v", item, back)
	}
}

// --- redis host result surfacing (interpreter <-> host wiring), no backend ---

func TestJSResultExport(t *testing.T) {
	con := &playConsole{}
	v, err := runJS(`const o = {x: 1, y: [2,3]}; o`, nil, nil, con, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	m, ok := v.(map[string]interface{})
	if !ok || m["x"] == nil {
		t.Errorf("JS result export: %#v", v)
	}
}

// --- live read-only check against a running proxy on :6379 (skipped if down) ---

func TestLiveRedisReadOnly(t *testing.T) {
	conn, err := respDial("127.0.0.1:6379", 1*time.Second)
	if err != nil {
		t.Skip("no proxy on :6379")
	}
	defer conn.close()
	con := &playConsole{}
	// Type of a non-existent key is a safe read (no writes to real data).
	script := `const t = redis.type("__pg_test_nonexistent_key__"); console.log("type=" + t)`
	if _, err := runJS(script, &redisHost{conn: conn}, nil, con, 3*time.Second); err != nil {
		t.Fatalf("live redis JS: %v", err)
	}
	if len(con.lines) == 0 || !strings.Contains(con.lines[0], "type=") {
		t.Errorf("live redis output: %v", con.lines)
	}
}
