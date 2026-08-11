# pixel-fidelity-v23 — convergence plan (CP 9.1)

Final numbers after per-screen rounds (CP 9.9 closeout, 2026-08-08):
**2/8 screens PASS — inst-config, inst-console.** Order = diffRatio descending.

| # | screen | diffRatio | rail | midBar | cardHead | tableHead | colors |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | inst-browse | 3.86% | 1.96 ✓ | 2.79 ✓ | 2.24 ✓ | 6.14 ✗ | ✓ |
| 2 | ep-overview | 3.03% | 2.03 ✓ | 0.97 ✓ | 10.82 ✗ | 1.31 ✓ | ✓ |
| 3 | inst-logs | 2.85% | 1.96 ✓ | 1.09 ✓ | 4.44 ✗ | 6.41 ✗ | ✓ |
| 4 | ep-browser | 2.78% | 2.03 ✓ | 2.47 ✓ | 6.31 ✗ | 5.47 ✗ | ✓ |
| 5 | inst-monitor | 2.68% | 1.96 ✓ | 1.07 ✓ | 3.09 ✗ | 1.88 ✓ | ✓ |
| 6 | inst-config | **2.40% PASS** | 1.96 ✓ | 1.02 ✓ | 2.36 ✓ | 0.27 ✓ | ✓ |
| 7 | inst-console | **2.27% PASS** | 1.96 ✓ | 1.08 ✓ | 2.16 ✓ | 0.87 ✓ | ✓ |
| 8 | inst-playground | 2.10% | 1.96 ✓ | 1.08 ✓ | 3.94 ✗ | 1.53 ✓ | ✓ |

## Cross-cutting rounds (already applied, all screens)

- **R1 — capture-channel chrome** (Option E): `HomeChrome` wraps the content
  screens in the capture channel only; rail / midBar / statusbar / entity
  sidebar now present. Fixed three chrome overflow bugs the wrapper exposed
  (rail label FittedBox, ep-browser scan-filter compact, browse key-header
  compact). 9–11% → 2.4–4.8%.
- **R2 — logs geometry + midbar tab gap**: `.logs-body` card geometry aligned
  (toolbar 32→42 matching mockup `.logs-toolbar`, removed the legacy 22px
  status strip — v2.3 has the global statusbar instead); midBar tabs gained
  the mockup `.mtabs gap:4`.
- **R2.5 — copy alignment via EXISTING i18n keys (no new keys)**: instance
  tab now uses `ep.browse` ('Browse') while the endpoint tab keeps
  `tab.browser` ('Browser') — mockups use different words per screen;
  `config.new` value aligned to the mockup button ('Instance' / 新建实例);
  `contentBg` sample moved y760→758 (760 sat on the mockup's 1px border AA
  blend — not a flat surface, violating the sample-point contract).
- **R3 — test-env fonts**: registered the SDK's MaterialIcons in
  `golden_fonts.dart` (widget tests rendered every Icon as a tofu box);
  moved button label styling from `FilledButton.styleFrom(textStyle:)` to an
  explicit `Text(style: Ts.style(...))` — the styleFrom chain resolves to the
  blocky fallback face in widget tests (proven by a 4-variant scratch test:
  styleFrom-textStyle = block bar, explicit label style = correct Inter).
  Fixed sites: home_chrome sidebar button + chromeCta, browser_page New Key,
  playground_page Run, partiql_page Run.

## Per-screen rounds

(appended as each screen is worked; ≤3 rounds each, residuals recorded with
root cause + escalation note per CP 9.9)

### inst-config — 4.71% → 3.22% → 2.47% → **2.40% PASS** (2 rounds)
- round 1 (4.71→3.22): transient controllers seeded with mockup values
  (group=production, host=127.0.0.1, db=3, ttl=300); switch captions aligned
  (不启用明文连接/可写/使用远端), _writeThrough default ON; _fLabel line-box
  14/11; Ts.style monoFont now sets primary fontFamily (was fallback-only →
  values rendered Inter; tableHead 7.46→0.27); requirepass fixture 10 chars.
- round 2 (3.22→2.47): _switchField row 30→19 (mockup .f-inline is
  switch-high) — removed S2's +22ph overshoot that mis-set every card border
  below (S2 19.7k→5.0k, three full-width hot lines gone). Shared: _midBar
  bottom border hairline→border (mockup --border); sidebar New button +
  chromeCta restyled to mockup .pbtn (32h, radius 6, pad 14; FilledButton
  default pill was wrong).
- residuals (accepted): S3 lacks mockup Proxy-port field / S4 carries extra
  persisted fields (model semantics); topbar crumb vs dropdown; action-bar
  copy (Revert/Delete instance/Save changes + dirty note); statusbar right
  metrics; sidebar card sub format / INST chip / search placeholder; one CJK
  tofu glyph (test-env only); tab group ~5ph right of mockup centre.
- closeout note: final 2.40% measured at CP 9.9 after the shared midBar/chrome
  tweaks landed (midBar 2.04→1.02); all four ROIs under the 3% line.

### inst-console — 3.44% → 2.27% **PASS** (2 rounds)
- round 2 (fixture seed): `pumpInstConsoleLoaded` runs against the fake RESP
  server — `instanceName 'prod-redis-01'`, `connectedLabel '2h 14m'`,
  `initialDb: 3`, mockup command history (KEYS * excluded by design: it would
  flood the stream with 375 lines).
- round 3 (geometry): toolbar 42h (mockup `.console-toolbar`), instance chip
  28h (`.inst-crumb` inline height), stream padding 18/14 (`.console-stream`).
  cardHead 2.96→2.16, tableHead→0.87, total 3.44→2.27 → every ROI ≤3%.
- residuals (accepted): stream prompt renders `127.0.0.1:<port>[3]>` where the
  mockup shows `❯` (inside the tableHead budget).

### inst-browse — 3.86% (tableHead 6.14✗; rail/midBar/cardHead ✓)
- rounds: R1–R3 shared chrome + probe-only rounds; the loaded-state pump
  (`pumpInstBrowseLoaded`: db3, user:1001 hash tab + queue:email_jobs ktabs,
  CLI drawer with HGETALL/TTL history) landed under task #50.
- residuals (accepted): right-pane keycard head floats ~20px above the mockup
  (app head lacks the ktabs/key-meta block — no Encoding row); left tree is
  alphabetical with real counts vs the mockup's curated star order (user:*
  first) + ':*' suffixes; 'Copy as command' button has no mockup counterpart
  (kept — functional surface).
- escalation: rebuild the keycard head per mockup `.keycard` (design-level
  decision); tree order needs a product call on curated-vs-scan ordering.

### inst-monitor — 2.68% (cardHead 3.09✗, misses by 0.09)
- round 2 (fixture seed): `mockSparkCpu/Mem/Ops` inverted from the mockup svg
  paths; `fixtureStatus` 412 MB / 1,208 ops / 0.4 ms / uptime 2h 14m;
  SparkTile big values mono (mockup `.st-top b` 20/700 mono tabular).
- round 3 (painter): sparkline min-max normalization + topInset 12 / botInset
  14 — the old max→y=0 pinned peaks to the box top; mockup paths keep ~14px
  headroom.
- residuals (accepted): `sectionHeader` hairline sits 2–3px below the mockup
  `.section-head::after` (~842 hot px) and the eyebrow text ~1px — shared
  component (inst-config PASS and ddb_views draw from it), deliberately not
  moved to protect the inst-config pass.
- escalation: re-probe `.section-head` alignment globally, then re-baseline
  inst-config + inst-monitor together.

### ep-overview — 3.03% (cardHead 10.82✗)
- round 3 attempt: translating the banner note to Chinese REGRESSED
  (solid-box glyphs in capture + the real EN app would show zh) → reverted to
  HEAD i18n values; divergence recorded as a language/design exemption.
- residuals (accepted): banner note language — app EN locale shows the English
  copy, mockup is the zh design comp; CJK runs double-shadowed (exempt class,
  CP 4.15); the 本/测/中 glyphs paint as solid boxes in capture — isolated
  test-channel glyph anomaly, root cause unresolved (not present in the real
  app render).
- escalation: embed the same CJK webfont (e.g. Noto Sans SC) on both channels
  or formalize the language exemption; the black-box glyphs need a font
  coverage probe.

### ep-browser — 2.78% total ✓ (cardHead 6.31✗ / tableHead 5.47✗)
- rounds: chrome/shared fixes + probe-only.
- residuals (accepted): feature chrome the mockup omits — pager '6 ⟳ < 1',
  gear, Actions/Create buttons (kept: removing = functional regression, and
  the business surface is off-limits); sidebar title truncation 'U…'; column
  widths auto vs mockup fixed w-180/w-120; rowact ✎ ⧉ ⌫ absent from capture;
  ⛁ glyph tofu.
- escalation: ⛁ → Icons.storage (mechanical); column-width mapping is
  mechanical; trimming the chrome is a product decision.

### inst-logs — 2.85% (cardHead 4.44✗ / tableHead 6.41✗)
- rounds: R2 logs geometry (toolbar 42h, legacy status strip removed) +
  probe-only.
- residuals (accepted): chip counts show live line counts vs the mockup's
  cumulative values; the `<b>` bold runs are missing — Text.rich boxes glyphs
  under widget-test capture, so the `<b>` segments render as plain Text;
  ~2px column/vertical offset.
- escalation: seed counts in the fixture; rebuild bold segments as TextSpans
  inside a Row; padding probe.

### inst-playground — 2.10% total ✓ (cardHead 3.94✗)
- rounds: R3 Run-button restyle + probe-only.
- residuals (accepted): pre-run state — mockup shows '● 上次运行 08:12:44 ·
  128 ms' with an enabled Run, capture shows a disabled Run and no last-run
  row; editor header 'Sample program' vs mockup '示例 · hash-crud.js'; editor
  CJK comment lines exempt.
- escalation: seed a last-run state param; sample naming needs an i18n-key
  change (blocked by the no-new-key constraint — needs a decision).

## Residuals / exemptions ledger

- CJK runs (known exemption, CP 4.15).
- rail active item: mockup shows an orange underline accent under the active
  rail icon; app rail has no underline. Within rail ROI threshold (2.0%);
  left as residual unless a per-screen round needs the budget.
- midBar 1px top/bottom border alignment (~188px/band constant) — shared
  residual, below per-screen fix priority.
- `sectionHeader` hairline 2–3px below mockup `.section-head::after` — shared
  across inst-monitor (its cardHead miss), inst-config, and ddb_views. Left
  untouched to protect the inst-config PASS; revisit with a joint re-baseline.
- Feature-chrome overflow class (ep-browser pager/gear/Actions/Create;
  inst-browse 'Copy as command'): the mockups are trimmed comps; the app keeps
  the functional surfaces (business-logic-unchanged constraint).
- ep-overview banner language: EN app copy vs the zh design comp — a
  language/design exemption, not a stack bug.
- Capture-channel glyph anomalies: ep-overview 本/测/中 solid boxes; Text.rich
  boxing (inst-logs bold runs). Test-environment only.
- report.md is regenerated on every diff run — this file is the durable
  per-screen ledger; the diff template also emits a compact CP 9.9 residuals
  section pointing here.

## CP 11 live-app verification (2026-08-08)

- 11.1–11.2: `flutter build macos --debug` (single pass); re-inserted the #38
  screenshot hook (REDIMOS_SHOT / REDIMOS_SHOT_DIR / REDIMOS_SHOT_WAIT + a
  RepaintBoundary around HomeChrome + REDIMOS_INITIAL_ENDPOINT /
  REDIMOS_INITIAL_EPSCREEN companions), captured all 8 screens at pixelRatio
  2.0 into ~/Documents/Claude/app-shots-0808; each run wrote its PNG and
  exited 0 — no orphan processes left behind.
- 11.3: Inter / JetBrains Mono read correctly in the real render (labels,
  mono values, tab underlines) — the SF→Inter swap is acceptable on all 8
  screens.
- 11.4: tile drop shadows + 1px top inset highlights give the intended
  halved-depth read on sidebar cards and content tiles; no flat-tile or
  double-shadow regression.
- 11.5: rail / sidebar / midbar tabs / statusbar / CTA surfaces and the
  empty-, error- and data-states are all intact (browse/playground
  not-running, console failed-to-start, logs with live ERROR lines and
  自动滚动/导出/清空 rendering real CJK perfectly — confirming the
  capture-channel solid-box glyphs are an isolated test-env anomaly, not a
  shipping defect). Interaction coverage comes from the full widget suite.
- 11.6: hook removed by manual edits only (git checkout lib/main.dart
  forbidden — the file carries uncommitted work); grep shows zero TEMP
  remnants with the pre-existing REDIMOS_INITIAL_TAB / REDIMOS_INITIAL_INSTANCE
  debug hooks intact; flutter analyze clean; flutter test +45 ~1 all green.
- 11.7: report.md now carries the four verdict classes (text 3%, per-ROI 3%,
  channel-exact colors), heatmap paths, env fingerprint, and the new
  baseline↔final convergence table; this file remains the durable ledger.
