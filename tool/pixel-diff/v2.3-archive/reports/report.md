# pixel-diff report

- hostname: FEVMFN60G-V2-WE
- timestamp: 2026-08-07T22:54:02.467Z
- flutter: Flutter 3.44.5 • channel stable • https://github.com/flutter/flutter.git
- chrome (puppeteer bundled): mac-151.0.7922.71
- font hashes: Inter=4989b125924991b9 / JetBrainsMono=3cfafa86e28b8718
- thresholds: text=0.03 roi={"rail":0.03,"midBar":0.03,"cardHead":0.03,"tableHead":0.03}

| screen | diffRatio | threshold | pass | rail | midBar | cardHead | tableHead | colors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| inst-browse | 3.86% | 0.03 | ✗ | 1.96% | 2.79% | 2.24% | 6.14% | ✓ |
| inst-console | 2.27% | 0.03 | ✓ | 1.96% | 1.08% | 2.16% | 0.87% | ✓ |
| inst-monitor | 2.68% | 0.03 | ✗ | 1.96% | 1.07% | 3.09% | 1.88% | ✓ |
| inst-logs | 2.85% | 0.03 | ✗ | 1.96% | 1.09% | 4.44% | 6.41% | ✓ |
| inst-playground | 2.10% | 0.03 | ✗ | 1.96% | 1.08% | 3.94% | 1.53% | ✓ |
| inst-config | 2.40% | 0.03 | ✓ | 1.96% | 1.02% | 2.36% | 0.27% | ✓ |
| ep-overview | 3.03% | 0.03 | ✗ | 2.03% | 0.97% | 10.82% | 1.31% | ✓ |
| ep-browser | 2.78% | 0.03 | ✗ | 2.03% | 2.47% | 6.31% | 5.47% | ✓ |

## Convergence (baseline ↔ final)

Baseline = official pre-change capture archived in `baseline-report.md` (CP 3.11: before any chapter 4–7 visual work; fonts not embedded, no capture-channel chrome). Final = this run. Reduction = baseline ÷ final diffRatio.

| screen | baseline | final | reduction | verdict |
| --- | --- | --- | --- | --- |
| inst-browse | 9.28% | 3.86% | 2.40× | residual — see Residuals |
| inst-console | 8.69% | 2.27% | 3.83× | PASS |
| inst-monitor | 8.46% | 2.68% | 3.16× | residual — see Residuals |
| inst-logs | 8.25% | 2.85% | 2.90× | residual — see Residuals |
| inst-playground | 7.69% | 2.10% | 3.67× | residual — see Residuals |
| inst-config | 11.19% | 2.40% | 4.66× | PASS |
| ep-overview | 8.62% | 3.03% | 2.85× | residual — see Residuals |
| ep-browser | 7.88% | 2.78% | 2.84× | residual — see Residuals |

Cross-screen: rail ROI 92.71–95.93% → 1.96–2.03%; midBar 17.04–24.37% → 0.97–2.79%; channel-exact color checks: every screen failing → all passing; full-frame 7.69–11.19% → 2.10–3.86%, with 2/8 screens PASS under the calibrated 3% text + per-ROI thresholds.

## Known exemptions

- CJK text (e.g. inst-config 「实例标识 / 上游连接」): Inter/JetBrains Mono bundle no CJK glyphs, so BOTH sides fall back to the host's PingFang SC — mockup via Chrome resolving `--ui-font: Inter, 'PingFang SC', …`, Flutter capture via `test/golden_fonts.dart` registering the host PingFang (the same face the real app's `Ts.sans` fallback resolves at runtime). Residual diff confined to these CJK runs is an exempt divergence of rasterization, not a stack bug (CP 4.15).

## Residuals (CP 9.9 closeout, 2026-08-08)

Final state: 2/8 screens PASS (inst-config, inst-console). The six failing screens below carry residual diffs that need design- or data-level decisions, not more style tuning. Root cause + escalation per screen; the full round-by-round ledger lives in `convergence-plan.md` (survives regeneration, unlike this file).

- **inst-browse** (tableHead 6.14✗): keycard head floats ~20px vs mockup (app lacks the ktabs/meta block); left tree is alphabetical with real counts vs the mockup's curated order; extra Copy-as-command button. Escalation: rebuild keycard head per `.keycard` (design decision).
- **ep-overview** (cardHead 10.82✗): banner note renders in the app EN locale but the mockup is a zh design comp; CJK runs double-shadowed (exempt class); 本/测/中 paint as solid boxes in capture (isolated test-env glyph anomaly). Escalation: embed one CJK webfont (e.g. Noto Sans SC) both sides, or formalize a language exemption.
- **inst-logs** (cardHead 4.44✗ / tableHead 6.41✗): chip counts show live line counts vs mockup cumulative values; `<b>` bold runs missing (Text.rich boxes glyphs under widget-test capture); ~2px column/vertical offset. Escalation: seed counts, rebuild bold runs as TextSpans, padding probe.
- **ep-browser** (cardHead 6.31✗ / tableHead 5.47✗): feature chrome the mockup omits (pager, gear, Actions/Create — kept, not a bug); column widths auto vs mockup fixed; rowact ✎⧉⌫ absent; ⛁ tofu. Escalation: ⛁→Icons.storage (mechanical), map fixed widths, chrome trim is a product call.
- **inst-monitor** (cardHead 3.09✗, misses by 0.09): sectionHeader hairline sits 2-3px below the mockup `.section-head::after`. Escalation: re-probe `.section-head` alignment globally, then re-baseline inst-config + inst-monitor together (shared component — left untouched to protect the inst-config pass).
- **inst-playground** (cardHead 3.94✗): pre-run state (mockup shows 上次运行 08:12:44 · 128 ms + an enabled Run; capture shows a disabled Run, no last-run row); header Sample program vs 示例 · hash-crud.js. Escalation: seed a last-run state param; sample naming needs an i18n-key decision (no-new-key constraint).

## Per-screen detail

### inst-browse

- diffPixels: 158078 / 4096000 (3.86%)
- heatmap: diff/inst-browse-diff.png
  - ROI rail: 1.96% (threshold 0.03)
  - ROI midBar: 2.79% (threshold 0.03)
  - ROI cardHead: 2.24% (threshold 0.03)
  - ROI tableHead: 6.14% (threshold 0.03)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(13,19,45,255) → equal
  - color contentBg: mockup rgba(246,247,249,255) vs flutter rgba(246,247,249,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal

### inst-console

- diffPixels: 92847 / 4096000 (2.27%)
- heatmap: diff/inst-console-diff.png
  - ROI rail: 1.96% (threshold 0.03)
  - ROI midBar: 1.08% (threshold 0.03)
  - ROI cardHead: 2.16% (threshold 0.03)
  - ROI tableHead: 0.87% (threshold 0.03)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(13,19,45,255) → equal
  - color contentBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal

### inst-monitor

- diffPixels: 109807 / 4096000 (2.68%)
- heatmap: diff/inst-monitor-diff.png
  - ROI rail: 1.96% (threshold 0.03)
  - ROI midBar: 1.07% (threshold 0.03)
  - ROI cardHead: 3.09% (threshold 0.03)
  - ROI tableHead: 1.88% (threshold 0.03)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(13,19,45,255) → equal
  - color contentBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal

### inst-logs

- diffPixels: 116571 / 4096000 (2.85%)
- heatmap: diff/inst-logs-diff.png
  - ROI rail: 1.96% (threshold 0.03)
  - ROI midBar: 1.09% (threshold 0.03)
  - ROI cardHead: 4.44% (threshold 0.03)
  - ROI tableHead: 6.41% (threshold 0.03)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(13,19,45,255) → equal
  - color contentBg: mockup rgba(246,247,249,255) vs flutter rgba(246,247,249,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal

### inst-playground

- diffPixels: 85925 / 4096000 (2.10%)
- heatmap: diff/inst-playground-diff.png
  - ROI rail: 1.96% (threshold 0.03)
  - ROI midBar: 1.08% (threshold 0.03)
  - ROI cardHead: 3.94% (threshold 0.03)
  - ROI tableHead: 1.53% (threshold 0.03)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(13,19,45,255) → equal
  - color contentBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal

### inst-config

- diffPixels: 98254 / 4096000 (2.40%)
- heatmap: diff/inst-config-diff.png
  - ROI rail: 1.96% (threshold 0.03)
  - ROI midBar: 1.02% (threshold 0.03)
  - ROI cardHead: 2.36% (threshold 0.03)
  - ROI tableHead: 0.27% (threshold 0.03)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(13,19,45,255) → equal
  - color contentBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal

### ep-overview

- diffPixels: 123948 / 4096000 (3.03%)
- heatmap: diff/ep-overview-diff.png
  - ROI rail: 2.03% (threshold 0.03)
  - ROI midBar: 0.97% (threshold 0.03)
  - ROI cardHead: 10.82% (threshold 0.03)
  - ROI tableHead: 1.31% (threshold 0.03)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(13,19,45,255) → equal
  - color contentBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal

### ep-browser

- diffPixels: 113822 / 4096000 (2.78%)
- heatmap: diff/ep-browser-diff.png
  - ROI rail: 2.03% (threshold 0.03)
  - ROI midBar: 2.47% (threshold 0.03)
  - ROI cardHead: 6.31% (threshold 0.03)
  - ROI tableHead: 5.47% (threshold 0.03)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(13,19,45,255) → equal
  - color contentBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal
