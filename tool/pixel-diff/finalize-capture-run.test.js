'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  BUILD_FILES,
  BUNDLED_FONT_FILES,
  FIXTURE_FILES,
  buildRevision,
  expectedCaptureNames,
  finalizeCaptureRun,
  fontProvenance,
} = require('./finalize-capture-run');

function temporaryRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'redimos-capture-run-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function writePngHeader(file, width = 2560, height = 1600) {
  const header = Buffer.alloc(24);
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(header, 0);
  header.writeUInt32BE(13, 8);
  header.write('IHDR', 12, 4, 'ascii');
  header.writeUInt32BE(width, 16);
  header.writeUInt32BE(height, 20);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, header);
}

function fixtureRepo(root) {
  for (const relative of FIXTURE_FILES) {
    const file = path.join(root, relative);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, `fixture:${relative}\n`);
  }
  fs.mkdirSync(path.join(root, 'lib'), { recursive: true });
  fs.writeFileSync(path.join(root, 'lib', 'main.dart'), 'void main() {}\n');
  for (const relative of BUILD_FILES) {
    fs.writeFileSync(path.join(root, relative), `${relative}: test\n`);
  }
  for (const relative of BUNDLED_FONT_FILES) {
    const file = path.join(root, relative);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, `font:${relative}\n`);
  }
}

function testFontInputs(repoRoot) {
  return BUNDLED_FONT_FILES.map((relative) => ({
    id: path.basename(relative),
    source: 'bundled',
    file: path.join(repoRoot, relative),
  }));
}

function completeRun(t, runNumber = 1) {
  const root = temporaryRoot(t);
  const repoRoot = path.join(root, 'repo');
  const runDir = path.join(root, 'visual-evidence', 'active', 'codex-v1', 'captures', `run-${runNumber}`);
  fixtureRepo(repoRoot);
  for (const name of expectedCaptureNames()) {
    writePngHeader(path.join(runDir, name));
  }
  return { repoRoot, runDir, fontInputs: testFontInputs(repoRoot) };
}

function finalizeOptions(fixture, runNumber, overrides = {}) {
  return {
    runNumber,
    repoRoot: fixture.repoRoot,
    fontInputs: fixture.fontInputs,
    flutterVersion: 'Flutter 3.test',
    platform: 'macOS test',
    capturedAt: '2026-08-12T00:00:00.000Z',
    ...overrides,
  };
}

test('finalizer validates 16 captures and records deterministic metadata v2', (t) => {
  const fixture = completeRun(t, 7);
  const result = finalizeCaptureRun(fixture.runDir, finalizeOptions(fixture, 7));

  assert.equal(result.metadata.schemaVersion, 2);
  assert.equal(result.metadata.runNumber, 7);
  assert.deepEqual(result.metadata.viewport, {
    logicalWidth: 1280,
    logicalHeight: 800,
    dpr: 2,
  });
  assert.deepEqual(result.metadata.physicalSize, { width: 2560, height: 1600 });
  assert.equal(result.metadata.renderingEnvironment.fontMode, 'bundled');
  assert.equal(result.metadata.files.length, 16);
  assert.equal(new Set(result.metadata.files.map((entry) => `${entry.screen}:${entry.theme}`)).size, 16);
  assert.match(result.metadata.fixtureRevision, /^[0-9a-f]{64}$/);
  assert.match(result.metadata.buildRevision, /^[0-9a-f]{64}$/);
  assert.match(result.metadata.fontRevision, /^[0-9a-f]{64}$/);
  assert.equal(result.metadata.fonts.length, BUNDLED_FONT_FILES.length);
  assert.ok(result.metadata.fonts.every((font) => /^[0-9a-f]{64}$/.test(font.sha256)));
  assert.deepEqual(
    JSON.parse(fs.readFileSync(result.metadataPath, 'utf8')),
    result.metadata,
  );
});

test('finalizer rejects missing and unexpected captures', (t) => {
  const fixture = completeRun(t);
  fs.rmSync(path.join(fixture.runDir, expectedCaptureNames()[0]));
  writePngHeader(path.join(fixture.runDir, 'unexpected-light.png'));

  assert.throws(
    () => finalizeCaptureRun(fixture.runDir, finalizeOptions(fixture, 1)),
    /missing:.*unexpected:/,
  );
});

test('finalizer rejects wrong dimensions and metadata overwrite', (t) => {
  const fixture = completeRun(t);
  const firstName = expectedCaptureNames()[0];
  writePngHeader(path.join(fixture.runDir, firstName), 1280, 800);
  assert.throws(
    () => finalizeCaptureRun(fixture.runDir, finalizeOptions(fixture, 1)),
    /must be 2560x1600/,
  );

  writePngHeader(path.join(fixture.runDir, firstName));
  finalizeCaptureRun(fixture.runDir, finalizeOptions(fixture, 1));
  assert.throws(
    () => finalizeCaptureRun(fixture.runDir, finalizeOptions(fixture, 1)),
    /Refusing to overwrite capture metadata/,
  );
});

test('build, fixture, and font revisions are deterministic and input-sensitive', (t) => {
  const fixture = completeRun(t);
  const originalBuild = buildRevision(fixture.repoRoot);
  const originalFonts = fontProvenance(fixture.repoRoot, { fontInputs: fixture.fontInputs });

  assert.equal(buildRevision(fixture.repoRoot), originalBuild);
  assert.deepEqual(
    fontProvenance(fixture.repoRoot, { fontInputs: fixture.fontInputs }),
    originalFonts,
  );

  fs.appendFileSync(path.join(fixture.repoRoot, 'lib', 'main.dart'), '// changed\n');
  assert.notEqual(buildRevision(fixture.repoRoot), originalBuild);

  const originalFontRevision = originalFonts.fontRevision;
  fs.appendFileSync(fixture.fontInputs[0].file, 'changed');
  assert.notEqual(
    fontProvenance(fixture.repoRoot, { fontInputs: fixture.fontInputs }).fontRevision,
    originalFontRevision,
  );
});

test('finalizer rejects references, archive paths, and mismatched run numbers', (t) => {
  const root = temporaryRoot(t);
  for (const segment of ['references', 'v2.3-archive']) {
    const runDir = path.join(root, segment, 'captures', 'run-1');
    fs.mkdirSync(runDir, { recursive: true });
    assert.throws(
      () => finalizeCaptureRun(runDir, {
        runNumber: 1,
        repoRoot: root,
        flutterVersion: 'Flutter test',
      }),
      /outside references\/archive/,
    );
  }

  const runDir = path.join(root, 'active', 'captures', 'run-2');
  fs.mkdirSync(runDir, { recursive: true });
  assert.throws(
    () => finalizeCaptureRun(runDir, {
      runNumber: 1,
      repoRoot: root,
      flutterVersion: 'Flutter test',
    }),
    /must end with run-1/,
  );
});
