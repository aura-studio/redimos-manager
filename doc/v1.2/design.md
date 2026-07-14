# Redimos Manager v1.2 — Design

> [requirements](requirements.md) → design → [tasks](tasks.md)

## Mental model

`redimos` is a pipe: Redis protocol in → DynamoDB out. A former `Config` bundled
three unrelated things — the **process**, the **Redis front**, the **DynamoDB
back**. v1.2 makes the structure explicit:

```
[ Redis clients ] --RESP--> [ redimos proxy = Instance ] --DDB API--> [ Endpoint = DynamoDB ]
```

- **Instance** = the proxy process + the table it serves + a ref to an Endpoint.
- **Endpoint** = a DynamoDB backend (kind ∈ local | aws | url) + credentials,
  shared by instances that target it (deduped by backend tuple).

## Data model

- Go: `Endpoint`, `Instance` structs; on-disk `diskStore{ endpoints[], instances[],
  configs[](legacy mirror), settings, localDdb, formatters, autoStart, ... }`.
- The manager keeps `[]Config` **in memory** unchanged — all launch / DDB-client
  / table-ops code is untouched. Only `load()`/`persist()` translate via
  `splitConfigs` / `mergeToConfigs`. Endpoint id = fnv hash of the backend tuple
  (stable across saves).
- `load()` prefers endpoints[]+instances[]; falls back to legacy configs[].
  `persist()` writes both forms (configs[] is a downgrade mirror).
- Dart mirrors: `DdbEndpoint`, `ProxyInstance`; `DdbEndpoint.toStorageConfig()`
  bridges an endpoint to the storage pages (which take a `RedimosConfig`).

## Navigation

- Root sidebar: two sections (Instances / Endpoints), collapsible 232px ↔ 58px
  rail (persisted to `~/.redimos/nav`). Rail shows status dots + tooltips.
- Instance selected → tabs Configure · Monitor · Logs · Browser · Console.
- Endpoint selected → tabs Configure · Monitor · Logs · Browser · PartiQL.
- Local DynamoDB → an Endpoint (kind=local); its Monitor/Logs reuse the existing
  Local-DDB process metrics/logs.

## Endpoint Browser (merge)

- `Browser` = a two-pane view: left **Tables** list (reuse `endpoint_page`'s list
  + right-click Purge/Recreate/Delete/Browse) + right **Explorer** (reuse
  `table_page` Scan/Query + `item_editor`), driven by the selected table.
- `PartiQL` stays (`partiql_page`).
- AWS endpoints: destructive ops disabled, header shows read-only.

## Playground

- Native: `goja` (JS) + `yaegi` (Go) pure-Go interpreters; FFI
  `rm_playground_run({kind, lang, target, script, timeoutMs})` → `{ok, logs,
  result, error, elapsedMs}`. Host objects `redis` (RESP client) / `ddb` (SigV4)
  / `console`. Sandboxed (no fs/net beyond the client); `vm.Interrupt` on timeout;
  writes re-check the AWS read-only guard. External-exec (custom formatters + any
  Playground shell-out) is argv-only, never `sh -c`.
- Flutter: one `PlaygroundView` reused for instance/endpoint, with a JS/Go toggle
  and a sample-program dropdown (samples in both languages).

## i18n

- `lib/src/i18n.dart`: global `appLang`, `tr(key)` table, persisted to
  `~/.redimos/locale`; MaterialApp rebuilds on theme|lang. Product/brand/format
  names stay untranslated.

## Constraints

- RedimosManager only; `redimos` repos untouched. New native deps pure-Go, in the
  offline module cache. Every phase: `flutter analyze` + `go vet`/`go test` green.
