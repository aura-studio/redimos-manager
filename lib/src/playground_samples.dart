// Sample Playground programs, in both JavaScript (goja) and Go (yaegi). The
// hosts are sandboxed — JS gets lowercase objects (redis.get / ddb.scanAll /
// console.log); Go gets Go method names (redis.Get / ddb.ScanAll / console.Log)
// and, since no stdlib is injected, Go samples avoid fmt/strconv/strings and use
// only builtins + the host packages.

class PlaygroundSample {
  final String titleKey; // i18n key
  final String js;
  final String go;
  const PlaygroundSample(this.titleKey, this.js, this.go);
}

List<PlaygroundSample> samplesForKind(String kind) =>
    kind == 'redis' ? redisSamples : ddbSamples;

// --------------------------------------------------------------------------
// Redis (instance) samples — talk to the running proxy via the `redis` host.
// --------------------------------------------------------------------------

const List<PlaygroundSample> redisSamples = [
  PlaygroundSample(
    'pg.s.redisPrefix',
    // JS
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
    // Go — redis.Keys() walks the whole keyspace in one call (the Go sandbox
    // can't bind a paged SCAN's results inside a loop), then we group in pure Go.
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
    // Go — a per-key TTL loop can't bind host results in the Go sandbox, so this
    // inspects one key at top level; use the JavaScript version for a full audit.
    '''
// Inspect one key's type and remaining TTL (edit the key name below).
key := "mykey"
t, _ := redis.Type(key)
ttl, _ := redis.TTL(key)
console.Log("key:", key, " type:", t, " ttl(seconds):", ttl)
''',
  ),
  PlaygroundSample(
    'pg.s.redisRename',
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
    '''
// Scan a table and count items + sum a numeric attribute (edit names below).
const table = "mytable";
const items = ddb.scanAll(table, { limit: 1000 });
let sum = 0;
for (const it of items) if (typeof it.amount === "number") sum += it.amount;
console.log("items:", items.length, " sum(amount):", sum);
({ count: items.length, sumAmount: sum });
''',
    '''
// Scan a table and count items (edit the table name below).
table := "mytable"
items, err := ddb.ScanAll(table, map[string]interface{}{"limit": 1000})
if err != nil {
	console.Error(err.Error())
} else {
	console.Log("items:", len(items))
	console.Table(items)
}
''',
  ),
  PlaygroundSample(
    'pg.s.ddbExportJsonl',
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
// Bucket items by serialized size (approximated by field count here).
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
  PlaygroundSample(
    'pg.s.ddbPartiql',
    '''
// Run a PartiQL SELECT and show the first few rows.
const rows = ddb.partiql('SELECT * FROM "mytable"', []);
console.log("rows:", rows.length);
rows.slice(0, 5);
''',
    '''
// Run a PartiQL SELECT and show the row count.
rows, err := ddb.PartiQL("SELECT * FROM \\"mytable\\"", nil)
if err != nil {
	console.Error(err.Error())
} else {
	console.Log("rows:", len(rows))
	console.Table(rows)
}
''',
  ),
  PlaygroundSample(
    'pg.s.ddbConditionalDelete',
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
];
