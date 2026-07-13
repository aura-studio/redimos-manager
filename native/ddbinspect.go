package main

// Startup table inspection: before (re)starting a config, peek at the DynamoDB
// table it points at and, if it already holds data, infer what redimos line
// wrote it — v1 vs v2 and MultiDB vs single-DB — so a mismatch with the current
// config can be surfaced instead of letting redimos crash-loop on a "Type
// mismatch for key" or silently write into an incompatible layout.
//
// Inference ground truth (verified against DynamoDB Local):
//   - v1 tables use STRING (S) partition keys; v2 uses BINARY (B).  (DescribeTable
//     AttributeDefinitions — authoritative, independent of the data.)
//   - MultiDB namespaces every key as "<db>:<key>" (db 0..15); single-DB stores
//     the bare key.  Inferred from the partition-key VALUES of a data sample.
//
// The DynamoDB client is hand-rolled (SigV4 + net/http + encoding/json) so the
// native module stays dependency-free and the c-shared build stays offline.

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
)

// tableInspect is the result of checkTableCompat.
type tableInspect struct {
	Checked      bool   `json:"checked"`      // false = skipped (no creds, table missing/empty, or net error)
	HasData      bool   `json:"hasData"`      //
	Version      string `json:"tableVersion"` // "v1" | "v2" (inferred from key type)
	MultiDB      bool   `json:"tableMultiDb"` // inferred (valid only when MultiDBKnown)
	MultiDBKnown bool   `json:"tableMultiDbKnown"`
	Mismatch     bool   `json:"mismatch"`
	Detail       string `json:"detail"` // English, one line, what disagrees with the config
}

// ddbNamespaced matches a MultiDB partition key: a leading "<db>:" where db is
// a Redis database index 0..15.
var ddbNamespaced = regexp.MustCompile(`^(1[0-5]|[0-9]):`)

// ddbCreds mirrors awsCredEnv: config creds first, dummy "local" for a local
// endpoint left blank, else the process AWS_* env. Empty accessKey => can't sign.
func ddbCreds(cfg *Config) (ak, sk, token string) {
	ak, sk, token = cfg.AccessKeyID, cfg.SecretKey, cfg.SessionToken
	if ak == "" && cfg.Endpoint != "" {
		return "local", "local", ""
	}
	if ak == "" {
		ak, sk, token = os.Getenv("AWS_ACCESS_KEY_ID"), os.Getenv("AWS_SECRET_ACCESS_KEY"), os.Getenv("AWS_SESSION_TOKEN")
	}
	return ak, sk, token
}

func ddbRegion(cfg *Config) string {
	if strings.TrimSpace(cfg.Region) != "" {
		return cfg.Region
	}
	return "us-east-1"
}

func ddbEndpoint(cfg *Config) string {
	if strings.TrimSpace(cfg.Endpoint) != "" {
		return cfg.Endpoint
	}
	return "https://dynamodb." + ddbRegion(cfg) + ".amazonaws.com"
}

func hmacSHA256(key []byte, s string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(s))
	return h.Sum(nil)
}

func sha256Hex(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// ddbCall issues one signed DynamoDB JSON request (target e.g. "DescribeTable")
// and returns the decoded JSON body.
func ddbCall(cfg *Config, target string, payload map[string]any) (map[string]any, error) {
	ak, sk, token := ddbCreds(cfg)
	if ak == "" || sk == "" {
		return nil, fmt.Errorf("no credentials")
	}
	region := ddbRegion(cfg)
	endpoint := ddbEndpoint(cfg)
	u, err := url.Parse(endpoint)
	if err != nil {
		return nil, err
	}
	body, _ := json.Marshal(payload)

	now := time.Now().UTC()
	amzDate := now.Format("20060102T150405Z")
	dateStamp := now.Format("20060102")
	host := u.Host
	amzTarget := "DynamoDB_20120810." + target
	contentType := "application/x-amz-json-1.0"

	// Canonical headers (sorted). x-amz-security-token included only when present.
	var canonHeaders strings.Builder
	signedHeaders := "content-type;host;x-amz-date;x-amz-target"
	canonHeaders.WriteString("content-type:" + contentType + "\n")
	canonHeaders.WriteString("host:" + host + "\n")
	canonHeaders.WriteString("x-amz-date:" + amzDate + "\n")
	if token != "" {
		canonHeaders.WriteString("x-amz-security-token:" + token + "\n")
		signedHeaders = "content-type;host;x-amz-date;x-amz-security-token;x-amz-target"
	}
	canonHeaders.WriteString("x-amz-target:" + amzTarget + "\n")

	canonReq := strings.Join([]string{
		"POST", "/", "",
		canonHeaders.String(),
		signedHeaders,
		sha256Hex(body),
	}, "\n")

	scope := dateStamp + "/" + region + "/dynamodb/aws4_request"
	stringToSign := strings.Join([]string{
		"AWS4-HMAC-SHA256", amzDate, scope, sha256Hex([]byte(canonReq)),
	}, "\n")

	kDate := hmacSHA256([]byte("AWS4"+sk), dateStamp)
	kRegion := hmacSHA256(kDate, region)
	kService := hmacSHA256(kRegion, "dynamodb")
	kSigning := hmacSHA256(kService, "aws4_request")
	signature := hex.EncodeToString(hmacSHA256(kSigning, stringToSign))

	authz := fmt.Sprintf("AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		ak, scope, signedHeaders, signature)

	req, err := http.NewRequest("POST", endpoint, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", contentType)
	req.Header.Set("X-Amz-Date", amzDate)
	req.Header.Set("X-Amz-Target", amzTarget)
	req.Header.Set("Authorization", authz)
	if token != "" {
		req.Header.Set("X-Amz-Security-Token", token)
	}

	client := &http.Client{Timeout: 6 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	// Cap the body generously (a DynamoDB response is bounded — a Scan page is ≤1 MB
	// of item data, a few MB on the wire once Binary keys are base64-encoded), but do
	// NOT silently accept a truncated/undecodable body: on a 200 a discarded decode
	// error would report bogus success — e.g. an oversized Scan page decoding to nil
	// would look like an empty page and stop a purge mid-table with deleted:0.
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	var out map[string]any
	uerr := json.Unmarshal(raw, &out)
	if resp.StatusCode != 200 {
		msg := ""
		if out != nil {
			if m, ok := out["message"].(string); ok {
				msg = m
			} else if m, ok := out["Message"].(string); ok {
				msg = m
			}
		}
		return out, fmt.Errorf("http %d: %s", resp.StatusCode, msg)
	}
	if uerr != nil {
		return nil, fmt.Errorf("decode response (%d bytes): %w", len(raw), uerr)
	}
	return out, nil
}

// isAwsHost reports whether an endpoint URL targets a real AWS DynamoDB host, so
// destructive table lifecycle can be walled off there too — not only for the empty
// (default-resolver) endpoint — since the manager can't tell a test AWS account from
// production even when an explicit regional/FIPS/VPC-interface URL is typed.
func isAwsHost(endpoint string) bool {
	u, err := url.Parse(strings.TrimSpace(endpoint))
	if err != nil {
		return false
	}
	h := strings.ToLower(u.Hostname())
	return h == "amazonaws.com" || strings.HasSuffix(h, ".amazonaws.com")
}

// awsModeForEndpoint reports whether destructive table/item ops must be refused for
// this endpoint: the empty endpoint (default AWS resolver) OR an explicit AWS host.
// Local / LocalStack / custom endpoints return false.
func awsModeForEndpoint(ep string) bool {
	ep = strings.TrimSpace(ep)
	return ep == "" || isAwsHost(ep)
}

// hashKeyType returns the DynamoDB attribute type ("S"/"B"/...) of a table's
// partition (HASH) key, from a DescribeTable response.
func hashKeyType(desc map[string]any) (string, bool) {
	tbl, _ := desc["Table"].(map[string]any)
	if tbl == nil {
		return "", false
	}
	hashName := ""
	if ks, ok := tbl["KeySchema"].([]any); ok {
		for _, e := range ks {
			m, _ := e.(map[string]any)
			if m != nil && m["KeyType"] == "HASH" {
				hashName, _ = m["AttributeName"].(string)
			}
		}
	}
	if hashName == "" {
		return "", false
	}
	if ads, ok := tbl["AttributeDefinitions"].([]any); ok {
		for _, e := range ads {
			m, _ := e.(map[string]any)
			if m != nil && m["AttributeName"] == hashName {
				t, _ := m["AttributeType"].(string)
				return t, t != ""
			}
		}
	}
	return "", false
}

// pkValuesFromScan extracts the partition-key string values from a Scan
// response, decoding Binary (v2) keys from base64 to their UTF-8 form.
func pkValuesFromScan(scan map[string]any, hashName string) []string {
	var out []string
	items, _ := scan["Items"].([]any)
	for _, it := range items {
		m, _ := it.(map[string]any)
		av, _ := m[hashName].(map[string]any)
		if av == nil {
			continue
		}
		if s, ok := av["S"].(string); ok {
			out = append(out, s)
		} else if b, ok := av["B"].(string); ok {
			if raw, err := base64.StdEncoding.DecodeString(b); err == nil {
				out = append(out, string(raw))
			}
		}
	}
	return out
}

func hashKeyName(desc map[string]any) string {
	tbl, _ := desc["Table"].(map[string]any)
	if tbl == nil {
		return ""
	}
	if ks, ok := tbl["KeySchema"].([]any); ok {
		for _, e := range ks {
			m, _ := e.(map[string]any)
			if m != nil && m["KeyType"] == "HASH" {
				n, _ := m["AttributeName"].(string)
				return n
			}
		}
	}
	return ""
}

// checkTableCompat inspects cfg's table and reports whether the data already
// there disagrees with cfg's Version / MultiDB. Best-effort: any failure
// (missing creds, table absent, empty table, network error) yields Checked=false
// and Mismatch=false so the caller just proceeds to start.
func checkTableCompat(cfg *Config) tableInspect {
	res := tableInspect{}
	if strings.TrimSpace(cfg.Table) == "" {
		return res
	}
	desc, err := ddbCall(cfg, "DescribeTable", map[string]any{"TableName": cfg.Table})
	if err != nil {
		return res // table missing / unreachable / unauthorized → nothing to warn about
	}
	keyType, ok := hashKeyType(desc)
	if !ok {
		return res
	}
	scan, err := ddbCall(cfg, "Scan", map[string]any{
		"TableName": cfg.Table, "Limit": 20,
		"ProjectionExpression": "#p", "ExpressionAttributeNames": map[string]any{"#p": hashKeyName(desc)},
	})
	if err != nil {
		return res
	}
	pks := pkValuesFromScan(scan, hashKeyName(desc))
	if len(pks) == 0 {
		return res // empty table → nothing to infer from ("已有数据" only)
	}

	res.Checked = true
	res.HasData = true
	res.Version = "v1"
	if keyType == "B" {
		res.Version = "v2"
	}

	// MultiDB: all sampled keys namespaced => on; none => off; mixed => unknown.
	ns, plain := 0, 0
	for _, k := range pks {
		if ddbNamespaced.MatchString(k) {
			ns++
		} else {
			plain++
		}
	}
	if ns > 0 && plain == 0 {
		res.MultiDB, res.MultiDBKnown = true, true
	} else if plain > 0 && ns == 0 {
		res.MultiDB, res.MultiDBKnown = false, true
	}

	verMis := res.Version != cfg.Version
	mdMis := res.MultiDBKnown && res.MultiDB != cfg.MultiDB
	res.Mismatch = verMis || mdMis
	if res.Mismatch {
		var parts []string
		if verMis {
			parts = append(parts, fmt.Sprintf("the data was written by redimos %s (%s keys) but this config is %s",
				res.Version, map[string]string{"v1": "String", "v2": "Binary"}[res.Version], cfg.Version))
		}
		if mdMis {
			was, want := "single-DB", "MultiDB on"
			if res.MultiDB {
				was, want = "MultiDB (namespaced keys)", "MultiDB off"
			}
			parts = append(parts, fmt.Sprintf("the keys look %s but this config has %s", was, want))
		}
		res.Detail = fmt.Sprintf("Table %q already has data and %s.", cfg.Table, strings.Join(parts, ", and "))
	}
	return res
}
