package main

import (
	"bytes"
	"compress/flate"
	"compress/gzip"
	"compress/zlib"
	"strings"
	"testing"

	"github.com/andybalholm/brotli"
	"github.com/vmihailenco/msgpack/v5"
)

func gz(b []byte) []byte {
	var buf bytes.Buffer
	w := gzip.NewWriter(&buf)
	w.Write(b)
	w.Close()
	return buf.Bytes()
}

func zl(b []byte) []byte {
	var buf bytes.Buffer
	w := zlib.NewWriter(&buf)
	w.Write(b)
	w.Close()
	return buf.Bytes()
}

func fl(b []byte) []byte {
	var buf bytes.Buffer
	w, _ := flate.NewWriter(&buf, flate.DefaultCompression)
	w.Write(b)
	w.Close()
	return buf.Bytes()
}

func br(b []byte) []byte {
	var buf bytes.Buffer
	w := brotli.NewWriter(&buf)
	w.Write(b)
	w.Close()
	return buf.Bytes()
}

func TestDetect(t *testing.T) {
	json := []byte(`{"a":1,"b":[2,3]}`)
	cases := []struct {
		name string
		in   []byte
		want string
	}{
		{"empty", []byte(``), fmtText},
		{"plaintext", []byte(`hello world`), fmtText},
		{"json", json, fmtJSON},
		{"gzip", gz(json), fmtGzip},
		{"deflate", zl(json), fmtDeflate},
		{"brotli", br(json), fmtBrotli},
		{"numberString", []byte(`123456`), fmtText}, // not protobuf (numeric guard)
	}
	for _, c := range cases {
		if got := detectFormat(c.in); got != c.want {
			t.Errorf("%s: detect=%q want %q", c.name, got, c.want)
		}
	}
}

func TestGzipRoundTrip(t *testing.T) {
	src := []byte(`{"msg":"héllo","n":42}`)
	text, _, err := decodeAs(fmtGzip, gz(src))
	if err != nil {
		t.Fatalf("gzip decode err: %v", err)
	}
	// gzipped JSON should render as pretty JSON containing the key.
	if !strings.Contains(text, `"msg"`) || !strings.Contains(text, "héllo") {
		t.Errorf("gzip->json unexpected: %q", text)
	}
}

func TestDeflateAndRaw(t *testing.T) {
	src := []byte("plain deflate payload 12345")
	if text, _, err := decodeAs(fmtDeflate, zl(src)); err != nil || !strings.Contains(text, "plain deflate") {
		t.Errorf("deflate: %q err=%v", text, err)
	}
	if text, _, err := decodeAs(fmtDeflateRaw, fl(src)); err != nil || !strings.Contains(text, "plain deflate") {
		t.Errorf("deflateRaw: %q err=%v", text, err)
	}
}

func TestMsgpack(t *testing.T) {
	m := map[string]interface{}{"id": 7, "name": "abc"}
	b, err := msgpack.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	if !isMsgpack(b) {
		t.Errorf("isMsgpack false for a map")
	}
	text, _, derr := decodeAs(fmtMsgpack, b)
	if derr != nil || !strings.Contains(text, `"name"`) || !strings.Contains(text, "abc") {
		t.Errorf("msgpack decode: %q err=%v", text, derr)
	}
}

func TestPHPSerialize(t *testing.T) {
	// a:2:{s:3:"foo";s:3:"bar";i:0;i:42;}
	php := []byte(`a:2:{s:3:"foo";s:3:"bar";i:0;i:42;}`)
	if !isPHPSerialize(php) {
		t.Errorf("isPHPSerialize false")
	}
	text, _, err := decodeAs(fmtPHPSerialize, php)
	if err != nil || !strings.Contains(text, "foo") || !strings.Contains(text, "bar") {
		t.Errorf("php decode: %q err=%v", text, err)
	}
}

func TestJSONPretty(t *testing.T) {
	text, _, _ := decodeAs(fmtJSON, []byte(`{"b":2,"a":1}`))
	if !strings.Contains(text, "\n    \"") { // 4-space indent
		t.Errorf("json not 4-space indented: %q", text)
	}
	// big int preserved (not turned into 1e19)
	big, _, _ := decodeAs(fmtJSON, []byte(`{"n":12345678901234567890}`))
	if !strings.Contains(big, "12345678901234567890") {
		t.Errorf("big int lost: %q", big)
	}
}

func TestHexAndBinary(t *testing.T) {
	in := []byte{0x00, 'A', 0xff}
	hexv, _, _ := decodeAs(fmtHex, in)
	if hexv != `\x00A\xff` {
		t.Errorf("hex escape: %q", hexv)
	}
	binv, _, _ := decodeAs(fmtBinary, []byte{0x01})
	if binv != "00000001" {
		t.Errorf("binary: %q", binv)
	}
}

func TestHumanFileSize(t *testing.T) {
	cases := map[int]string{0: "0", 512: "512B", 1536: "1.5KB", 20971520: "20MB"}
	for in, want := range cases {
		if got := humanFileSize(in); got != want {
			t.Errorf("humanFileSize(%d)=%q want %q", in, got, want)
		}
	}
}

func TestBufVisible(t *testing.T) {
	if !bufVisible([]byte("héllo")) {
		t.Errorf("utf8 should be visible")
	}
	if bufVisible([]byte{0xff, 0xfe, 0x00}) {
		t.Errorf("invalid utf8 should be non-visible")
	}
}

func TestProtobufWalk(t *testing.T) {
	// field 1, varint 150  =>  0x08 0x96 0x01
	fields, err := protoWalk([]byte{0x08, 0x96, 0x01}, 0)
	if err != nil || len(fields) != 1 || fields[0].Field != 1 || fields[0].Value.(uint64) != 150 {
		t.Errorf("protoWalk: %+v err=%v", fields, err)
	}
}

// --- DoS-guard regression tests (from the adversarial review) ---

func TestProtobufDepthCap(t *testing.T) {
	// A deeply-nested length-delimited chain must NOT stack-overflow: build
	// field-1 BytesType nested far past protoMaxDepth and confirm it returns
	// (the top level renders the too-deep inner as bytes/string, no crash).
	inner := []byte{0x08, 0x01} // field 1 varint 1
	for i := 0; i < protoMaxDepth+50; i++ {
		// wrap: field 1, BytesType(inner)
		hdr := []byte{0x0a, byte(len(inner))}
		if len(inner) > 127 {
			t.Skip("inner grew beyond 1-byte length for this simple wrapper")
		}
		inner = append(hdr, inner...)
	}
	fields, err := protoWalk(inner, 0)
	if err != nil {
		t.Fatalf("protoWalk returned error instead of bounded result: %v", err)
	}
	if len(fields) == 0 {
		t.Errorf("expected some fields")
	}
}

func TestMsgpackValidateRejectsHugeMap(t *testing.T) {
	// map32 declaring 0xffffffff entries in 5 bytes — the prealloc DoS. Validator
	// must reject WITHOUT allocating, and isMsgpack/decodeMsgpack must be safe.
	bomb := []byte{0xdf, 0xff, 0xff, 0xff, 0xff}
	if msgpackValidate(bomb, msgpackMaxDepth) {
		t.Errorf("validator accepted an over-length map32 header")
	}
	if isMsgpack(bomb) {
		t.Errorf("isMsgpack accepted the bomb")
	}
	if _, _, err := decodeMsgpack(bomb); err == nil {
		t.Errorf("decodeMsgpack should error on the bomb")
	}
}

func TestMsgpackValidateRejectsDeepNesting(t *testing.T) {
	// A chain of fixarray-1 far deeper than msgpackMaxDepth must be rejected.
	var deep []byte
	for i := 0; i < msgpackMaxDepth+50; i++ {
		deep = append(deep, 0x91) // fixarray with 1 element
	}
	deep = append(deep, 0x01) // final scalar
	if msgpackValidate(deep, msgpackMaxDepth) {
		t.Errorf("validator accepted nesting past the depth cap")
	}
}

func TestMsgpackValidateAcceptsGoodValue(t *testing.T) {
	m := map[string]interface{}{"a": 1, "b": []interface{}{2, 3}}
	b, _ := msgpack.Marshal(m)
	if !msgpackValidate(b, msgpackMaxDepth) {
		t.Errorf("validator rejected a well-formed value")
	}
}

func TestTruncateUTF8(t *testing.T) {
	// Must not split a multibyte rune.
	s := "aé"                     // 'a'(1) + 'é'(2 bytes)
	if got := truncateUTF8(s, 2); got != "a" {
		t.Errorf("truncateUTF8 split a rune: %q", got)
	}
	if got := truncateUTF8("abc", 10); got != "abc" {
		t.Errorf("truncateUTF8 shortened a short string: %q", got)
	}
}

func TestDecodeJSONErrors(t *testing.T) {
	if _, _, err := decodeJSON([]byte(`not json`)); err == nil {
		t.Errorf("decodeJSON should error on non-JSON")
	}
	if _, _, err := decodeJSON([]byte(`{"a":1} trailing`)); err == nil {
		t.Errorf("decodeJSON should reject trailing data")
	}
	if _, _, err := decodeJSON([]byte(`{"a":1}`)); err != nil {
		t.Errorf("decodeJSON should accept clean JSON: %v", err)
	}
}

func TestTextEditableOnlyUTF8(t *testing.T) {
	if _, editable, _ := decodeAs(fmtText, []byte("hello")); !editable {
		t.Errorf("valid UTF-8 Text should be editable")
	}
	if _, editable, _ := decodeAs(fmtText, []byte{0xff, 0xfe}); editable {
		t.Errorf("non-UTF-8 Text must be read-only")
	}
}

func TestShellSplit(t *testing.T) {
	toks, err := shellSplit(`--value "{VALUE}" --hex {HEX}`)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"--value", "{VALUE}", "--hex", "{HEX}"}
	if len(toks) != len(want) {
		t.Fatalf("tokens=%v", toks)
	}
	for i := range want {
		if toks[i] != want[i] {
			t.Errorf("token %d = %q want %q", i, toks[i], want[i])
		}
	}
	// a value with spaces stays ONE token (no shell splitting of substituted value)
	if _, err := shellSplit(`"unterminated`); err == nil {
		t.Errorf("expected unterminated-quote error")
	}
}
