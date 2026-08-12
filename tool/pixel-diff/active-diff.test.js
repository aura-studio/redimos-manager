'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { PNG } = require('pngjs');

const {
  CHANNELS,
  REPORT_FILES,
  comparePair,
  evaluateThresholds,
  loadCaptureRun,
  loadThresholds,
  measureAnchor,
  runActiveDiff,
} = require('./active-diff');
const { SCREENS, THEMES } = require('./reference-manifest');

const ENVIRONMENT = Object.freeze({
  platform: 'darwin test',
  flutter: 'Flutter test',
  fontMode: 'bundled',
});
const VIEWPORT = Object.freeze({ logicalWidth: 1280, logicalHeight: 800, dpr: 2 });
const PHYSICAL = Object.freeze({ width: 2560, height: 1600 });

function temporaryRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'redimos-active-diff-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function png(width, height, rgba = [0, 0, 0, 255]) {
  const image = new PNG({ width, height });
  for (let index = 0; index < image.data.length; index += 4) {
    image.data[index] = rgba[0];
    image.data[index + 1] = rgba[1];
    image.data[index + 2] = rgba[2];
    image.data[index + 3] = rgba[3];
  }
  return image;
}

function fillRect(image, x, y, width, height, rgba) {
  for (let row = y; row < y + height; row++) {
    for (let column = x; column < x + width; column++) {
      const index = (row * image.width + column) * 4;
      for (let channel = 0; channel < 4; channel++) image.data[index + channel] = rgba[channel];
    }
  }
}

function writePng(file, image) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, PNG.sync.write(image));
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function screenEntry(id, theme, approval = 'approved') {
  return {
    id,
    theme,
    file: `references/${id}-${theme}.png`,
    source: 'user-approved-codex-comparison',
    approval,
    regions: [{ id: 'sample', x: 0, y: 0, width: 1, height: 1 }],
  };
}

function manifest(approval = 'approved') {
  return {
    schemaVersion: 1,
    referenceVersion: 'codex-v1',
    viewport: { ...VIEWPORT },
    renderingEnvironment: { ...ENVIRONMENT },
    screens: SCREENS.flatMap((id) => THEMES.map((theme) => screenEntry(id, theme, approval))),
    history: [{
      reason: approval === 'approved' ? 'approved test baseline' : 'candidate test baseline',
      affected: ['all'],
      renderingEnvironment: { ...ENVIRONMENT },
      approval,
      ...(approval === 'approved' ? { reviewer: 'test-reviewer' } : {}),
      recordedAt: '2026-08-12T00:00:00.000Z',
    }],
  };
}

function approvedThresholds(metrics) {
  return {
    schemaVersion: 1,
    referenceVersion: 'codex-v1',
    approval: 'approved',
    reviewer: 'threshold-reviewer',
    reason: 'test-only approved thresholds',
    approvedAt: '2026-08-12T00:00:00.000Z',
    metrics,
  };
}

let solidPhysicalBuffer;
function physicalPngBuffer() {
  if (!solidPhysicalBuffer) solidPhysicalBuffer = PNG.sync.write(png(PHYSICAL.width, PHYSICAL.height, [24, 24, 24, 255]));
  return solidPhysicalBuffer;
}

function activeFixture(t, options = {}) {
  const root = temporaryRoot(t);
  const activeRoot = path.join(root, 'visual-evidence', 'active', 'codex-v1');
  const references = path.join(activeRoot, 'references');
  const runDir = path.join(activeRoot, 'captures', 'run-1');
  const reports = path.join(activeRoot, 'reports');
  fs.mkdirSync(references, { recursive: true });
  fs.mkdirSync(runDir, { recursive: true });
  fs.mkdirSync(reports, { recursive: true });

  const value = manifest(options.approval);
  const commonPng = physicalPngBuffer();
  const files = [];
  for (const entry of value.screens) {
    const name = `${entry.id}-${entry.theme}.png`;
    fs.writeFileSync(path.join(activeRoot, entry.file), commonPng);
    fs.writeFileSync(path.join(runDir, name), commonPng);
    files.push({
      screen: entry.id,
      theme: entry.theme,
      file: name,
      ...PHYSICAL,
      sha256: sha256(path.join(runDir, name)),
    });
  }
  const metadata = {
    schemaVersion: 1,
    referenceVersion: 'codex-v1',
    runNumber: 1,
    capturedAt: '2026-08-12T00:00:00.000Z',
    viewport: { ...VIEWPORT },
    physicalSize: { ...PHYSICAL },
    renderingEnvironment: { ...ENVIRONMENT },
    fixtureRevision: 'a'.repeat(64),
    files,
  };
  const manifestPath = path.join(activeRoot, 'manifest.json');
  const metadataPath = path.join(runDir, 'capture-metadata.json');
  fs.writeFileSync(manifestPath, `${JSON.stringify(value, null, 2)}\n`);
  fs.writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`);
  return { activeRoot, manifestPath, metadata, metadataPath, reports, runDir, value };
}

function metricEntry(regions = [{ id: 'sample', x: 0, y: 0, width: 2, height: 2 }]) {
  return { id: 'inst-browse', theme: 'light', file: 'references/inst-browse-light.png', regions };
}

function decodeForMetric(image) {
  image.depth = 8;
  image.colorType = 6;
  return image;
}

test('reports exact full-frame, independent ROI, and per-channel normalized MAE metrics', () => {
  const reference = decodeForMetric(png(4, 4));
  const actual = decodeForMetric(png(4, 4));
  fillRect(actual, 0, 0, 1, 1, [255, 128, 64, 0]);

  const metrics = comparePair(reference, actual, metricEntry(), 1, {
    expectedPhysical: { width: 4, height: 4 },
  });

  assert.equal(metrics.differingPixels, 1);
  assert.equal(metrics.comparedPixels, 16);
  assert.equal(metrics.fullFrameDiffRatio, 1 / 16);
  assert.equal(metrics.roiDiffRatios.sample.differingPixels, 1);
  assert.equal(metrics.roiDiffRatios.sample.comparedPixels, 4);
  assert.equal(metrics.roiDiffRatios.sample.diffRatio, 1 / 4);
  assert.equal(metrics.channelMAE.sample.r, 1 / 4);
  assert.equal(metrics.channelMAE.sample.g, 128 / (4 * 255));
  assert.equal(metrics.channelMAE.sample.b, 64 / (4 * 255));
  assert.equal(metrics.channelMAE.sample.a, 1 / 4);
});

test('overlapping ROIs are measured independently and do not alter full-frame ratio', () => {
  const reference = decodeForMetric(png(4, 4));
  const actual = decodeForMetric(png(4, 4));
  fillRect(actual, 1, 1, 1, 1, [255, 255, 255, 255]);
  const regions = [
    { id: 'outer', x: 0, y: 0, width: 3, height: 3 },
    { id: 'inner', x: 1, y: 1, width: 2, height: 2 },
  ];

  const metrics = comparePair(reference, actual, metricEntry(regions), 1, {
    expectedPhysical: { width: 4, height: 4 },
  });

  assert.equal(metrics.fullFrameDiffRatio, 1 / 16);
  assert.equal(metrics.roiDiffRatios.outer.diffRatio, 1 / 9);
  assert.equal(metrics.roiDiffRatios.inner.diffRatio, 1 / 4);
});

test('geometry reports logical x/y/width/height deltas from strongest edge gradients', () => {
  const reference = png(32, 24);
  const actual = png(32, 24);
  fillRect(reference, 8, 6, 16, 12, [255, 255, 255, 255]);
  fillRect(actual, 10, 8, 18, 14, [255, 255, 255, 255]);

  const anchor = measureAnchor(reference, actual, { x: 4, y: 3, width: 8, height: 6 }, 2);

  assert.deepEqual(anchor.unmeasurableEdges, []);
  assert.equal(anchor.x, 1);
  assert.equal(anchor.y, 1);
  assert.equal(anchor.width, 1);
  assert.equal(anchor.height, 1);
  assert.equal(anchor.maxAbs, 1);
});

test('geometry distinguishes image boundaries from internal edges with no usable gradient', () => {
  const reference = png(16, 12, [32, 32, 32, 255]);
  const actual = png(16, 12, [32, 32, 32, 255]);

  const boundary = measureAnchor(reference, actual, { x: 0, y: 0, width: 16, height: 12 }, 1);
  const internal = measureAnchor(reference, actual, { x: 2, y: 2, width: 8, height: 6 }, 1);

  assert.deepEqual(boundary.unmeasurableEdges, []);
  assert.equal(boundary.maxAbs, 0);
  assert.deepEqual(internal.unmeasurableEdges, ['left', 'right', 'top', 'bottom']);
});

test('dimension and color-space mismatches fail before metric calculation', () => {
  const reference = decodeForMetric(png(4, 4));
  const wrongSize = decodeForMetric(png(5, 4));
  assert.throws(
    () => comparePair(reference, wrongSize, metricEntry(), 1, { expectedPhysical: { width: 4, height: 4 } }),
    /Dimension mismatch/,
  );

  const wrongColor = decodeForMetric(png(4, 4));
  wrongColor.colorType = 2;
  assert.throws(
    () => comparePair(reference, wrongColor, metricEntry(), 1, { expectedPhysical: { width: 4, height: 4 } }),
    /Color-space mismatch/,
  );
});

test('threshold evaluation fails independently for full-frame, ROI, geometry, channels, and unmeasurable anchors', () => {
  const metrics = {
    fullFrameDiffRatio: 0.2,
    roiDiffRatios: { sample: { diffRatio: 0.3 } },
    geometry: {
      maxGeometryDeviationPx: 2,
      anchors: { sample: { unmeasurableEdges: ['right'] } },
    },
    channelMAE: { sample: { r: 0.4, g: 0, b: 0, a: 0 } },
  };
  const violations = evaluateThresholds(metrics, {
    fullFrameDiffRatio: 0.1,
    roiDiffRatios: 0.1,
    maxGeometryDeviationPx: 1,
    channelMAE: 0.1,
  });

  assert.deepEqual(
    new Set(violations.map((value) => value.metric)),
    new Set([
      'fullFrameDiffRatio',
      'roiDiffRatio',
      'geometryAnchorMeasurability',
      'maxGeometryDeviationPx',
      'channelMAE',
    ]),
  );
});

test('threshold files must be explicitly approved and bound to the manifest reference version', (t) => {
  const root = temporaryRoot(t);
  const thresholdPath = path.join(root, 'thresholds.json');
  const value = manifest();
  fs.writeFileSync(thresholdPath, JSON.stringify(approvedThresholds({ fullFrameDiffRatio: 0.01 })));
  assert.equal(loadThresholds(thresholdPath, value).metrics.fullFrameDiffRatio, 0.01);

  const rejected = approvedThresholds({ fullFrameDiffRatio: 0.01 });
  rejected.approval = 'candidate';
  fs.writeFileSync(thresholdPath, JSON.stringify(rejected));
  assert.throws(() => loadThresholds(thresholdPath, value), /approval must be "approved"/);

  const wrongVersion = approvedThresholds({ fullFrameDiffRatio: 0.01 });
  wrongVersion.referenceVersion = 'other-v1';
  fs.writeFileSync(thresholdPath, JSON.stringify(wrongVersion));
  assert.throws(() => loadThresholds(thresholdPath, value), /does not match manifest/);
});

test('capture run validates 16-pair coverage, dimensions, hashes, viewport, environment, and exact PNG inventory', (t) => {
  const fixture = activeFixture(t);
  assert.equal(
    loadCaptureRun(fixture.runDir, fixture.value, { activeRoot: fixture.activeRoot }).captures.size,
    16,
  );

  const original = JSON.parse(fs.readFileSync(fixture.metadataPath, 'utf8'));
  const cases = [
    ['coverage', (value) => value.files.pop(), /exactly 16 entries/],
    ['dimensions', (value) => { value.files[0].width = 1280; }, /must record 2560x1600/],
    ['hash', (value) => { value.files[0].sha256 = '0'.repeat(64); }, /sha256 mismatch/],
    ['viewport', (value) => { value.viewport.logicalWidth = 1279; }, /viewport must be 1280x800/],
    ['environment', (value) => { value.renderingEnvironment.flutter = 'other'; }, /exactly match/],
  ];
  for (const [name, mutate, expected] of cases) {
    const changed = structuredClone(original);
    mutate(changed);
    fs.writeFileSync(fixture.metadataPath, JSON.stringify(changed));
    assert.throws(
      () => loadCaptureRun(fixture.runDir, fixture.value, { activeRoot: fixture.activeRoot }),
      expected,
      name,
    );
  }
  fs.writeFileSync(fixture.metadataPath, JSON.stringify(original));
  fs.writeFileSync(path.join(fixture.runDir, 'unexpected.png'), physicalPngBuffer());
  assert.throws(
    () => loadCaptureRun(fixture.runDir, fixture.value, { activeRoot: fixture.activeRoot }),
    /must exactly match metadata files/,
  );
});

test('approved manifest without thresholds emits 16 metric sets and writes no reports', (t) => {
  const fixture = activeFixture(t);

  const result = runActiveDiff({
    manifestPath: fixture.manifestPath,
    runDir: fixture.runDir,
  });

  assert.equal(result.passed, null);
  assert.equal(result.thresholds, null);
  assert.equal(result.reportRunRoot, null);
  assert.equal(result.pairs.length, 16);
  assert.ok(result.pairs.every((pair) => pair.passed === null));
  assert.ok(result.pairs.every((pair) => pair.fullFrameDiffRatio === 0));
  assert.deepEqual(fs.readdirSync(fixture.reports), []);
});

test('candidate manifest is rejected before captures are compared or reports are created', (t) => {
  const fixture = activeFixture(t, { approval: 'candidate' });
  assert.throws(
    () => runActiveDiff({ manifestPath: fixture.manifestPath, runDir: fixture.runDir }),
    /unapproved-reference|missing-approval-history/,
  );
  assert.deepEqual(fs.readdirSync(fixture.reports), []);
});

test('capture and report paths cannot escape active directories or enter archive/reference trees', (t) => {
  const fixture = activeFixture(t);
  const outside = path.join(path.dirname(fixture.activeRoot), 'captures', 'run-1');
  fs.mkdirSync(outside, { recursive: true });
  assert.throws(
    () => loadCaptureRun(outside, fixture.value, { activeRoot: fixture.activeRoot }),
    /must stay under the active captures directory/,
  );
  assert.throws(
    () => runActiveDiff({
      manifestPath: fixture.manifestPath,
      runDir: fixture.runDir,
      reportsDir: path.join(fixture.activeRoot, 'references'),
    }),
    /must stay under the active reports directory/,
  );
});

test('threshold failure writes uniquely named expected/actual/diff/metrics artifacts and refuses overwrite', (t) => {
  const fixture = activeFixture(t);
  const changedName = `${SCREENS[0]}-${THEMES[0]}.png`;
  const changedPath = path.join(fixture.runDir, changedName);
  const changed = png(PHYSICAL.width, PHYSICAL.height, [24, 24, 24, 255]);
  changed.data[0] = 255;
  writePng(changedPath, changed);
  const fileMetadata = fixture.metadata.files.find((entry) => entry.file === changedName);
  fileMetadata.sha256 = sha256(changedPath);
  fs.writeFileSync(fixture.metadataPath, `${JSON.stringify(fixture.metadata, null, 2)}\n`);
  const thresholdsPath = path.join(fixture.activeRoot, 'approved-thresholds.json');
  fs.writeFileSync(thresholdsPath, JSON.stringify(approvedThresholds({
    fullFrameDiffRatio: 0,
    roiDiffRatios: { sample: 0 },
    channelMAE: { r: 0, g: 0, b: 0, a: 0 },
  })));

  const result = runActiveDiff({
    manifestPath: fixture.manifestPath,
    runDir: fixture.runDir,
    thresholdsPath,
  });

  assert.equal(result.passed, false);
  assert.equal(result.pairs.filter((pair) => !pair.passed).length, 1);
  assert.equal(path.basename(result.reportRunRoot), 'run-1');
  const failed = result.pairs.find((pair) => !pair.passed);
  assert.deepEqual(new Set(Object.keys(failed.reportFiles)), new Set(REPORT_FILES));
  for (const [kind, file] of Object.entries(failed.reportFiles)) {
    assert.equal(fs.existsSync(file), true, kind);
    assert.match(path.basename(file), new RegExp(`^${SCREENS[0]}-${THEMES[0]}-${kind}\\.(png|json)$`));
  }
  const persisted = JSON.parse(fs.readFileSync(failed.reportFiles.metrics, 'utf8'));
  assert.equal(persisted.fullFrameDiffRatio, 1 / (PHYSICAL.width * PHYSICAL.height));
  assert.ok(persisted.violations.some((value) => value.metric === 'fullFrameDiffRatio'));
  assert.deepEqual(fs.readdirSync(path.join(fixture.activeRoot, 'references')).sort(),
    fixture.value.screens.map((entry) => path.basename(entry.file)).sort());

  assert.throws(
    () => runActiveDiff({
      manifestPath: fixture.manifestPath,
      runDir: fixture.runDir,
      thresholdsPath,
    }),
    /Refusing to overwrite existing failure report run/,
  );
});
