// Value formatter / serialization viewer — the native half of the Browser's
// ARDM-style format dropdown. Given a redis value's exact bytes (base64 in, so
// the boundary is binary-safe), it either auto-detects the most likely encoding
// or decodes as a caller-chosen format, and returns a human-readable string plus
// display metadata (size, printable, which format was auto-picked).
//
// This reimplements the format set and auto-detect ORDER of Another Redis Desktop
// Manager (Text, Hex, Json, Binary, Msgpack, PHPSerialize, JavaSerialize, Pickle,
// Brotli, Gzip, Deflate, DeflateRaw, Protobuf) plus user-defined "custom"
// formatters. The decoders are Go-native (no Electron/Node); the hard formats
// (Pickle, JavaSerialize, Protobuf-without-schema) are decode-only best-effort,
// matching ARDM's read-only stance for those.
//
// Custom formatters run an external program, but — unlike ARDM, which string-
// interpolates the raw value into a `/bin/sh -c` command (a shell-injection sink
// for hostile redis data) — this passes {VALUE}/{HEX}/… as whole argv tokens to
// exec.CommandContext with NO shell, so a value can never break out into a command.

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"bytes"
	"compress/flate"
	"compress/gzip"
	"compress/zlib"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/andybalholm/brotli"
	"github.com/elliotchance/phpserialize"
	"github.com/nlpodyssey/gopickle/pickle"
	"github.com/vmihailenco/msgpack/v5"
	"google.golang.org/protobuf/encoding/protowire"
)

// Format names (must match the Dart dropdown labels exactly).
const (
	fmtText         = "Text"
	fmtHex          = "Hex"
	fmtJSON         = "Json"
	fmtBinary       = "Binary"
	fmtMsgpack      = "Msgpack"
	fmtPHPSerialize = "PHPSerialize"
	fmtJavaSerial   = "JavaSerialize"
	fmtPickle       = "Pickle"
	fmtBrotli       = "Brotli"
	fmtGzip         = "Gzip"
	fmtDeflate      = "Deflate"
	fmtDeflateRaw   = "DeflateRaw"
	fmtProtobuf     = "Protobuf"
)

// oversizeBytes mirrors ARDM's 20MB cap: past this we don't decode, just show a
// truncated Text preview so a huge value can't freeze the UI.
const oversizeBytes = 20 * 1024 * 1024

// oversizePreview is how many bytes of an oversize value we actually render.
const oversizePreview = 20000

// protoMaxDepth caps schema-less protobuf nesting so a crafted deeply-nested
// message can't blow the goroutine stack (mirrors protowire.DefaultRecursionLimit).
const protoMaxDepth = 100

// msgpackMaxDepth caps msgpack nesting. The library has no recursion limit, so a
// crafted deeply-nested value would blow the stack; we reject past this depth in a
// non-recursive pre-validator before the library's recursive decode runs.
const msgpackMaxDepth = 100

type formatResp struct {
	OK        bool   `json:"ok"`
	Text      string `json:"text"`
	Detected  string `json:"detected,omitempty"`
	Size      int    `json:"size"`
	SizeHuman string `json:"sizeHuman"`
	Printable bool   `json:"printable"`
	Editable  bool   `json:"editable"`
	Error     string `json:"error,omitempty"`
}

func fmtJSONReturn(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		b = []byte(`{"ok":false,"error":"marshal failed"}`)
	}
	return C.CString(string(b))
}

// rm_format decodes one value for display. Request: {format, valueB64}. When
// format is "" or "Auto" the encoding is auto-detected (returned in `detected`).
//
//export rm_format
func rm_format(in *C.char) (ret *C.char) {
	// A decoder run on hostile/malformed redis bytes must never abort the app
	// (this dylib runs in-process). Any panic escaping a cgo export kills the
	// process, so convert it to an error result. (Cannot catch a stack-overflow
	// or OOM — those are bounded separately below and in the decoders.)
	defer func() {
		if r := recover(); r != nil {
			ret = fmtJSONReturn(formatResp{OK: false, Error: fmt.Sprintf("decoder panic: %v", r)})
		}
	}()

	var req struct {
		Format   string `json:"format"`
		ValueB64 string `json:"valueB64"`
	}
	if err := json.Unmarshal([]byte(C.GoString(in)), &req); err != nil {
		return fmtJSONReturn(formatResp{OK: false, Error: err.Error()})
	}
	raw, err := base64.StdEncoding.DecodeString(req.ValueB64)
	if err != nil {
		return fmtJSONReturn(formatResp{OK: false, Error: "bad base64: " + err.Error()})
	}

	resp := formatResp{
		Size:      len(raw),
		SizeHuman: humanFileSize(len(raw)),
		Printable: bufVisible(raw),
	}

	format := req.Format
	if format == "" || format == "Auto" {
		format = detectFormat(raw)
	}
	// ARDM disables the format selector for oversize values; do the same — force
	// Text and render only a bounded preview so a 100MB/512MB value can't be
	// marshaled, shipped, and laid out (and can't be Saved back truncated).
	oversize := len(raw) > oversizeBytes
	if oversize {
		format = fmtText
	}
	resp.Detected = format

	text, editable, derr := decodeAs(format, raw)
	if oversize {
		text = truncateUTF8(text, oversizePreview) +
			fmt.Sprintf("\n\n… (truncated; value is %s, showing first %d chars)",
				humanFileSize(len(raw)), oversizePreview)
		editable = false
	}
	resp.Text = text
	resp.Editable = editable
	if derr != nil {
		resp.OK = false
		resp.Error = derr.Error()
	} else {
		resp.OK = true
	}
	return fmtJSONReturn(resp)
}

// truncateUTF8 returns the first n bytes of s trimmed back to a valid UTF-8
// boundary (so a multibyte rune is never split).
func truncateUTF8(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

// decodeAs renders raw bytes as the named format. Returns (displayText, editable,
// err). On a decode failure it returns a friendly message as displayText AND the
// error (the caller shows the message; ARDM shows "<Fmt> Parse Failed!").
func decodeAs(format string, raw []byte) (string, bool, error) {
	switch format {
	case fmtText:
		// Editable only when the bytes are valid UTF-8: the JSON return would
		// mojibake invalid bytes (→ U+FFFD), so saving the Text view of a binary
		// value would corrupt it. Non-UTF-8 → read-only (view it as Hex instead).
		return string(raw), utf8.Valid(raw), nil
	case fmtHex:
		return bufToHexEscaped(raw), true, nil
	case fmtBinary:
		return bufToBinary(raw), true, nil
	case fmtJSON:
		return decodeJSON(raw)
	case fmtMsgpack:
		return decodeMsgpack(raw)
	case fmtPHPSerialize:
		return decodePHP(raw)
	case fmtJavaSerial:
		return decodeJava(raw)
	case fmtPickle:
		return decodePickle(raw)
	case fmtBrotli:
		return decodeCompressed(raw, fmtBrotli)
	case fmtGzip:
		return decodeCompressed(raw, fmtGzip)
	case fmtDeflate:
		return decodeCompressed(raw, fmtDeflate)
	case fmtDeflateRaw:
		return decodeCompressed(raw, fmtDeflateRaw)
	case fmtProtobuf:
		return decodeProtobuf(raw)
	default:
		// Unknown / custom names fall back to raw text so the UI never blanks.
		return string(raw), utf8.Valid(raw), nil
	}
}

// -------------------------------------------------------------------------
// Auto-detect chain — same ORDER as ARDM's FormatViewer.autoFormat(). First
// match wins. Structured formats are tried BEFORE the codecs, and DeflateRaw
// (which accepts almost any input) is tried last of all so it can't shadow a
// more specific match.
// -------------------------------------------------------------------------

func detectFormat(b []byte) string {
	if len(b) == 0 {
		return fmtText
	}
	if len(b) > oversizeBytes {
		return fmtText
	}
	if isJSONObject(b) {
		return fmtJSON
	}
	if isPHPSerialize(b) {
		return fmtPHPSerialize
	}
	if isJavaSerialize(b) {
		return fmtJavaSerial
	}
	if isPickle(b) {
		return fmtPickle
	}
	if isMsgpack(b) {
		return fmtMsgpack
	}
	if isBrotli(b) {
		return fmtBrotli
	}
	if isGzip(b) {
		return fmtGzip
	}
	if isDeflate(b) {
		return fmtDeflate
	}
	if isProtobuf(b) {
		return fmtProtobuf
	}
	if isDeflateRaw(b) {
		return fmtDeflateRaw
	}
	if !bufVisible(b) {
		return fmtHex
	}
	return fmtText
}

// isJSONObject: valid JSON whose top value is an object or array (ARDM rejects a
// bare scalar here so plain numbers/strings stay Text).
func isJSONObject(b []byte) bool {
	t := bytes.TrimSpace(b)
	if len(t) == 0 || (t[0] != '{' && t[0] != '[') {
		return false
	}
	return json.Valid(t)
}

// isPHPSerialize: matches PHP's serialize() grammar prefix, then confirms with a
// real decode so a coincidental "a:" text isn't a false positive.
func isPHPSerialize(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	s := string(b)
	if s == "N;" {
		return true
	}
	if len(s) < 2 || s[1] != ':' {
		return false
	}
	switch s[0] {
	case 'b', 'i', 'd', 's', 'a', 'O', 'C', 'R', 'r':
		_, _, err := decodePHP(b)
		return err == nil
	}
	return false
}

// isJavaSerialize: Java Object Serialization Stream magic AC ED 00 05.
func isJavaSerialize(b []byte) bool {
	return len(b) >= 4 && b[0] == 0xAC && b[1] == 0xED && b[2] == 0x00 && b[3] == 0x05
}

// isPickle: protocol >=2 starts with PROTO (0x80) + a version byte and ends with
// STOP ('.'); confirm with a real parse (pickle detection is false-positive
// prone, so a bare heuristic isn't enough).
func isPickle(b []byte) bool {
	if len(b) < 2 {
		return false
	}
	if b[0] != 0x80 || b[len(b)-1] != '.' {
		return false
	}
	_, _, err := decodePickle(b)
	return err == nil
}

// isMsgpack: plausible first byte AND a full decode that yields a container or
// string (a lone int would be too greedy).
func isMsgpack(b []byte) bool {
	if len(b) == 0 || b[0] == 0xc1 { // 0xc1 is never valid msgpack
		return false
	}
	// Structurally validate first: this rejects a header declaring more elements
	// than the buffer can hold (the prealloc DoS) and pathological nesting (the
	// stack-overflow DoS), and guarantees exactly one value consuming the whole
	// buffer — so the recursive library decode below is safe and trailing-garbage
	// free.
	if !msgpackValidate(b, msgpackMaxDepth) {
		return false
	}
	dec := msgpack.NewDecoder(bytes.NewReader(b))
	dec.UseLooseInterfaceDecoding(true)
	v, err := dec.DecodeInterface()
	if err != nil {
		return false
	}
	// Require a container to accept, which keeps ordinary short ASCII (fixstr /
	// positive-fixint ranges overlap ASCII) from auto-detecting as Msgpack.
	switch v.(type) {
	case map[string]interface{}, []interface{}:
		return true
	default:
		return false
	}
}

// msgpackValidate does a NON-recursive structural pass over a msgpack value to
// bound the two failure modes the library's recursive decode is vulnerable to:
// (1) a container header declaring more elements than the remaining bytes can
// possibly hold (each sub-value needs >=1 byte) — the make(map,n) prealloc DoS;
// and (2) nesting deeper than maxDepth — the stack-overflow DoS. Returns true
// only for exactly one well-formed value that consumes the whole buffer within
// those limits, after which the library decode is safe.
func msgpackValidate(b []byte, maxDepth int) bool {
	stack := []int{1} // remaining sub-values to read at each open container level
	i := 0
	readUint := func(n int) (int, bool) {
		if i+n > len(b) {
			return 0, false
		}
		v := 0
		for k := 0; k < n; k++ {
			v = v<<8 | int(b[i+k])
		}
		i += n
		return v, true
	}
	skip := func(n int) bool {
		if n < 0 || i+n > len(b) {
			return false
		}
		i += n
		return true
	}
	push := func(items int) bool {
		// each sub-value needs >=1 byte, so a count exceeding the remaining bytes
		// is malformed/hostile — reject before anything allocates.
		if items < 0 || items > len(b)-i {
			return false
		}
		if items > 0 {
			stack = append(stack, items)
		}
		return true
	}
	for {
		for len(stack) > 0 && stack[len(stack)-1] == 0 {
			stack = stack[:len(stack)-1]
		}
		if len(stack) == 0 {
			return i == len(b) // one top-level value, no trailing bytes
		}
		if len(stack) > maxDepth+1 || i >= len(b) {
			return false
		}
		stack[len(stack)-1]--
		c := b[i]
		i++
		switch {
		case c <= 0x7f, c >= 0xe0: // positive / negative fixint
		case c >= 0x80 && c <= 0x8f: // fixmap
			if !push(2 * int(c&0x0f)) {
				return false
			}
		case c >= 0x90 && c <= 0x9f: // fixarray
			if !push(int(c & 0x0f)) {
				return false
			}
		case c >= 0xa0 && c <= 0xbf: // fixstr
			if !skip(int(c & 0x1f)) {
				return false
			}
		case c == 0xc0, c == 0xc2, c == 0xc3: // nil / false / true
		case c == 0xc1: // never valid
			return false
		case c == 0xc4, c == 0xc5, c == 0xc6: // bin 8/16/32
			n, ok := readUint(1 << (c - 0xc4))
			if !ok || !skip(n) {
				return false
			}
		case c == 0xc7, c == 0xc8, c == 0xc9: // ext 8/16/32
			n, ok := readUint(1 << (c - 0xc7))
			if !ok || !skip(1+n) { // 1 type byte + payload
				return false
			}
		case c == 0xca: // float32
			if !skip(4) {
				return false
			}
		case c == 0xcb: // float64
			if !skip(8) {
				return false
			}
		case c >= 0xcc && c <= 0xcf: // uint 8/16/32/64
			if !skip(1 << (c - 0xcc)) {
				return false
			}
		case c >= 0xd0 && c <= 0xd3: // int 8/16/32/64
			if !skip(1 << (c - 0xd0)) {
				return false
			}
		case c >= 0xd4 && c <= 0xd8: // fixext 1/2/4/8/16
			if !skip(1 + (1 << (c - 0xd4))) { // 1 type byte + fixed payload
				return false
			}
		case c == 0xd9, c == 0xda, c == 0xdb: // str 8/16/32
			n, ok := readUint(1 << (c - 0xd9))
			if !ok || !skip(n) {
				return false
			}
		case c == 0xdc, c == 0xdd: // array 16/32
			n, ok := readUint(2 << (c - 0xdc))
			if !ok || !push(n) {
				return false
			}
		case c == 0xde, c == 0xdf: // map 16/32
			n, ok := readUint(2 << (c - 0xde))
			if !ok || !push(2*n) {
				return false
			}
		default:
			return false
		}
	}
}

func isBrotli(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	out, err := brotliDecode(b)
	return err == nil && len(out) > 0
}

func isGzip(b []byte) bool {
	return len(b) >= 3 && b[0] == 0x1f && b[1] == 0x8b && b[2] == 0x08
}

// isDeflate: zlib/RFC1950 wrapper — 2-byte header where (CMF<<8|FLG) % 31 == 0
// and CM (low nibble of CMF) == 8; confirm by inflating.
func isDeflate(b []byte) bool {
	if len(b) < 2 || b[0]&0x0f != 0x08 {
		return false
	}
	if (uint16(b[0])<<8|uint16(b[1]))%31 != 0 {
		return false
	}
	_, err := zlibDecode(b)
	return err == nil
}

// isDeflateRaw: raw RFC1951 with no header — accepts almost anything, so it is
// LAST in the chain. Require a non-empty inflate that isn't itself printable
// text (else plain text would match).
func isDeflateRaw(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	out, err := flateDecode(b)
	if err != nil || len(out) == 0 {
		return false
	}
	return true
}

// isProtobuf: schema-less wire-format walk succeeds, with ARDM's guards — reject
// buffers that look like a plain number, and reject a decode whose first field is
// a tiny float (a sign of mis-parse).
func isProtobuf(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	if _, err := strconv.ParseFloat(strings.TrimSpace(string(b)), 64); err == nil {
		return false // numeric-looking string, not protobuf
	}
	fields, err := protoWalk(b, 0)
	if err != nil || len(fields) == 0 {
		return false
	}
	return true
}

// -------------------------------------------------------------------------
// Decoders
// -------------------------------------------------------------------------

func decodeJSON(b []byte) (string, bool, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber() // keep big ints exact
	var v interface{}
	if err := dec.Decode(&v); err != nil {
		return "Json parse failed!", true, err
	}
	// Reject trailing bytes after the first value so `{...} garbage` (or two
	// concatenated values) isn't silently shown as just the first one.
	if _, err := dec.Token(); err != io.EOF {
		return "Json parse failed!", true, errors.New("trailing data after JSON value")
	}
	return prettyJSON(v), true, nil
}

func decodeMsgpack(b []byte) (string, bool, error) {
	// Same DoS guard as isMsgpack before the recursive library decode.
	if !msgpackValidate(b, msgpackMaxDepth) {
		return "Msgpack decode failed!", true, errors.New("invalid or unsafe msgpack")
	}
	dec := msgpack.NewDecoder(bytes.NewReader(b))
	dec.UseLooseInterfaceDecoding(true)
	v, err := dec.DecodeInterface()
	if err != nil {
		return "Msgpack decode failed!", true, err
	}
	return prettyJSON(normalize(v)), true, nil
}

func decodePHP(b []byte) (string, bool, error) {
	s := string(b)
	if s == "N;" {
		return "null", true, nil
	}
	if len(s) < 2 {
		return "PHP unserialize failed!", true, errors.New("too short")
	}
	switch s[0] {
	case 'a', 'O':
		m, err := phpserialize.UnmarshalAssociativeArray(b)
		if err != nil {
			return "PHP unserialize failed!", true, err
		}
		return prettyJSON(normalize(m)), true, nil
	case 's':
		v, err := phpserialize.UnmarshalString(b)
		if err != nil {
			return "PHP unserialize failed!", true, err
		}
		return prettyJSON(v), true, nil
	case 'i':
		v, err := phpserialize.UnmarshalInt(b)
		if err != nil {
			return "PHP unserialize failed!", true, err
		}
		return strconv.FormatInt(v, 10), true, nil
	case 'd':
		v, err := phpserialize.UnmarshalFloat(b)
		if err != nil {
			return "PHP unserialize failed!", true, err
		}
		return strconv.FormatFloat(v, 'g', -1, 64), true, nil
	case 'b':
		v, err := phpserialize.UnmarshalBool(b)
		if err != nil {
			return "PHP unserialize failed!", true, err
		}
		return strconv.FormatBool(v), true, nil
	}
	return "PHP unserialize failed!", true, errors.New("unrecognized PHP serialize prefix")
}

func decodePickle(b []byte) (string, bool, error) {
	u := pickle.NewUnpickler(bytes.NewReader(b))
	v, err := u.Load()
	if err != nil {
		return "Pickle parse failed!", false, err
	}
	return prettyJSON(normalize(v)), false, nil // read-only
}

func decodeJava(b []byte) (string, bool, error) {
	// Go has no complete Java Object Serialization reader. Confirm the stream
	// header and surface a best-effort structural summary; keep it read-only.
	if !isJavaSerialize(b) {
		return "Not a Java serialization stream (missing AC ED 00 05 magic).", false,
			errors.New("bad java magic")
	}
	summary := javaSummary(b)
	return summary, false, nil
}

// decodeCompressed inflates then shows the payload as pretty JSON when it is JSON,
// else as its raw string.
func decodeCompressed(b []byte, which string) (string, bool, error) {
	var (
		out []byte
		err error
	)
	switch which {
	case fmtBrotli:
		out, err = brotliDecode(b)
	case fmtGzip:
		out, err = gzipDecode(b)
	case fmtDeflate:
		out, err = zlibDecode(b)
	case fmtDeflateRaw:
		out, err = flateDecode(b)
	}
	if err != nil {
		return which + " decompress failed!", true, err
	}
	if isJSONObject(out) {
		s, _, _ := decodeJSON(out)
		return s, true, nil
	}
	return string(out), true, nil
}

func decodeProtobuf(b []byte) (string, bool, error) {
	fields, err := protoWalk(b, 0)
	if err != nil {
		return "Protobuf decode failed!", false, err
	}
	return prettyJSON(fields), false, nil // schema-less: read-only
}

// -------------------------------------------------------------------------
// Codec primitives
// -------------------------------------------------------------------------

func gzipDecode(b []byte) ([]byte, error) {
	r, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	defer r.Close()
	return io.ReadAll(io.LimitReader(r, oversizeBytes+1))
}

func zlibDecode(b []byte) ([]byte, error) {
	r, err := zlib.NewReader(bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	defer r.Close()
	return io.ReadAll(io.LimitReader(r, oversizeBytes+1))
}

func flateDecode(b []byte) ([]byte, error) {
	r := flate.NewReader(bytes.NewReader(b))
	defer r.Close()
	return io.ReadAll(io.LimitReader(r, oversizeBytes+1))
}

func brotliDecode(b []byte) ([]byte, error) {
	r := brotli.NewReader(bytes.NewReader(b))
	return io.ReadAll(io.LimitReader(r, oversizeBytes+1))
}

// -------------------------------------------------------------------------
// Protobuf schema-less walk (rawproto-style). Produces a slice of
// {field, type, value} entries; a length-delimited field that itself parses as a
// message is nested, else shown as string (if printable) or base64.
// -------------------------------------------------------------------------

type protoField struct {
	Field int         `json:"field"`
	Type  string      `json:"type"`
	Value interface{} `json:"value"`
}

func protoWalk(b []byte, depth int) ([]protoField, error) {
	// Bound nesting: a crafted deeply-nested message would otherwise recurse
	// until the goroutine stack overflows (a fatal, unrecoverable abort).
	if depth > protoMaxDepth {
		return nil, errors.New("protobuf nesting too deep")
	}
	var out []protoField
	for len(b) > 0 {
		num, typ, n := protowire.ConsumeTag(b)
		if n < 0 {
			return nil, protowire.ParseError(n)
		}
		b = b[n:]
		switch typ {
		case protowire.VarintType:
			v, m := protowire.ConsumeVarint(b)
			if m < 0 {
				return nil, protowire.ParseError(m)
			}
			out = append(out, protoField{int(num), "varint", v})
			b = b[m:]
		case protowire.Fixed32Type:
			v, m := protowire.ConsumeFixed32(b)
			if m < 0 {
				return nil, protowire.ParseError(m)
			}
			out = append(out, protoField{int(num), "fixed32", v})
			b = b[m:]
		case protowire.Fixed64Type:
			v, m := protowire.ConsumeFixed64(b)
			if m < 0 {
				return nil, protowire.ParseError(m)
			}
			out = append(out, protoField{int(num), "fixed64", v})
			b = b[m:]
		case protowire.BytesType:
			v, m := protowire.ConsumeBytes(b)
			if m < 0 {
				return nil, protowire.ParseError(m)
			}
			b = b[m:]
			if nested, err := protoWalk(v, depth+1); err == nil && len(nested) > 0 {
				out = append(out, protoField{int(num), "message", nested})
			} else if utf8.Valid(v) {
				out = append(out, protoField{int(num), "string", string(v)})
			} else {
				out = append(out, protoField{int(num), "bytes", base64.StdEncoding.EncodeToString(v)})
			}
		case protowire.StartGroupType:
			v, m := protowire.ConsumeGroup(num, b)
			if m < 0 {
				return nil, protowire.ParseError(m)
			}
			b = b[m:]
			nested, err := protoWalk(v, depth+1)
			if err != nil {
				return nil, err
			}
			out = append(out, protoField{int(num), "group", nested})
		default:
			return nil, fmt.Errorf("unknown wire type %d", typ)
		}
	}
	return out, nil
}

// -------------------------------------------------------------------------
// Byte / display helpers
// -------------------------------------------------------------------------

// bufVisible reports whether the bytes are valid UTF-8 text (ARDM's round-trip
// test reduces to UTF-8 validity in Go, since Go's []byte("string") is lossless).
func bufVisible(b []byte) bool { return utf8.Valid(b) }

// bufToHexEscaped is ARDM's Hex viewer form: printable ASCII bytes literally,
// everything else as \xHH (lowercase), joined with no separator.
func bufToHexEscaped(b []byte) string {
	var sb strings.Builder
	const hexdig = "0123456789abcdef"
	for _, c := range b {
		if c >= 0x20 && c <= 0x7e {
			sb.WriteByte(c)
		} else {
			sb.WriteString(`\x`)
			sb.WriteByte(hexdig[c>>4])
			sb.WriteByte(hexdig[c&0x0f])
		}
	}
	return sb.String()
}

// bufToBinary is ARDM's Binary viewer form: each byte as 8 bits, concatenated.
func bufToBinary(b []byte) string {
	var sb strings.Builder
	sb.Grow(len(b) * 8)
	for _, c := range b {
		for bit := 7; bit >= 0; bit-- {
			if c&(1<<uint(bit)) != 0 {
				sb.WriteByte('1')
			} else {
				sb.WriteByte('0')
			}
		}
	}
	return sb.String()
}

// humanFileSize mirrors ARDM's util.humanFileSize (no space before unit, trailing
// zeros stripped): e.g. 0 -> "0", 1536 -> "1.5KB", 20971520 -> "20MB".
func humanFileSize(size int) string {
	if size == 0 {
		return "0"
	}
	units := []string{"B", "KB", "MB", "GB", "TB"}
	i := int(math.Floor(math.Log(float64(size)) / math.Log(1024)))
	if i < 0 {
		i = 0
	}
	if i >= len(units) {
		i = len(units) - 1
	}
	val := float64(size) / math.Pow(1024, float64(i))
	// toFixed(2) then *1 (strip trailing zeros).
	s := strconv.FormatFloat(val, 'f', 2, 64)
	s = strings.TrimRight(s, "0")
	s = strings.TrimRight(s, ".")
	return s + units[i]
}

// normalize makes an arbitrary decoded value json.Marshal-safe: map[interface{}]…
// (from php/msgpack/pickle) becomes map[string]…, recursively; []byte becomes a
// string when printable.
func normalize(v interface{}) interface{} {
	switch t := v.(type) {
	case map[interface{}]interface{}:
		m := make(map[string]interface{}, len(t))
		for k, val := range t {
			m[fmt.Sprintf("%v", k)] = normalize(val)
		}
		return m
	case map[string]interface{}:
		m := make(map[string]interface{}, len(t))
		for k, val := range t {
			m[k] = normalize(val)
		}
		return m
	case []interface{}:
		s := make([]interface{}, len(t))
		for i, val := range t {
			s[i] = normalize(val)
		}
		return s
	case []byte:
		if utf8.Valid(t) {
			return string(t)
		}
		return base64.StdEncoding.EncodeToString(t)
	default:
		return v
	}
}

// prettyJSON renders v as 4-space-indented JSON (ARDM's display form). HTML
// escaping is disabled so &, <, > survive verbatim.
func prettyJSON(v interface{}) string {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "    ")
	if err := enc.Encode(v); err != nil {
		return fmt.Sprintf("%v", v)
	}
	return strings.TrimRight(buf.String(), "\n")
}

// javaSummary walks the leading tokens of a Java serialization stream enough to
// name the top-level class(es), since Go has no full reader. Best-effort.
func javaSummary(b []byte) string {
	var classes []string
	// TC_OBJECT=0x73 TC_CLASSDESC=0x72; class name is a length-prefixed UTF right
	// after TC_CLASSDESC. Scan for that pattern.
	for i := 0; i+3 < len(b); i++ {
		if b[i] == 0x72 { // TC_CLASSDESC
			ln := int(b[i+1])<<8 | int(b[i+2])
			if ln > 0 && ln < 256 && i+3+ln <= len(b) {
				name := b[i+3 : i+3+ln]
				if utf8.Valid(name) && isJavaClassName(string(name)) {
					classes = append(classes, string(name))
				}
			}
		}
	}
	if len(classes) == 0 {
		return "Java serialized object (class name not recovered).\n" +
			"Full Java deserialization is not supported natively; use the Hex view for raw bytes."
	}
	uniq := dedupStrings(classes)
	return "Java serialized object.\nClasses: " + strings.Join(uniq, ", ") +
		"\n\n(Full field decoding of Java streams is not supported natively; use Hex for raw bytes.)"
}

func isJavaClassName(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !(r == '.' || r == '$' || r == '_' || r == '[' || (r >= '0' && r <= '9') ||
			(r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')) {
			return false
		}
	}
	return strings.Contains(s, ".") || s[0] >= 'A'
}

func dedupStrings(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// -------------------------------------------------------------------------
// Custom formatters — run an external program with the value passed as whole
// argv tokens (NO shell), so redis data can never inject a command.
// -------------------------------------------------------------------------

// rm_format_custom runs a user-defined formatter. Request:
//
//	{command, params, valueB64, key, field, score, member, timeoutMs}
//
// `params` is tokenized shell-style (quotes respected) into argv; each token has
// {VALUE},{HEX},{HEX_FILE},{KEY},{FIELD},{SCORE},{MEMBER} substituted, then the
// program is run as command + argv with a timeout. Response: {ok, text, error}.
//
//export rm_format_custom
func rm_format_custom(in *C.char) (ret *C.char) {
	defer func() {
		if r := recover(); r != nil {
			ret = fmtJSONReturn(map[string]any{"ok": false, "error": fmt.Sprintf("formatter panic: %v", r)})
		}
	}()
	var req struct {
		Command   string `json:"command"`
		Params    string `json:"params"`
		ValueB64  string `json:"valueB64"`
		Key       string `json:"key"`
		Field     string `json:"field"`
		Score     string `json:"score"`
		Member    string `json:"member"`
		TimeoutMs int    `json:"timeoutMs"`
	}
	if err := json.Unmarshal([]byte(C.GoString(in)), &req); err != nil {
		return fmtJSONReturn(map[string]any{"ok": false, "error": err.Error()})
	}
	if strings.TrimSpace(req.Command) == "" {
		return fmtJSONReturn(map[string]any{"ok": false, "error": "Command Error, Check Config!"})
	}
	raw, err := base64.StdEncoding.DecodeString(req.ValueB64)
	if err != nil {
		return fmtJSONReturn(map[string]any{"ok": false, "error": "bad base64: " + err.Error()})
	}

	tokens, err := shellSplit(req.Params)
	if err != nil {
		return fmtJSONReturn(map[string]any{"ok": false, "error": "bad params: " + err.Error()})
	}

	hexStr := toLowerHex(raw)
	var hexFile string
	needHexFile := false
	for _, t := range tokens {
		if strings.Contains(t, "{HEX_FILE}") {
			needHexFile = true
			break
		}
	}
	if needHexFile {
		f, ferr := os.CreateTemp("", "ardm_cv_*")
		if ferr == nil {
			_, _ = f.WriteString(hexStr)
			_ = f.Close()
			hexFile = f.Name()
			defer os.Remove(hexFile)
		}
	}

	repl := strings.NewReplacer(
		"{VALUE}", string(raw),
		"{HEX}", hexStr,
		"{HEX_FILE}", hexFile,
		"{KEY}", req.Key,
		"{FIELD}", req.Field,
		"{SCORE}", req.Score,
		"{MEMBER}", req.Member,
	)
	args := make([]string, len(tokens))
	for i, t := range tokens {
		args[i] = repl.Replace(t)
	}

	timeout := time.Duration(req.TimeoutMs) * time.Millisecond
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, req.Command, args...)
	// Don't hand the app's full environment (which may carry AWS_* / *SECRET* /
	// *TOKEN* credentials) to a formatter subprocess — strip credential-bearing
	// vars.
	cmd.Env = filteredEnv()
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	runErr := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return fmtJSONReturn(map[string]any{"ok": false, "error": "formatter timed out"})
	}
	if runErr != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = runErr.Error()
		}
		return fmtJSONReturn(map[string]any{"ok": false, "error": msg})
	}
	out := strings.TrimRight(stdout.String(), "\n")
	// Pretty-print if the program emitted JSON (ARDM does the same).
	if isJSONObject([]byte(out)) {
		if s, _, e := decodeJSON([]byte(out)); e == nil {
			out = s
		}
	}
	// Include the same Size/printable metadata the built-in path returns, so the
	// Size tag and [Hex] tag stay consistent when a custom formatter is selected.
	return fmtJSONReturn(map[string]any{
		"ok":        true,
		"text":      out,
		"size":      len(raw),
		"sizeHuman": humanFileSize(len(raw)),
		"printable": bufVisible(raw),
	})
}

// filteredEnv is the app environment with credential-bearing variables removed,
// for passing to a user-configured formatter subprocess.
func filteredEnv() []string {
	out := make([]string, 0, len(os.Environ()))
	for _, e := range os.Environ() {
		name := e
		if idx := strings.IndexByte(e, '='); idx >= 0 {
			name = e[:idx]
		}
		up := strings.ToUpper(name)
		if strings.HasPrefix(up, "AWS_") ||
			strings.Contains(up, "SECRET") ||
			strings.Contains(up, "TOKEN") ||
			strings.Contains(up, "PASSWORD") ||
			strings.Contains(up, "PASSWD") ||
			strings.Contains(up, "ACCESS_KEY") ||
			strings.Contains(up, "PRIVATE_KEY") ||
			strings.Contains(up, "CREDENTIAL") {
			continue
		}
		out = append(out, e)
	}
	return out
}

func toLowerHex(b []byte) string {
	const hexdig = "0123456789abcdef"
	var sb strings.Builder
	sb.Grow(len(b) * 2)
	for _, c := range b {
		sb.WriteByte(hexdig[c>>4])
		sb.WriteByte(hexdig[c&0x0f])
	}
	return sb.String()
}

// shellSplit tokenizes a params string like a POSIX shell would for word
// splitting: whitespace separates tokens; single and double quotes group; a
// backslash escapes the next char. It does NOT interpret $, |, ; etc. — those
// stay literal, so there is no shell to inject into.
func shellSplit(s string) ([]string, error) {
	var tokens []string
	var cur strings.Builder
	inTok := false
	i := 0
	for i < len(s) {
		c := s[i]
		switch c {
		case ' ', '\t', '\n', '\r':
			if inTok {
				tokens = append(tokens, cur.String())
				cur.Reset()
				inTok = false
			}
			i++
		case '\'':
			inTok = true
			i++
			for i < len(s) && s[i] != '\'' {
				cur.WriteByte(s[i])
				i++
			}
			if i >= len(s) {
				return nil, errors.New("unterminated single quote")
			}
			i++ // closing '
		case '"':
			inTok = true
			i++
			for i < len(s) && s[i] != '"' {
				if s[i] == '\\' && i+1 < len(s) {
					i++
				}
				cur.WriteByte(s[i])
				i++
			}
			if i >= len(s) {
				return nil, errors.New("unterminated double quote")
			}
			i++ // closing "
		case '\\':
			inTok = true
			if i+1 < len(s) {
				cur.WriteByte(s[i+1])
				i += 2
			} else {
				i++
			}
		default:
			inTok = true
			cur.WriteByte(c)
			i++
		}
	}
	if inTok {
		tokens = append(tokens, cur.String())
	}
	return tokens, nil
}
