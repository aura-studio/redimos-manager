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
- [ ] 3.5 Instance tab set trimmed to Configure·Monitor·Logs·Browser·Console
      (move Table/PartiQL/Endpoint to the endpoint view). *(deferred to P4)*
- [ ] 3.6 Local DynamoDB shown under the Endpoints section (kind=local). *(deferred)*
- [x] 3.7 i18n: nav strings added to `i18n.dart` (`nav.instances/endpoints/collapse/
      expand/noneYet`).
- [x] 3.8 **TEST**: `flutter analyze` clean; macOS build + launch → two sections
      render (Instances: local-ddb, new-config · Endpoints: us-east-1 [AWS], local
      [LOCAL], deduped from the configs, with kind badges) — verified via screenshot.
      Collapse rail + endpoint-detail implemented & analyze-clean (click-verify by
      user, screencapture flaky this session). Commit G3.

## Phase 4 — Endpoint Browser (merge Tables+Explorer)

- [ ] 4.1 New `EndpointBrowserView`: left Tables pane (reuse `endpoint_page` list +
      right-click Purge/Recreate/Delete/Browse), right Explorer pane (reuse
      `table_page` Scan/Query + `item_editor`), driven by selected table.
- [ ] 4.2 Wire the endpoint detail (3.4) tab set to Configure·Monitor·Logs +
      Browser + PartiQL (Browser = 4.1).
- [ ] 4.3 AWS endpoint: destructive ops disabled + read-only header; loopback/url
      allow them (reuse existing `awsModeForEndpoint` guard).
- [ ] 4.4 i18n strings for the merged view.
- [ ] 4.5 **TEST**: analyze clean; build; launch → pick endpoint → Browser shows
      table list; click a table → items load; right-click ops present (AWS shows
      read-only); PartiQL runs. Commit G4.

## Phase 5 — Playground (JS + Go)

- [ ] 5.1 native `go.mod`: add `goja` + `yaegi` (pure Go, offline cache); pre-warm.
- [ ] 5.2 `native/playground.go`: `//export rm_playground_run`; host objects
      `redis` (RESP to instance port) / `ddb` (SigV4, reuse ddbtable) / `console`;
      dispatch by `lang` (js→goja, go→yaegi).
- [ ] 5.3 Sandbox: no fs/net beyond the client; `vm.Interrupt` on `timeoutMs`;
      writes re-check the AWS read-only guard; external exec argv-only.
- [ ] 5.4 `native/playground_test.go`: JS sample + Go sample decode a value; a
      long loop is killed by timeout; an AWS write is refused.
- [ ] 5.5 Dart: `native.dart playgroundRun(...)`; `PlaygroundView` (editor +
      output + JS/Go toggle + sample dropdown); reused for instance/endpoint.
- [ ] 5.6 Sample sets (JS + Go): redis (prefix stats / hash export / TTL audit /
      rename / bench) and ddb (scan-aggregate / cross-table copy / conditional
      delete / export JSONL / size histogram / partiql).
- [ ] 5.7 Add Playground tab to both entity tab sets; i18n strings.
- [ ] 5.8 **TEST**: `go test` playground green; launch → run a JS and a Go sample
      → correct output; timeout kills a runaway; AWS write refused. Commit G5.

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
