'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { PNG } = require('pngjs');

const {
  THRESHOLD_POLICY,
  calculatePairwiseNoise,
  loadNoiseRuns,
  measureNoiseFloor,
  summarizeThresholdConstraints,
  validateNoisePlan,
  validateThresholdProposal,
} = require('./noise-floor');

const ENVIRONMENT = Object.freeze({
  platform: 'darwin test',
  flutter: 'Flutter test',
  fontMode: 'bundled',
});
const VIEWPORT = Object.freeze({ logicalWidth: 1280, logicalHeight: 800, dpr: 2 });
const PHYSICAL = Object.freeze({ width: 2560, height: 1600 });
const SHA = 'a'.repeat(64);

function temporaryRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'redimos-noise-floor-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function image(width, height, rgba = [0, 0, 0, 255]) {
  const png = new PNG({ width, height });
  for (let index = 0; index < png.data.length; index += 4) {
    png.data[index] = rgba[0];
    png.data[index + 1] = rgba[1];
    png.data[index + 2] = rgba[2];
    png.data[index + 3] = rgba[3];
  }
  return png;
}

function setPixel(png, x, y, rgba) {
  const index = (y * png.width + x) * 4;
  for (let channel = 0; channel < 4; channel++) png.data[index + channel] = rgba[channel];
}

function writePng(file, png) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, PNG.sync.write(png));
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function screenEntry() {
  return {
    id: 'inst-browse',
    theme: 'light',
    file: 'references/inst-browse-light.png',
    source: 'user-approved-codex-comparison',
    approval: 'candidate',
    regions: [{ id: 'sample', x: 0, y: 0, width: 1280, height: 800 }],
  };
}

function manifestPlan(runNumbers = [2, 3, 4]) {
  return {
    schemaVersion: 1,
    referenceVersion: 'codex-v1',
    viewport: { ...VIEWPORT },
    renderingEnvironment: { platform: 'macOS', flutter: 'pending-capture', fontMode: 'bundled' },
    screens: [screenEntry()],
    captureRuns: runNumbers.map((runNumber) => ({
      runNumber,
      directory: `captures/run-${runNumber}`,
      metadata: `captures/run-${runNumber}/capture-metadata.json`,
      purpose: 'noise-floor',
    })),
    noiseMeasurement: {
      status: 'planned',
      runNumbers: [...runNumbers],
      report: 'reports/noise-floor-test.json',
      thresholdPolicy: THRESHOLD_POLICY,
      thresholdApproval: 'pending',
      legacyV23ThresholdImported: false,
      rationale: 'Measure the new Codex capture noise without importing v2.3 thresholds.',
    },
    history: [{
      reason: 'candidate test manifest',
      affected: ['all'],
      renderingEnvironment: { platform: 'macOS', flutter: 'pending-capture', fontMode: 'bundled' },
      approval: 'candidate',
      recordedAt: '2026-08-12T00:00:00.000Z',
    }],
  };
}

let physicalBuffer;
function fullPngBuffer() {
  if (!physicalBuffer) physicalBuffer = PNG.sync.write(image(PHYSICAL.width, PHYSICAL.height, [24, 24, 24, 255]));
  return physicalBuffer;
}

function writeRun(activeRoot, manifest, runNumber, overrides = {}) {
  const runDir = path.join(activeRoot, 'captures', `run-${runNumber}`);
  fs.mkdirSync(runDir, { recursive: true });
  const entry = manifest.screens[0];
  const name = `${entry.id}-${entry.theme}.png`;
  const file = path.join(runDir, name);
  fs.writeFileSync(file, fullPngBuffer());
  const metadata = {
    schemaVersion: 2,
    referenceVersion: manifest.referenceVersion,
    runNumber,
    capturedAt: `2026-08-12T00:0${runNumber}:00.000Z`,
    viewport: { ...VIEWPORT },
    physicalSize: { ...PHYSICAL },
    renderingEnvironment: { ...ENVIRONMENT },
    fixtureRevision: SHA,
    buildRevision: 'b'.repeat(64),
    fontRevision: 'c'.repeat(64),
    fonts: [{ id: 'Inter-Variable.ttf', source: 'bundled', sha256: 'd'.repeat(64) }],
    files: [{
      screen: entry.id,
      theme: entry.theme,
      file: name,
      ...PHYSICAL,
      sha256: sha256(file),
    }],
    ...overrides,
  };
  const metadataPath = path.join(runDir, 'capture-metadata.json');
  fs.writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`);
  return { runDir, metadata, metadataPath };
}

function completeFixture(t) {
  const root = temporaryRoot(t);
  const activeRoot = path.join(root, 'visual-evidence', 'active', 'codex-v1');
  fs.mkdirSync(path.join(activeRoot, 'reports'), { recursive: true });
  fs.mkdirSync(path.join(activeRoot, 'references'), { recursive: true });
  const manifest = manifestPlan();
  for (const runNumber of manifest.noiseMeasurement.runNumbers) {
    writeRun(activeRoot, manifest, runNumber);
  }
  const manifestPath = path.join(activeRoot, 'manifest.json');
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  return { activeRoot, manifest, manifestPath };
}

test('noise plan requires at least three explicitly declared active capture runs', (t) => {
  const activeRoot = temporaryRoot(t);
  fs.mkdirSync(path.join(activeRoot, 'captures'), { recursive: true });
  fs.mkdirSync(path.join(activeRoot, 'reports'), { recursive: true });
  const tooFew = manifestPlan([2, 3]);
  assert.throws(() => validateNoisePlan(tooFew, activeRoot), /at least three runs/);

  const undeclared = manifestPlan();
  undeclared.captureRuns.pop();
  assert.throws(() => validateNoisePlan(undeclared, activeRoot), /undeclared run-4/);

  const archive = manifestPlan();
  archive.captureRuns[0].directory = 'captures/v2.3-archive/run-2';
  assert.throws(() => validateNoisePlan(archive, activeRoot), /outside v2.3-archive|must stay under/);
});

test('noise runs require metadata v2 and identical build, fixture, font, engine, and viewport provenance', (t) => {
  const fixture = completeFixture(t);
  const plan = validateNoisePlan(fixture.manifest, fixture.activeRoot);
  assert.equal(loadNoiseRuns(fixture.manifest, fixture.activeRoot, plan).length, 3);

  const run3Metadata = path.join(fixture.activeRoot, 'captures', 'run-3', 'capture-metadata.json');
  const original = JSON.parse(fs.readFileSync(run3Metadata, 'utf8'));
  fs.writeFileSync(run3Metadata, JSON.stringify({ ...original, schemaVersion: 1 }));
  assert.throws(
    () => loadNoiseRuns(fixture.manifest, fixture.activeRoot, plan),
    /schemaVersion 2/,
  );

  fs.writeFileSync(run3Metadata, JSON.stringify({ ...original, buildRevision: 'e'.repeat(64) }));
  assert.throws(
    () => loadNoiseRuns(fixture.manifest, fixture.activeRoot, plan),
    /does not match run-2/,
  );
});

test('maximum pairwise noise records the largest source run pair for every metric', (t) => {
  const root = temporaryRoot(t);
  const manifest = {
    viewport: { logicalWidth: 4, logicalHeight: 4, dpr: 1 },
    screens: [{
      ...screenEntry(),
      regions: [{ id: 'sample', x: 0, y: 0, width: 4, height: 4 }],
    }],
  };
  const runs = [2, 3, 4].map((runNumber, index) => {
    const png = image(4, 4);
    if (index > 0) setPixel(png, 1, 1, [index === 1 ? 10 : 30, 0, 0, 255]);
    const file = path.join(root, `run-${runNumber}.png`);
    writePng(file, png);
    return {
      runNumber,
      captures: new Map([['inst-browse:light', file]]),
    };
  });

  const [floor] = calculatePairwiseNoise(manifest, runs, {
    expectedPhysical: { width: 4, height: 4 },
  });

  assert.equal(floor.fullFrameDiffRatio.measuredNoiseFloor, 1 / 16);
  assert.deepEqual(floor.fullFrameDiffRatio.sourceRuns, [2, 3]);
  assert.equal(floor.roiDiffRatios.sample.measuredNoiseFloor, 1 / 16);
  assert.deepEqual(floor.roiDiffRatios.sample.sourceRuns, [2, 3]);
  assert.equal(floor.channelMAE.sample.r.measuredNoiseFloor, 30 / (16 * 255));
  assert.deepEqual(floor.channelMAE.sample.r.sourceRuns, [2, 4]);
  assert.equal(floor.maxGeometryDeviationPx.measuredNoiseFloor, 0);
});

test('threshold constraints aggregate the maximum across screen/theme pairs', () => {
  const pair = (screen, full, roi, geometry, red) => ({
    screen,
    theme: 'light',
    fullFrameDiffRatio: { measuredNoiseFloor: full, minimumExclusive: full, sourceRuns: [2, 3] },
    roiDiffRatios: { sample: { measuredNoiseFloor: roi, minimumExclusive: roi, sourceRuns: [2, 3] } },
    maxGeometryDeviationPx: { measuredNoiseFloor: geometry, minimumExclusive: geometry, sourceRuns: [2, 3] },
    channelMAE: { sample: {
      r: { measuredNoiseFloor: red, minimumExclusive: red, sourceRuns: [2, 3] },
      g: { measuredNoiseFloor: 0, minimumExclusive: 0, sourceRuns: [2, 3] },
      b: { measuredNoiseFloor: 0, minimumExclusive: 0, sourceRuns: [2, 3] },
      a: { measuredNoiseFloor: 0, minimumExclusive: 0, sourceRuns: [2, 3] },
    } },
  });
  const constraints = summarizeThresholdConstraints([
    pair('inst-browse', 0.1, 0.2, 1, 0.3),
    pair('inst-console', 0.4, 0.1, 2, 0.2),
  ]);

  assert.equal(constraints.fullFrameDiffRatio.measuredNoiseFloor, 0.4);
  assert.equal(constraints.fullFrameDiffRatio.screen, 'inst-console');
  assert.equal(constraints.roiDiffRatios.sample.measuredNoiseFloor, 0.2);
  assert.equal(constraints.maxGeometryDeviationPx.measuredNoiseFloor, 2);
  assert.equal(constraints.channelMAE.r.measuredNoiseFloor, 0.3);
});

test('threshold proposals must bind the report, reject legacy 3%, and stay strictly above every noise floor', () => {
  const report = {
    referenceVersion: 'codex-v1',
    thresholdConstraints: {
      fullFrameDiffRatio: { measuredNoiseFloor: 0.01 },
      roiDiffRatios: { sample: { measuredNoiseFloor: 0.02 } },
      maxGeometryDeviationPx: { measuredNoiseFloor: 1 },
      channelMAE: {
        r: { measuredNoiseFloor: 0.01 },
        g: { measuredNoiseFloor: 0 },
        b: { measuredNoiseFloor: 0 },
        a: { measuredNoiseFloor: 0 },
      },
    },
  };
  const proposal = {
    schemaVersion: 1,
    referenceVersion: 'codex-v1',
    noiseReportSha256: SHA,
    derivation: 'codex-reference-and-measured-noise',
    legacyV23ThresholdImported: false,
    margin: 0.001,
    rationale: 'Measured Codex noise plus an explicit margin.',
    metrics: {
      fullFrameDiffRatio: 0.011,
      roiDiffRatios: { sample: 0.021 },
      maxGeometryDeviationPx: 1.1,
      channelMAE: { r: 0.011, g: 0.001, b: 0.001, a: 0.001 },
    },
  };
  assert.equal(validateThresholdProposal(proposal, report, SHA), proposal);

  assert.throws(
    () => validateThresholdProposal({ ...proposal, noiseReportSha256: '0'.repeat(64) }, report, SHA),
    /exact noise report/,
  );
  assert.throws(
    () => validateThresholdProposal({
      ...proposal,
      legacyV23ThresholdImported: true,
      metrics: { ...proposal.metrics, fullFrameDiffRatio: 0.03 },
    }, report, SHA),
    /reject importing the legacy/,
  );
  assert.throws(
    () => validateThresholdProposal({
      ...proposal,
      metrics: { ...proposal.metrics, maxGeometryDeviationPx: 1 },
    }, report, SHA),
    /strictly greater than measured noise/,
  );
});

test('complete measurement writes one pending report and refuses overwrite', (t) => {
  const fixture = completeFixture(t);
  const result = measureNoiseFloor({ manifestPath: fixture.manifestPath });

  assert.equal(result.report.runNumbers.length, 3);
  assert.equal(result.report.pairCount, 3);
  assert.equal(result.report.thresholdApproval, 'pending');
  assert.equal(result.report.legacyV23ThresholdImported, false);
  assert.equal(result.report.pairs.length, 1);
  assert.equal(result.report.pairs[0].fullFrameDiffRatio.measuredNoiseFloor, 0);
  assert.match(result.reportSha256, /^[0-9a-f]{64}$/);
  assert.deepEqual(JSON.parse(fs.readFileSync(result.reportPath, 'utf8')), result.report);

  assert.throws(
    () => measureNoiseFloor({ manifestPath: fixture.manifestPath }),
    /Refusing to overwrite existing noise report/,
  );
});
