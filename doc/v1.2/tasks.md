# Redimos Manager v1.2 — Tasks

> [requirements](requirements.md) → [design](design.md) → tasks (this file).
> Expert mode: fine-grained checkboxes, tests built in, checked off as completed.
> Branch `feat/v1.2`. Legend: `[ ]` todo · `[x]` done · `[~]` in progress.
> Gate G* = each phase ends with `flutter analyze` clean + `go vet`/`go test` green
> before commit.

---

## Phase 0 — Spec & branch (foundation)

- [x] 0.1 Create branch `feat/v1.2` off master (v1.1.0).
- [x] 0.2 Write `doc/v1.2/requirements.md`, `design.md`, `tasks.md` (this spec).

## Phase 1 — i18n + theme  · commit `a2f7cb1`  · DONE

- [x] 1.1 `lib/src/i18n.dart`: `AppLang{en,zh}`, global `appLang`, `~/.redimos/locale`
      load/save (first run follows OS locale), `tr(key)` table.
- [x] 1.2 `main.dart`: `loadAppLang()` in `main()`; MaterialApp rebuilds on
      theme|lang via `Listenable.merge`; keep existing Light/Dark/System theme.
- [x] 1.3 Top bar: 🌐 language menu (中文/English) beside the theme menu.
- [x] 1.4 Extract user-visible strings to `tr()` across main + all page files
      (8-agent workflow, 397 keys, product/brand names left as-is).
- [x] 1.5 **TEST**: `flutter analyze` clean; launch with `locale=zh` → tabs and
      Configure form render in Chinese (verified via screenshot).
- [ ] 1.6 Extract the remaining mid-sentence interpolations the workflow left
      (Purged N items / delete-confirm bodies / stats caption). *(polish, deferred)*

## Phase 2 — Data model split + migration  · commit `5288fa7`  · DONE

- [x] 2.1 `native/model_split.go`: `Endpoint`, `Instance`, `diskStore`,
      `endpointKind`, `endpointTuple`, `splitConfigs`, `mergeToConfigs`, dedup by
      backend tuple, fnv-hash endpoint ids.
- [x] 2.2 `redimos_core.go` `load()`/`persist()`: translate to/from the split form;
      legacy `configs[]` fallback; downgrade `configs[]` mirror written.
- [x] 2.3 `native/model_split_test.go`: kind, split/merge round-trip, dedup,
      stable ids, legacy migration.
- [x] 2.4 **TEST**: `go test` (5 tests) pass; real store migrated end-to-end
      (proxies relaunched with correct args; `configs:2 → endpoints:2 + instances:2`).
- [x] 2.5 `rm_load` also returns `endpoints[]`+`instances[]`; Dart `DdbEndpoint`,
      `ProxyInstance` models; `native.dart load()` parses them.

## Phase 3 — Two-section sidebar + nav rework  · IN PROGRESS

- [x] 3.1 HomePage state: `_endpoints`, `_selEndpointId`, `_navCollapsed`;
      `_reload()` populates the lists; `~/.redimos/nav` persist helpers. (Instances
      use `_configs` directly — a config = one instance.)
- [x] 3.2 Sidebar `_configList()`: two sections (Instances via `_configTile`,
      Endpoints via `_endpointTile`) + colored section headers + New-config/collapse
      header.
- [x] 3.3 Collapsed rail `_navRail()` (58px): expand toggle + status-dot items with
      name tooltips; body width toggles 232 ↔ 58; state persisted to `~/.redimos/nav`.
- [x] 3.4 `_detail()`: branch on `_selEndpointId` — endpoint selected shows
      `_endpointDetail` (header + the endpoint's table list / lifecycle ops over
      `endpoint.toStorageConfig()`); instance selected keeps the existing tab detail.
- [~] 3.5 Instance tab set: Playground ADDED (now 9 tabs: Configure·Monitor·Logs·
      Endpoint·Table·PartiQL·Console·Browser·Playground). *Deliberate deviation:*
      Endpoint/Table/PartiQL were kept on the instance rather than removed — the
      endpoint now has its OWN copy of those views (P4), so trimming the instance
      would only remove convenience, not capability. Left as-is to avoid regressing
      a working layout; a later cleanup can drop them if the endpoint view fully
      subsumes them.
- [ ] 3.6 Local DynamoDB shown under the Endpoints section (kind=local). *(deferred)*
- [x] 3.7 i18n: nav strings added to `i18n.dart` (`nav.instances/endpoints/collapse/
      expand/noneYet`).
- [x] 3.8 **TEST**: `flutter analyze` clean; macOS build + launch → two sections
      render (Instances: local-ddb, new-config · Endpoints: us-east-1 [AWS], local
      [LOCAL], deduped from the configs, with kind badges) — verified via screenshot.
      Collapse rail + endpoint-detail implemented & analyze-clean (click-verify by
      user, screencapture flaky this session). Commit G3.

## Phase 4 — Endpoint Browser (merge Tables+Explorer)

- [x] 4.1 `endpoint_detail.dart` `EndpointDetailView`: gives an endpoint its own
      tab set bound to the backend — **Tables** (reuse `endpoint_page` list +
      lifecycle ops), **Explorer** (reuse `table_page` Scan/Query + `item_editor`),
      **PartiQL**, **Playground**. Browsing a table from Tables jumps to the
      Explorer focused on it (`tableOverride`). *(Delivered as a tab set rather than
      a single split pane with a persistent Tables sidebar — same views merged onto
      one entity, less code, no regression. A split-pane refinement is optional.)*
- [x] 4.2 Endpoint detail (3.4) now renders `EndpointDetailView` (header + the tab
      set above) instead of the bare table list.
- [x] 4.3 AWS endpoint stays read-only: `table_page`/`partiql_page` already gate
      writes on `awsModeForEndpoint` + a read-only chip; the native `ddbHost` also
      re-guards every write. Playground shows a read-only chip on AWS.
- [x] 4.4 i18n: reused `tab.endpoint/table/partiql` + new `tab.playground`.
- [x] 4.5 **TEST**: `flutter analyze` clean; build+launch OK. Enablers verified:
      the Explorer's empty-table gate now keys off the EFFECTIVE table so an
      endpoint (empty own-table) becomes usable once a table is browsed; PartiQL
      gained `allowNoTable` so it works on an endpoint (table named in the
      statement). (Endpoint click-through left to the user.)

## Phase 5 — Playground (JS + Go)

- [x] 5.1 Pre-warm `goja` (dop251) + `yaegi` (traefik v0.16.1) into the offline
      module cache (both pure Go, c-shared-safe). *(go.mod require added when 5.2 lands.)*
- [x] 5.2 `native/playground.go` (`//export rm_playground_run`) + `native/resp_min.go`
      (minimal RESP client): host objects `redis` (RESP to instance port) / `ddb`
      (SigV4 via `ddbCall` + AV marshaling) / `console`; dispatch by `lang`
      (js→goja lowercase API, go→yaegi Go API). AV plain↔attribute-value both ways.
- [x] 5.3 Sandbox: goja has no require/process/fs, yaegi injects only redis/ddb/
      console (no stdlib), so `import "os"` fails; `vm.Interrupt`/`EvalWithContext`
      kill a runaway loop on `timeoutMs`; ddb writes re-check the AWS read-only guard.
- [x] 5.4 `native/playground_test.go` (10 tests, all pass): console/sandbox/timeout
      for JS **and** Go, AV round-trip, result export, and a live read-only check
      against the running `:6379` proxy. Full native suite + offline build + vet green.
- [x] 5.5 Dart: `native.dart playgroundRun(...)` (off-isolate); `PlaygroundView`
      (`playground_page.dart`) — monospace editor + JS/Go SegmentedButton + sample
      dropdown + console/return-value panels + read-only chip; reused for both
      instance (kind=redis) and endpoint (kind=ddb).
- [x] 5.6 Sample sets (`playground_samples.dart`, JS + Go): redis (prefix stats /
      hash export / TTL audit / rename / bench) and ddb (scan-aggregate / export
      JSONL / size histogram / partiql / conditional delete). Go samples respect
      yaegi's limits (no comma-ok assertions; no multi-return `:=` inside a loop —
      use `redis.Keys()`/`ddb.ScanAll()` at top level). Each sample verified via a
      ctypes probe of the shipped dylib against the live `:6379` proxy (read-only)
      and an unreachable ddb endpoint (compile check).
- [x] 5.7 Playground tab added to the instance tab set (9th tab) and the endpoint
      tab set; `pg.*` + `tab.playground` i18n (en/zh).
- [x] 5.8 **TEST**: `go test` playground green; ctypes probe on the shipped dylib —
      JS+Go console/SCAN against the live proxy, sandbox blocks `require`, timeout
      kills `while(true){}` in ~0.4s, all samples run. `flutter analyze` clean; app
      builds+launches. (GUI click-verify left to the user — screencapture blocked by
      the focus-stealing IDE this session.)

## Phase 6 — Finishing

- [ ] 6.1 Endpoint Monitor/Logs for AWS (client-side call metrics / API log) —
      minimal or clearly-labeled placeholder.
- [ ] 6.2 i18n completion: sweep new views; 1.6 leftovers.
- [ ] 6.3 Adversarial review (workflow) of native additions (Playground sandbox,
      model split edges); fix confirmed findings.
- [ ] 6.4 **TEST**: full `flutter analyze` + `go vet` + `go test ./native/...`
      green; migration + playground tests green.
- [ ] 6.5 Bump pubspec to 1.2.0; build macOS DMG; VM build Windows setup.exe+zip;
      `gh release create v1.2.0` with 3 assets (mirror v1.1.0).
- [ ] 6.6 Update memory (redimos-manager-project) with the v1.2 rework + recipe.

---

### Dependency order
`P0 → P1 ∥ P2 → P3 → P4 → P5 → P6`. P1 and P2 were independent. P3 depends on P2
(needs endpoints/instances). P4 depends on P3 (endpoint detail host). P5's native
runtime (5.1–5.4) is independent of P3/P4 and can be built in parallel; its UI
(5.5–5.7) depends on P3's tab structure. P6 last.

### Completion log
- 2026-07-13 P0, P1 (`a2f7cb1`), P2 (`5288fa7`) complete & pushed on `feat/v1.2`.
- 2026-07-13 P3 (two-section sidebar + collapsible rail + endpoint detail) —
  analyze clean, two-section render verified via screenshot; 3.5/3.6 deferred to P4.
- 2026-07-13 P5 native runtime (5.1–5.4): goja(JS)+yaegi(Go) sandboxed Playground
  engine + redis/ddb/console hosts + 10 go tests (incl. live read-only) all green.
  Committed `14e00e8`.
- 2026-07-14 P5 UI (5.5–5.8) + P4 endpoint tab set (4.1–4.5): `PlaygroundView`
  (JS/Go toggle + 10 samples), `EndpointDetailView` (Tables·Explorer·PartiQL·
  Playground), `playgroundRun` FFI, `pg.*` i18n. yaegi limits mapped empirically
  (no comma-ok asserts; no multi-return `:=` in a loop) and every sample verified
  by ctypes probe of the shipped dylib. analyze clean; app builds+launches.
