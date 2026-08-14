# pixel-diff report

> **OFFICIAL PRE-CHANGE BASELINE** (re-archived 2026-08-07, CP 3.11 / task #50).
> Captured BEFORE any visual work of chapters 4–7. `inst-browse` / `inst-console`
> are captured in the mockup's DATA-LOADED state via the in-process fake RESP
> server (`test/fake_resp_server.dart`); the other six screens use static
> fixtures. Every later diff run is compared against this file to quantify
> convergence.
>
> Known data-state divergences by design (mockup decorations with no app-side
> command behind them; also recorded in `test/screen_fixtures.dart`):
> - sidebar count 375 vs mockup 1,024 ("375 keys+"); alphabetical folder order
>   (cache first, not user); folder labels without the ':*' suffix; nested
>   folders for multi-segment keys (user:1004:profile under user/1004;
>   user:1003 below the fold); unopened leaves carry no type badge.
> - keycard has no Encoding row; elapsed shows integer ms (Stopwatch) not the
>   mockup's decimals.
> - console/drawer show real history; KEYS * skipped (would flood 375 lines vs
>   the mockup's folded summary); chips vanish after submit (app logic),
>   mockup shows history + chips together; console crumb shows the fake
>   server's ephemeral port, not 6379; header badge is "RESP" not
>   "RESP3 · 已连接 2h 14m".
> - statusbar / app top bar are app chrome outside the capture boundary
>   (existing structural divergence).
>
> Bugfix landed with this baseline (user-approved, layout-only, zero
> business/data change): `_valueTable` wraps its stretch Column in
> `IntrinsicWidth` — under the horizontal ScrollView the Column received an
> unbounded width and forced it onto every row (hard layout crash; any
> collection key opened in the real app hit the same bug).

- hostname: FEVMFN60G-V2-WE
- timestamp: 2026-08-07T15:21:45.396Z
- flutter: Flutter 3.44.5 • channel stable • https://github.com/flutter/flutter.git
- chrome (puppeteer bundled): mac-151.0.7922.71
- font hashes: Inter=not embedded yet (system fonts) / JetBrainsMono=not embedded yet (system fonts)
- thresholds: text=UNCALIBRATED roi=UNCALIBRATED

| screen | diffRatio | threshold | pass | rail | midBar | cardHead | tableHead | colors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| inst-browse | 9.28% | — | — | 92.71% | 24.37% | 5.96% | 7.24% | ✗ |
| inst-console | 8.69% | — | — | 94.35% | 17.77% | 2.20% | 0.25% | ✗ |
| inst-monitor | 8.46% | — | — | 95.51% | 17.97% | 5.03% | 2.95% | ✗ |
| inst-logs | 8.25% | — | — | 95.59% | 17.04% | 6.10% | 4.53% | ✗ |
| inst-playground | 7.69% | — | — | 95.93% | 17.40% | 5.43% | 1.52% | ✗ |
| inst-config | 11.19% | — | — | 95.14% | 18.37% | 7.76% | 5.29% | ✗ |
| ep-overview | 8.62% | — | — | 95.59% | 19.40% | 7.56% | 1.08% | ✗ |
| ep-browser | 7.88% | — | — | 95.31% | 20.96% | 3.28% | 3.55% | ✗ |

## Per-screen detail

### inst-browse

- diffPixels: 380063 / 4096000 (9.28%)
- heatmap: diff/inst-browse-diff.png
  - ROI rail: 92.71% (threshold —)
  - ROI midBar: 24.37% (threshold —)
  - ROI cardHead: 5.96% (threshold —)
  - ROI tableHead: 7.24% (threshold —)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(246,247,249,255) → DIFFERS
  - color contentBg: mockup rgba(246,247,249,255) vs flutter rgba(246,247,249,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal

### inst-console

- diffPixels: 355785 / 4096000 (8.69%)
- heatmap: diff/inst-console-diff.png
  - ROI rail: 94.35% (threshold —)
  - ROI midBar: 17.77% (threshold —)
  - ROI cardHead: 2.20% (threshold —)
  - ROI tableHead: 0.25% (threshold —)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(246,247,249,255) → DIFFERS
  - color contentBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal

### inst-monitor

- diffPixels: 346708 / 4096000 (8.46%)
- heatmap: diff/inst-monitor-diff.png
  - ROI rail: 95.51% (threshold —)
  - ROI midBar: 17.97% (threshold —)
  - ROI cardHead: 5.03% (threshold —)
  - ROI tableHead: 2.95% (threshold —)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(255,255,255,255) → DIFFERS
  - color contentBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal

### inst-logs

- diffPixels: 337921 / 4096000 (8.25%)
- heatmap: diff/inst-logs-diff.png
  - ROI rail: 95.59% (threshold —)
  - ROI midBar: 17.04% (threshold —)
  - ROI cardHead: 6.10% (threshold —)
  - ROI tableHead: 4.53% (threshold —)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(246,247,249,255) → DIFFERS
  - color contentBg: mockup rgba(244,246,248,255) vs flutter rgba(246,247,249,255) → DIFFERS
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal

### inst-playground

- diffPixels: 314832 / 4096000 (7.69%)
- heatmap: diff/inst-playground-diff.png
  - ROI rail: 95.93% (threshold —)
  - ROI midBar: 17.40% (threshold —)
  - ROI cardHead: 5.43% (threshold —)
  - ROI tableHead: 1.52% (threshold —)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(255,255,255,255) → DIFFERS
  - color contentBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal

### inst-config

- diffPixels: 458300 / 4096000 (11.19%)
- heatmap: diff/inst-config-diff.png
  - ROI rail: 95.14% (threshold —)
  - ROI midBar: 18.37% (threshold —)
  - ROI cardHead: 7.76% (threshold —)
  - ROI tableHead: 5.29% (threshold —)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(255,255,255,255) → DIFFERS
  - color contentBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(246,247,249,255) → DIFFERS

### ep-overview

- diffPixels: 353180 / 4096000 (8.62%)
- heatmap: diff/ep-overview-diff.png
  - ROI rail: 95.59% (threshold —)
  - ROI midBar: 19.40% (threshold —)
  - ROI cardHead: 7.56% (threshold —)
  - ROI tableHead: 1.08% (threshold —)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(255,255,255,255) → DIFFERS
  - color contentBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(247,243,235,255) → DIFFERS

### ep-browser

- diffPixels: 322607 / 4096000 (7.88%)
- heatmap: diff/ep-browser-diff.png
  - ROI rail: 95.31% (threshold —)
  - ROI midBar: 20.96% (threshold —)
  - ROI cardHead: 3.28% (threshold —)
  - ROI tableHead: 3.55% (threshold —)
  - color railBg: mockup rgba(13,19,45,255) vs flutter rgba(237,239,243,255) → DIFFERS
  - color contentBg: mockup rgba(255,255,255,255) vs flutter rgba(255,255,255,255) → equal
  - color topbarBg: mockup rgba(255,255,255,255) vs flutter rgba(246,247,249,255) → DIFFERS
