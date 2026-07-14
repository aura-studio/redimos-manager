# Redimos Manager v1.2 — Requirements

> Kiro-style spec, expert mode. requirements → [design](design.md) → [tasks](tasks.md).
> All work in RedimosManager only; the `redimos` server repos are NOT touched.

## Goal

Re-organize the manager around two clear entity types and add scripting, so the
UI stops mixing three unrelated mental models (process ops / Redis client /
DynamoDB storage) as eight flat tabs.

## Functional requirements

- **R1 — Language.** The app supports English and 简体中文, switchable at runtime
  from the top bar, persisted across restarts, first run follows the OS locale.
- **R2 — Theme.** Light / Dark / System, switchable from the top bar, persisted.
  (Already present pre-1.2; keep.)
- **R3 — Two entities.** A former "config" is split into an **Instance** (a
  redimos proxy: port/version/table/process opts) and an **Endpoint** (a DynamoDB
  backend: url/region/credentials). Endpoints are deduplicated by backend so many
  instances can share one; the persisted store uses endpoints[]+instances[].
- **R4 — Migration.** An existing pre-1.2 `store.json` migrates automatically and
  losslessly on first launch; no user action; a downgrade to 1.1.x still works.
- **R5 — Two-section sidebar.** The left sidebar lists **Instances** and
  **Endpoints** in two sections and is collapsible to a narrow rail (persisted).
- **R6 — Per-entity views.** Selecting an instance shows its proxy views
  (Configure/Monitor/Logs + Redis Browser + Console); selecting an endpoint shows
  its storage views (Configure/Monitor/Logs + DynamoDB Browser + PartiQL).
- **R7 — Endpoint Browser.** The endpoint's three former storage tabs
  (Tables/Explorer/PartiQL) become two: **Browser** (a Tables sidebar + an item
  Explorer merged into one view; table lifecycle ops in the Tables right-click)
  and **PartiQL**. AWS endpoints are read-only for destructive ops.
- **R8 — Playground.** Instances and Endpoints each get a **Playground** tab: a
  code editor (JS or Go) whose script gets a `redis` (instance) or `ddb`
  (endpoint) client to run batch operations, with a "sample program" dropdown.
- **R9 — Local DynamoDB.** The Local DynamoDB stops being a special sidebar panel
  and becomes an Endpoint (kind=local) with the same Configure/Monitor/Logs.

## Non-functional / acceptance

- **N1** `flutter analyze` clean and `go vet` clean after every phase.
- **N2** Every phase has explicit tests (unit and/or on-real-data) built into the
  task list; a phase is not "done" until its tests pass.
- **N3** No `redimos` repo change. Custom-formatter / Playground external exec
  never lets redis/DDB data inject a shell command.
- **N4** Milestones committed on branch `feat/v1.2`; final release tags `v1.2.0`
  with macOS + Windows assets (mirrors the v1.1.0 release).
