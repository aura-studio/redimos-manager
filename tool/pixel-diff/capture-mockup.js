// pixel-fidelity-v23 (CP 3.1–3.5) — mockup-side capture via Puppeteer.
// Screenshots the 8 allowlisted v2.3 mockups at 2560×1600 (logical
// 1280×800 @ deviceScaleFactor 2) into out/mockup/<name>.png.
//
// The mockup HTML files are NEVER modified; font + determinism overrides are
// injected at capture time via addStyleTag: STABILIZE_CSS below plus
// config.FONT_CSS (CP 4.12/4.13) which @font-face-loads the bundled
// Inter/JetBrains Mono and points --ui-font/--mono-font at them.
'use strict';

const fs = require('fs');
const path = require('path');
const puppeteer = require('puppeteer');
const config = require('./config');

// Determinism: kill every animation/transition and the text caret so two
// runs of the same page produce identical pixels.
const STABILIZE_CSS = `
  *, *::before, *::after {
    animation: none !important;
    transition: none !important;
    caret-color: transparent !important;
  }
  html, body { width: 100%; height: 100%; overflow: hidden; }
`;

async function captureScreen(page, name) {
  const file = path.join(config.MOCKUP_DIR, `${name}-light.html`);
  await page.goto(`file://${file}`, { waitUntil: 'networkidle0' });
  await page.addStyleTag({ content: STABILIZE_CSS });
  if (config.FONT_CSS) await page.addStyleTag({ content: config.FONT_CSS });
  // Fonts fully loaded AND one painted frame with them before capture.
  await page.evaluate(async () => {
    await document.fonts.ready;
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  });
  const out = path.join(config.OUT_DIR, 'mockup', `${name}.png`);
  await page.screenshot({ path: out, captureBeyondViewport: false });
  // CP 4.13: prove the capture really rendered Inter, never a silent system
  // fallback — body font-family must resolve with Inter FIRST, and the face
  // must actually be loaded.
  await page.evaluate((screen) => {
    const fam = getComputedStyle(document.body).fontFamily;
    const first = fam.split(',')[0].trim().replace(/^["']|["']$/g, '');
    if (first !== 'Inter') {
      throw new Error(
        `${screen}: body font-family head is "${first}" (${fam}), expected Inter`
      );
    }
    if (!document.fonts.check('13px Inter')) {
      throw new Error(`${screen}: Inter face failed document.fonts.check`);
    }
  }, name);
  return out;
}

async function main() {
  config.validateSources();
  fs.mkdirSync(path.join(config.OUT_DIR, 'mockup'), { recursive: true });

  const browser = await puppeteer.launch();
  try {
    const page = await browser.newPage();
    await page.setViewport(config.VIEWPORT);
    for (const name of config.SCREENS) {
      const out = await captureScreen(page, name);
      const png = require('pngjs').PNG.sync.read(fs.readFileSync(out));
      console.log(
        `[capture-mockup] ${name}: ${png.width}x${png.height} -> ${path.relative(process.cwd(), out)}`
      );
    }
  } finally {
    await browser.close();
  }
}

main().catch((e) => {
  console.error('[capture-mockup] failed:', e);
  process.exit(1);
});
