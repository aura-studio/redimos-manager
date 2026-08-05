package main

import (
	"fmt"
	"strings"
	"testing"
)

// readyzBody renders a /readyz body exactly the way cmd/redimos does (fmt.Fprintf
// with %q, NOT encoding/json), so these tests exercise the real wire shape —
// including the escaping quirks %q brings with it — rather than a JSON-marshalled
// idealisation of it that could never fail the way the real one can.
func readyzBody(ready bool, backendErr string) string {
	return fmt.Sprintf(
		`{"ready":%t,"backend_healthy":%t,"backend_error":%q,`+
			`"lazy_delete_queue_depth":%d,"lazy_delete_dropped":%d,"lazy_delete_failures":%d,`+
			`"lazy_delete_islive_errors":%d,`+
			`"orphan_sweep_runs":%d,"orphan_sweep_failures":%d,"rmw_exhausted":%d,"large_key_interceptions":%d}`+"\n",
		ready, ready, backendErr, 0, 0, 0, 0, 0, 0, 0, 0)
}

func TestReadyzBackendError(t *testing.T) {
	awsErr := "operation error DynamoDB: GetItem, https response error StatusCode: 400, " +
		"RequestID: ABC123, api error ResourceNotFoundException: Requested resource not found"

	cases := []struct {
		name string
		body string
		want string
	}{
		{
			// The case the whole feature exists for: a 503 body carrying the cause.
			name: "degraded body yields the cause",
			body: readyzBody(false, awsErr),
			want: awsErr,
		},
		{
			// A ready proxy reports an empty backend_error itself, so "no cause" needs
			// no special path — it falls out of the same parse.
			name: "ready body yields no cause",
			body: readyzBody(true, ""),
			want: "",
		},
		{
			// A redimos too old to publish the field must degrade, not error.
			name: "older redimos without the field",
			body: `{"ready":false,"lazy_delete_queue_depth":0}`,
			want: "",
		},
		{
			// probe() returns "" when the endpoint never answered.
			name: "empty body",
			body: "",
			want: "",
		},
		{
			name: "plain-text body from some other responder",
			body: "ok",
			want: "",
		},
		{
			name: "html error page from a proxy in between",
			body: "<html><body>503 Service Unavailable</body></html>",
			want: "",
		},
		{
			// backend_error present but not a string — must not panic or coerce.
			name: "wrong field type",
			body: `{"backend_error":42}`,
			want: "",
		},
		{
			name: "truncated body from the read cap",
			body: `{"ready":false,"backend_error":"half a mes`,
			want: "",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := readyzBackendError(c.body); got != c.want {
				t.Errorf("readyzBackendError(%q)\n got %q\nwant %q", c.body, got, c.want)
			}
		})
	}
}

// The documented %q-vs-JSON hazard, pinned as a test so the tolerant parse is
// known to be load-bearing rather than defensive boilerplate. Go's %q escapes a
// control byte as \x01, which is not a JSON escape — so redimos can emit a body
// that no JSON parser accepts. The contract is that this costs the cause string
// and nothing else; the caller keeps the health signal that came with it.
func TestReadyzBackendError_UnparseableQuoteEscape(t *testing.T) {
	body := readyzBody(false, "backend said \x01 boom")
	if !strings.Contains(body, `\x01`) {
		t.Fatalf("premise broken: %%q no longer emits \\x01 — body=%q", body)
	}
	if got := readyzBackendError(body); got != "" {
		t.Errorf("want %q (degrade to no cause), got %q", "", got)
	}
}

func TestReadyzBackendError_Truncates(t *testing.T) {
	long := strings.Repeat("e", maxBackendErrLen+50)
	got := readyzBackendError(readyzBody(false, long))
	if want := strings.Repeat("e", maxBackendErrLen) + "…"; got != want {
		t.Errorf("got %d chars (%q…), want the %d-char cap plus an ellipsis", len(got), got[:20], maxBackendErrLen)
	}
}

// A cap applied to a byte length must not split a multibyte rune: the result is
// handed to encoding/json and then to a Dart string, and a severed rune would
// surface as U+FFFD in the tooltip.
func TestReadyzBackendError_TruncatesOnRuneBoundary(t *testing.T) {
	// 3 bytes per rune, so the cap lands mid-rune rather than on a boundary.
	got := readyzBackendError(readyzBody(false, strings.Repeat("表", maxBackendErrLen)))
	for i, r := range got {
		if r == '�' {
			t.Fatalf("severed rune at byte %d: %q", i, got)
		}
	}
	if !strings.HasSuffix(got, "…") {
		t.Errorf("want a truncation marker, got %q", got)
	}
}
