'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  ManifestValidationError,
  SCREENS,
  THEMES,
  loadReferenceManifest,
  validateReferenceManifest,
} = require('./reference-manifest');

function environment() {
  return { platform: 'macOS', flutter: 'test-flutter', fontMode: 'bundled' };
}

function entry(id, theme, approval = 'approved') {
  return {
    id,
    theme,
    file: `references/${id}-${theme}.png`,
    source: 'user-approved-codex-comparison',
    approval,
    regions: [{ id: 'shell', x: 0, y: 0, width: 1280, height: 116 }],
  };
}

function manifest(approval = 'approved') {
  return {
    schemaVersion: 1,
    referenceVersion: 'codex-v1',
    viewport: { logicalWidth: 1280, logicalHeight: 800, dpr: 2 },
    renderingEnvironment: environment(),
    screens: SCREENS.flatMap((id) => THEMES.map((theme) => entry(id, theme, approval))),
    history: [{
      reason: approval === 'approved' ? 'test approval' : 'candidate creation',
      affected: ['all'],
      renderingEnvironment: environment(),
      approval,
      ...(approval === 'approved' ? { reviewer: 'test-reviewer' } : {}),
      recordedAt: '2026-08-12T00:00:00.000Z',
    }],
  };
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

function temporaryRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'redimos-reference-manifest-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function issueCodes(error) {
  assert.ok(error instanceof ManifestValidationError);
  return new Set(error.issues.map((value) => value.code));
}

test('acceptance mode validates exactly 8x2 approved references and PNG dimensions', (t) => {
  const root = temporaryRoot(t);
  const value = manifest();
  for (const screen of value.screens) {
    writePngHeader(path.join(root, screen.file));
  }
  const manifestPath = path.join(root, 'manifest.json');
  fs.writeFileSync(manifestPath, JSON.stringify(value));

  assert.deepEqual(loadReferenceManifest(manifestPath), value);
});

test('draft mode permits candidate slots without creating or approving files', () => {
  const value = manifest('candidate');
  value.screens = [value.screens[0]];

  assert.equal(
    validateReferenceManifest(value, { mode: 'draft', checkFiles: false }),
    value,
  );
});

test('acceptance mode reports missing, duplicate, unapproved, and wrong-size entries together', (t) => {
  const root = temporaryRoot(t);
  const value = manifest();
  value.viewport.logicalWidth = 1279;
  value.screens.pop();
  value.screens[0].approval = 'candidate';
  value.screens[1] = { ...value.screens[0] };
  for (const screen of value.screens) {
    writePngHeader(path.join(root, screen.file), 1280, 800);
  }

  assert.throws(
    () => validateReferenceManifest(value, { activeRoot: root }),
    (error) => {
      const codes = issueCodes(error);
      for (const code of [
        'wrong-viewport',
        'duplicate-pair',
        'duplicate-file',
        'unapproved-reference',
        'missing-pair',
        'wrong-coverage',
        'wrong-dimensions',
      ]) {
        assert.ok(codes.has(code), `expected diagnostic ${code}`);
      }
      return true;
    },
  );
});

test('active references cannot escape the manifest root or enter v2.3-archive', () => {
  const value = manifest('candidate');
  value.screens = [
    { ...value.screens[0], file: '../outside/inst-browse-light.png' },
    { ...value.screens[1], file: 'v2.3-archive/inst-browse-dark.png' },
  ];

  assert.throws(
    () => validateReferenceManifest(value, { mode: 'draft', checkFiles: false }),
    (error) => {
      const codes = issueCodes(error);
      assert.ok(codes.has('path-escape'));
      assert.ok(codes.has('archive-path'));
      return true;
    },
  );
});

test('approved baselines require reviewer approval history', () => {
  const value = manifest();
  delete value.history[0].reviewer;

  assert.throws(
    () => validateReferenceManifest(value, { checkFiles: false }),
    (error) => issueCodes(error).has('missing-reviewer'),
  );
});

test('missing and mistyped fields return structured diagnostics', () => {
  const value = manifest('candidate');
  value.screens = [value.screens[0]];
  delete value.screens[0].source;
  value.screens[0].file = 42;

  assert.throws(
    () => validateReferenceManifest(value, { mode: 'draft', checkFiles: false }),
    (error) => {
      const codes = issueCodes(error);
      assert.ok(codes.has('missing-field'));
      assert.ok(codes.has('invalid-file'));
      return true;
    },
  );
});

test('acceptance mode reports a missing reference file', (t) => {
  const root = temporaryRoot(t);
  const value = manifest();
  for (const screen of value.screens.slice(1)) {
    writePngHeader(path.join(root, screen.file));
  }

  assert.throws(
    () => validateReferenceManifest(value, { activeRoot: root }),
    (error) => issueCodes(error).has('missing-reference'),
  );
});

test('invalid JSON returns an explicit parse diagnostic', (t) => {
  const root = temporaryRoot(t);
  const manifestPath = path.join(root, 'manifest.json');
  fs.writeFileSync(manifestPath, '{not-json');

  assert.throws(
    () => loadReferenceManifest(manifestPath),
    (error) => issueCodes(error).has('parse-error'),
  );
});

test('measured noise status binds an existing report by SHA-256 and semantics', (t) => {
  const root = temporaryRoot(t);
  const value = manifest('candidate');
  value.screens = [value.screens[0]];
  const report = {
    referenceVersion: value.referenceVersion,
    runNumbers: [2, 3, 4],
    thresholdPolicy: 'strictly-greater-than-measured-noise',
    thresholdApproval: 'pending',
    legacyV23ThresholdImported: false,
  };
  const reportPath = path.join(root, 'reports', 'noise-floor.json');
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.writeFileSync(reportPath, `${JSON.stringify(report)}\n`);
  value.noiseMeasurement = {
    status: 'measured',
    runNumbers: [2, 3, 4],
    report: 'reports/noise-floor.json',
    reportSha256: crypto.createHash('sha256').update(fs.readFileSync(reportPath)).digest('hex'),
    thresholdPolicy: report.thresholdPolicy,
    thresholdApproval: 'pending',
    legacyV23ThresholdImported: false,
    rationale: 'Measured three same-provenance Codex captures.',
  };

  assert.equal(
    validateReferenceManifest(value, { mode: 'draft', checkFiles: false, activeRoot: root }),
    value,
  );
});

test('measured noise status rejects a missing report hash or report file', (t) => {
  const root = temporaryRoot(t);
  const value = manifest('candidate');
  value.screens = [value.screens[0]];
  value.noiseMeasurement = {
    status: 'measured',
    runNumbers: [2, 3, 4],
    report: 'reports/missing.json',
    thresholdPolicy: 'strictly-greater-than-measured-noise',
    thresholdApproval: 'pending',
    legacyV23ThresholdImported: false,
    rationale: 'Measured three same-provenance Codex captures.',
  };

  assert.throws(
    () => validateReferenceManifest(value, { mode: 'draft', checkFiles: false, activeRoot: root }),
    (error) => issueCodes(error).has('invalid-noise-report-hash'),
  );

  value.noiseMeasurement.reportSha256 = 'a'.repeat(64);
  assert.throws(
    () => validateReferenceManifest(value, { mode: 'draft', checkFiles: false, activeRoot: root }),
    (error) => issueCodes(error).has('missing-noise-report'),
  );
});

test('measured noise status rejects report content changed after binding', (t) => {
  const root = temporaryRoot(t);
  const value = manifest('candidate');
  value.screens = [value.screens[0]];
  const reportPath = path.join(root, 'reports', 'noise-floor.json');
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.writeFileSync(reportPath, '{"referenceVersion":"codex-v1"}\n');
  const boundHash = crypto.createHash('sha256').update(fs.readFileSync(reportPath)).digest('hex');
  fs.writeFileSync(reportPath, '{"referenceVersion":"tampered"}\n');
  value.noiseMeasurement = {
    status: 'measured',
    runNumbers: [2, 3, 4],
    report: 'reports/noise-floor.json',
    reportSha256: boundHash,
    thresholdPolicy: 'strictly-greater-than-measured-noise',
    thresholdApproval: 'pending',
    legacyV23ThresholdImported: false,
    rationale: 'Measured three same-provenance Codex captures.',
  };

  assert.throws(
    () => validateReferenceManifest(value, { mode: 'draft', checkFiles: false, activeRoot: root }),
    (error) => issueCodes(error).has('noise-report-hash-mismatch'),
  );
});
