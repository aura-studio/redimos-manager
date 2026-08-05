// Sample Playground programs, in both JavaScript (goja) and Go (yaegi). The
// hosts are sandboxed — JS gets lowercase objects (redis.get / ddb.scanAll /
// console.log); Go gets Go method names (redis.Get / ddb.ScanAll / console.Log)
// and, since no stdlib is injected, Go samples avoid fmt/strconv/strings, and
// cannot bind a host call's multi-return inside a loop — so they aggregate via
// redis.Keys() / ddb.ScanAll() at the top level and loop over pure Go.

class PlaygroundSample {
  final String titleKey; // i18n key for the dropdown title
  final String descKey; // i18n key for the one-line description
  final String js;
  final String go;
  const PlaygroundSample(this.titleKey, this.descKey, this.js, this.go);
}

List<PlaygroundSample> samplesForKind(String kind) =>
    kind == 'redis' ? redisSamples : ddbSamples;

// --------------------------------------------------------------------------
// Redis (instance) samples — talk to the running proxy via the `redis` host.
// --------------------------------------------------------------------------

const List<PlaygroundSample> redisSamples = [
  PlaygroundSample(
    'pg.s.redisPrefix',
    'pg.d.redisPrefix',
    '''
// Count keys grouped by their prefix (text before the first ':').
const groups = {};
let cursor = "0";
do {
  const page = redis.scan(cursor, "*", 500);
  for (const k of (page.keys || [])) {
    const s = String(k);
    const i = s.indexOf(":");
    const p = i < 0 ? s : s.slice(0, i);
    groups[p] = (groups[p] || 0) + 1;
  }
  cursor = page.cursor;
} while (cursor !== "0");
console.table(groups);
groups;
''',
    '''
// Count keys grouped by their prefix (text before the first ':').
keys, err := redis.Keys("*")
if err != nil {
	console.Error("keys: " + err.Error())
} else {
	groups := map[string]int{}
	for _, k := range keys {
		s := k.(string)
		p := s
		for i := 0; i < len(s); i++ {
			if s[i] == ':' {
				p = s[:i]
				break
			}
		}
		groups[p] = groups[p] + 1
	}
	console.Table(groups)
}
''',
  ),
  PlaygroundSample(
    'pg.s.redisHashExport',
    'pg.d.redisHashExport',
    '''
// Dump one hash key's fields (edit the key name below).
const key = "myhash";
const t = redis.type(key);
console.log("type:", t);
const all = redis.hgetall(key);
console.table(all);
all;
''',
    '''
// Dump one hash key's fields (edit the key name below).
key := "myhash"
t, _ := redis.Type(key)
console.Log("type:", t)
all, err := redis.HGetAll(key)
if err != nil {
	console.Error(err.Error())
} else {
	console.Table(all)
}
''',
  ),
  PlaygroundSample(
    'pg.s.redisTtlAudit',
    'pg.d.redisTtlAudit',
    '''
// Audit TTLs: scan keys and log each one that carries a TTL, as it is found,
// so partial results survive if a slow backend hits the run timeout. Each ttl()
// is a round-trip, so this is bounded to ~500 keys — narrow the SCAN match (or
// raise the cap) for a fuller audit.
let cursor = "0", scanned = 0, withTtl = 0;
do {
  const page = redis.scan(cursor, "*", 500);
  for (const k of (page.keys || [])) {
    scanned++;
    const ttl = redis.ttl(String(k));
    if (ttl > 0) { withTtl++; console.log(String(k) + "  ttl=" + ttl); }
  }
  cursor = page.cursor;
} while (cursor !== "0" && scanned < 500);
console.log("-- scanned " + scanned + " keys, " + withTtl + " with a TTL --");
({ scanned: scanned, withTtl: withTtl });
''',
    '''
// Inspect one key's type and remaining TTL (per-key TTL in a loop can't bind
// host results in the Go sandbox — use the JavaScript version for a full audit).
key := "mykey"
t, _ := redis.Type(key)
ttl, _ := redis.TTL(key)
console.Log("key:", key, " type:", t, " ttl(seconds):", ttl)
''',
  ),
  PlaygroundSample(
    'pg.s.redisRename',
    'pg.d.redisRename',
    '''
// Rename a String key: copy the value to a new key, then delete the old one.
// This WRITES — it only runs against a local / URL endpoint (AWS stays read-only).
const from = "old:key", to = "new:key";
const v = redis.get(from);
if (v === null) {
  console.error("source key not found:", from);
} else {
  redis.set(to, v);
  redis.del(from);
  console.log("renamed", from, "->", to);
}
''',
    '''
// Rename a String key: copy to a new key, then delete the old one. WRITES.
from, to := "old:key", "new:key"
v, err := redis.Get(from)
if err != nil {
	console.Error(err.Error())
} else if v == nil {
	console.Error("source key not found: " + from)
} else {
	redis.Set(to, v.(string))
	redis.Del(from)
	console.Log("renamed", from, "->", to)
}
''',
  ),
  PlaygroundSample(
    'pg.s.redisBench',
    'pg.d.redisBench',
    '''
// Time N SET+GET round-trips against the proxy, then clean up. WRITES.
const N = 200;
const t0 = Date.now();
for (let i = 0; i < N; i++) {
  redis.set("bench:" + i, String(i));
  redis.get("bench:" + i);
}
const ms = Date.now() - t0;
for (let i = 0; i < N; i++) redis.del("bench:" + i);
console.log(N + " set+get in " + ms + "ms  (" + (ms / N).toFixed(2) + " ms/op)");
({ ops: N, ms: ms });
''',
    '''
// Time N SET+GET round-trips against the proxy, then clean up. WRITES.
N := 200
for i := 0; i < N; i++ {
	redis.Set("bench:tmp", "x")
	redis.Get("bench:tmp")
}
redis.Del("bench:tmp")
console.Log("did", N, "set+get round-trips")
''',
  ),
];

// --------------------------------------------------------------------------
// DynamoDB (endpoint) samples — talk to the backend via the `ddb` host.
// --------------------------------------------------------------------------

const List<PlaygroundSample> ddbSamples = [
  PlaygroundSample(
    'pg.s.ddbScanAggregate',
    'pg.d.ddbScanAggregate',
    '''
// Scan a table and group items by one attribute, counting each value. The
// returned rows render as a table (edit the table + field names below).
const table = "mytable", field = "status";
const items = ddb.scanAll(table, {});
const counts = {};
for (const it of items) {
  const k = it[field] === undefined ? "(none)" : String(it[field]);
  counts[k] = (counts[k] || 0) + 1;
}
const rows = Object.keys(counts).map(k => ({ [field]: k, count: counts[k] }));
rows.sort((a, b) => b.count - a.count);
console.log("scanned " + items.length + " items in 1 page");
rows;
''',
    '''
// Scan a table and group items by one STRING attribute, counting each value.
table, field := "mytable", "status"
items, err := ddb.ScanAll(table, map[string]interface{}{})
if err != nil {
	console.Error(err.Error())
} else {
	counts := map[string]int{}
	for _, it := range items {
		m := it.(map[string]interface{})
		v := m[field]
		if v == nil {
			counts["(none)"] = counts["(none)"] + 1
		} else {
			s := v.(string)
			counts[s] = counts[s] + 1
		}
	}
	console.Log("scanned", len(items), "items in 1 page")
	console.Table(counts)
}
''',
  ),
  PlaygroundSample(
    'pg.s.ddbCrossCopy',
    'pg.d.ddbCrossCopy',
    '''
// Copy every item from one table to another. WRITES (local / URL only).
const src = "src_table", dst = "dst_table";
const items = ddb.scanAll(src, {});
let n = 0;
for (const it of items) { ddb.putItem(dst, it); n++; }
console.log("copied", n, "items", src, "->", dst);
n;
''',
    '''
// Copy every item from one table to another. WRITES (local / URL only).
src, dst := "src_table", "dst_table"
items, err := ddb.ScanAll(src, map[string]interface{}{})
if err != nil {
	console.Error(err.Error())
} else {
	n := 0
	for _, it := range items {
		m := it.(map[string]interface{})
		ddb.PutItem(dst, m)
		n = n + 1
	}
	console.Log("copied", n, "items", src, "->", dst)
}
''',
  ),
  PlaygroundSample(
    'pg.s.ddbConditionalDelete',
    'pg.d.ddbConditionalDelete',
    '''
// Delete items whose status == "expired". WRITES (local / URL only).
// Adjust the key attributes ({ pk, sk }) to your table's key schema.
const table = "mytable";
const items = ddb.scanAll(table, {});
let n = 0;
for (const it of items) {
  if (it.status === "expired") {
    ddb.deleteItem(table, { pk: it.pk, sk: it.sk });
    n++;
  }
}
console.log("deleted", n, "expired items");
n;
''',
    '''
// Delete items whose status == "expired". WRITES (local / URL only).
table := "mytable"
items, err := ddb.ScanAll(table, map[string]interface{}{})
if err != nil {
	console.Error(err.Error())
} else {
	n := 0
	for _, it := range items {
		m := it.(map[string]interface{})
		if m["status"] == "expired" {
			ddb.DeleteItem(table, map[string]interface{}{"pk": m["pk"], "sk": m["sk"]})
			n = n + 1
		}
	}
	console.Log("deleted", n, "expired items")
}
''',
  ),
  PlaygroundSample(
    'pg.s.ddbExportJsonl',
    'pg.d.ddbExportJsonl',
    '''
// Print each item as one JSON line (copy the console output as JSONL).
const table = "mytable";
const items = ddb.scanAll(table, { limit: 500 });
for (const it of items) console.log(JSON.stringify(it));
console.log("-- " + items.length + " items --");
''',
    '''
// Print each item; console.Table renders it as JSON.
table := "mytable"
items, err := ddb.ScanAll(table, map[string]interface{}{"limit": 500})
if err != nil {
	console.Error(err.Error())
} else {
	for _, it := range items {
		console.Table(it)
	}
	console.Log("count:", len(items))
}
''',
  ),
  PlaygroundSample(
    'pg.s.ddbSizeHistogram',
    'pg.d.ddbSizeHistogram',
    '''
// Bucket items by serialized size — spot oversized rows.
const table = "mytable";
const items = ddb.scanAll(table, {});
const buckets = { "<256B": 0, "<1KB": 0, "<4KB": 0, ">=4KB": 0 };
for (const it of items) {
  const n = JSON.stringify(it).length;
  if (n < 256) buckets["<256B"]++;
  else if (n < 1024) buckets["<1KB"]++;
  else if (n < 4096) buckets["<4KB"]++;
  else buckets[">=4KB"]++;
}
console.table(buckets);
buckets;
''',
    '''
// Bucket items by field count (a proxy for size, no stdlib needed).
table := "mytable"
items, err := ddb.ScanAll(table, map[string]interface{}{})
if err != nil {
	console.Error(err.Error())
} else {
	small, big := 0, 0
	for _, it := range items {
		m := it.(map[string]interface{})
		if len(m) <= 8 {
			small = small + 1
		} else {
			big = big + 1
		}
	}
	console.Table(map[string]int{"<=8 fields": small, ">8 fields": big})
}
''',
  ),
];
