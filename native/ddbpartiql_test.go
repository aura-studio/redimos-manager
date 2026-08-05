package main

import (
	"strings"
	"testing"
)

// The PartiQL AWS read-only guard must refuse non-SELECT statements before any
// network call, so these tests run fully offline — no test dials out. The
// exec-path tests (reject/empty) stop at the guard itself, and
// TestPartiqlGuardPredicate covers the rule matrix (SELECTs pass, writes are
// blocked, non-AWS endpoints are never gated) against the extracted predicate.

func TestPartiqlAwsRejectsWrites(t *testing.T) {
	writes := []string{
		`INSERT INTO t VALUE {'id': '1'}`,
		`UPDATE t SET a = 'x' WHERE id = '1'`,
		`DELETE FROM t WHERE id = '1'`,
		`DROP TABLE t`,
		// leading whitespace / lowercase keyword must still be caught
		"  delete from t where id = '1'",
	}
	endpoints := []string{
		"",                                        // default AWS resolver
		"https://dynamodb.us-east-1.amazonaws.com", // explicit AWS host
	}
	for _, ep := range endpoints {
		for _, stmt := range writes {
			res := partiqlExec(&partiqlReq{
				Config:    Config{Endpoint: ep, Table: "t"},
				Statement: stmt,
			})
			if res["ok"] != false {
				t.Errorf("ep=%q stmt=%q: expected ok=false", ep, stmt)
				continue
			}
			errMsg, _ := res["error"].(string)
			if !strings.Contains(errMsg, "read-only") {
				t.Errorf("ep=%q stmt=%q: expected read-only refusal, got %q", ep, stmt, errMsg)
			}
		}
	}
}

// TestPartiqlGuardPredicate exercises the guard rule itself, fully offline:
// (endpoint, statement) → blocked? Covers both directions — AWS endpoints
// refuse every non-SELECT (any keyword case, leading whitespace), and pass
// SELECTs through; non-AWS endpoints are never gated, whatever the statement.
func TestPartiqlGuardPredicate(t *testing.T) {
	cases := []struct {
		endpoint string
		stmt     string
		blocked  bool
	}{
		// AWS (default resolver = empty endpoint)
		{"", "SELECT * FROM t", false},
		{"", "select * from t", false},
		{"", "  select * from t", false},
		{"", "DELETE FROM t WHERE id = '1'", true},
		{"", "INSERT INTO t VALUE {'id': '1'}", true},
		{"", "  delete from t", true},
		{"", "DROP TABLE t", true},
		// AWS (explicit amazonaws.com URL)
		{"https://dynamodb.us-east-1.amazonaws.com", "SELECT * FROM t", false},
		{"https://dynamodb.us-east-1.amazonaws.com", "UPDATE t SET a = 'x'", true},
		{"https://dynamodb.cn-north-1.amazonaws.com.cn", "DELETE FROM t", true},
		// Non-AWS endpoints are never gated (the guard is an AWS-only wall)
		{"http://localhost:8000", "DELETE FROM t WHERE id = '1'", false},
		{"http://localhost:8000", "SELECT * FROM t", false},
		{"http://127.0.0.1:4566", "DROP TABLE t", false},
	}
	for _, c := range cases {
		if got := partiqlAwsBlocked(c.endpoint, c.stmt); got != c.blocked {
			t.Errorf("partiqlAwsBlocked(%q, %q) = %v, want %v", c.endpoint, c.stmt, got, c.blocked)
		}
	}
}

func TestPartiqlEmptyStatement(t *testing.T) {
	res := partiqlExec(&partiqlReq{
		Config:    Config{Endpoint: "http://localhost:8000", Table: "t"},
		Statement: "   ",
	})
	if res["ok"] != false {
		t.Error("empty statement: expected ok=false")
	}
}
