// pixel-fidelity-v23 — central config for the pixel-diff pipeline (CP 1.4–1.9).
'use strict';

const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');

// Absolute path on purpose: the v2.3 mockups live OUTSIDE the repo
// (review blocker B5). Never a relative path, never a glob.
const MOCKUP_DIR = '/Users/tony/Documents/Claude/redis-ui-mockups/v2/pages2';

// Explicit 8-screen allowlist. The same directory also holds 4 depth
// variants (depth-a/b/c/d-*-light.html) which MUST stay excluded.
const SCREENS = [
  'inst-browse',
  'inst-console',
  'inst-monitor',
  'inst-logs',
  'inst-playground',
  'inst-config',
  'ep-overview',
  'ep-browser',
];

// Logical 1280×800 at DPR 2 → physical 2560×1600 on BOTH sides.
// Flutter side mirrors test/golden_screens_test.dart:
//   tester.view.physicalSize = Size(2560, 1600); devicePixelRatio = 2;
const VIEWPORT = { width: 1280, height: 800, deviceScaleFactor: 2 };
const PHYSICAL = {
  width: VIEWPORT.width * VIEWPORT.deviceScaleFactor,
  height: VIEWPORT.height * VIEWPORT.deviceScaleFactor,
};

const OUT_DIR = path.join(__dirname, 'out');

// Regions of interest, LOGICAL coordinates (×deviceScaleFactor at crop time).
// rail / midBar derive from Dim constants (railW=64, topBarH=48, midBarH=44).
// cardHead / tableHead are approximate bands on the instance content area
// (content starts at x = railW+sidebarW = 344, y = topBarH+midBarH = 92);
// refined against real captures during threshold calibration (CP 8.5).
const ROIS = [
  { name: 'rail', x: 0, y: 0, w: 64, h: 800 },
  { name: 'midBar', x: 64, y: 48, w: 1216, h: 44 },
  { name: 'cardHead', x: 344, y: 106, w: 886, h: 46 },
  { name: 'tableHead', x: 344, y: 168, w: 886, h: 30 },
];

// Thresholds. Calibrated in CP 8.x (out/noise-floor.md): noise floor =
// inter-run spread of the SAME build (≤0.003%), so the 3% lower bound
// dominates everywhere. NOTE: rail/midBar currently fail hard at ~95%/~20%
// — that is the structural capture-channel chrome absence, the target of
// CP 9.x round 1, not noise.
const THRESHOLDS = {
  text: 0.03,
  roi: { rail: 0.03, midBar: 0.03, cardHead: 0.03, tableHead: 0.03 },
  geometryPx: 1,
  colorTolerance: 0,
};

// pixelmatch options, fixed by requirements 2.5.
const PIXELMATCH_OPTS = { threshold: 0.15, includeAA: false };

// Pure-color sample points (logical coordinates) for the channel-exact color
// assertion (requirements 3.2). Chosen on guaranteed-flat surfaces common to
// every screen: rail column, content background, midbar band. contentBg sits
// at y=758: on inst-logs the mockup's logs-body bottom border (y761) bleeds a
// 1px AA blend into y760, so 760 is NOT flat on the mockup side; 758 is pure
// panel-2 on both sides and stays on flat surfaces on every other screen.
const COLOR_SAMPLES = [
  { name: 'railBg', x: 32, y: 620 },
  { name: 'contentBg', x: 900, y: 758 },
  { name: 'topbarBg', x: 900, y: 24 }, // x=700 lands on flutter's topbar text
  // after the CP 9.x mono fix reflowed it; 725–1160 is flat white on BOTH
  // sides across all 8 screens (CP 9.x inst-browse round 1).
];

// Font/style CSS injected into the mockup at capture time (CP 4.12/4.13).
// The mockups are captured by an app build that ships Inter + JetBrains Mono
// (assets/fonts/, registered in pubspec.yaml), so the mockup side loads the
// SAME two variable faces via @font-face and points the --ui-font/--mono-font
// custom properties at them. The injected <style> is appended after the page's
// own, so its :root block wins the cascade. Never modifies the mockup HTML.
const FONT_DIR = path.join(__dirname, '..', '..', 'assets', 'fonts');
const INTER_TTF = path.join(FONT_DIR, 'Inter-Variable.ttf');
const JETBRAINS_MONO_TTF = path.join(FONT_DIR, 'JetBrainsMono-Variable.ttf');
const FONT_CSS = `
@font-face {
  font-family: 'Inter';
  src: url('${pathToFileURL(INTER_TTF).href}') format('truetype');
  font-weight: 100 900;
  font-style: normal;
  font-display: block;
}
@font-face {
  font-family: 'JetBrains Mono';
  src: url('${pathToFileURL(JETBRAINS_MONO_TTF).href}') format('truetype');
  font-weight: 100 900;
  font-style: normal;
  font-display: block;
}
:root {
  --ui-font: Inter, 'PingFang SC', sans-serif;
  --mono-font: 'JetBrains Mono', monospace;
}
`;

// Fail fast (CP 1.9/1.10): never silently skip a missing mockup source.
function validateSources() {
  const problems = [];
  if (!fs.existsSync(MOCKUP_DIR)) {
    problems.push(`mockup dir missing: ${MOCKUP_DIR}`);
  } else {
    for (const s of SCREENS) {
      const f = path.join(MOCKUP_DIR, `${s}-light.html`);
      if (!fs.existsSync(f)) problems.push(`missing mockup file: ${f}`);
    }
  }
  if (problems.length) {
    console.error('[pixel-diff] source validation failed:');
    for (const p of problems) console.error('  - ' + p);
    process.exit(1);
  }
  // CP 4.12: the injected @font-face src URLs must resolve — never capture
  // with silently-unloaded fonts.
  for (const f of [INTER_TTF, JETBRAINS_MONO_TTF]) {
    if (!fs.existsSync(f)) {
      console.error(`[pixel-diff] bundled font missing: ${f}`);
      process.exit(1);
    }
  }
  return true;
}

module.exports = {
  MOCKUP_DIR,
  SCREENS,
  VIEWPORT,
  PHYSICAL,
  OUT_DIR,
  ROIS,
  THRESHOLDS,
  PIXELMATCH_OPTS,
  COLOR_SAMPLES,
  FONT_CSS,
  validateSources,
};
