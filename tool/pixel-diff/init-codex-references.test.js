'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  OUTPUT_DIRECTORIES,
  REFERENCE_SOURCE,
  initializeReferenceSet,
} = require('./init-codex-references');
const {
  SCREENS,
  THEMES,
  loadReferenceManifest,
} = require('./reference-manifest');

function temporaryRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'redimos-codex-references-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function filesUnder(root) {
  return fs.readdirSync(root, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => path.join(entry.parentPath, entry.name))
    .map((entry) => path.relative(root, entry))
    .sort();
}

test('initializer creates 16 unique candidate slots and no PNG artifacts', (t) => {
  const root = path.join(temporaryRoot(t), 'active', 'codex-v1');
  const result = initializeReferenceSet(root, {
    recordedAt: '2026-08-12T00:00:00.000Z',
    flutterVersion: 'test-flutter',
  });
  const manifest = loadReferenceManifest(result.manifestPath, {
    mode: 'draft',
    checkFiles: false,
  });

  assert.equal(manifest.screens.length, SCREENS.length * THEMES.length);
  assert.equal(new Set(manifest.screens.map((entry) => `${entry.id}:${entry.theme}`)).size, 16);
  assert.equal(new Set(manifest.screens.map((entry) => entry.file)).size, 16);
  assert.ok(manifest.screens.every((entry) => entry.approval === 'candidate'));
  assert.ok(manifest.screens.every((entry) => entry.source === REFERENCE_SOURCE));
  assert.ok(manifest.screens.every((entry) => entry.regions.length === 4));

  const files = filesUnder(root);
  assert.deepEqual(files, [
    'captures/.gitignore',
    'manifest.json',
    'references/.gitignore',
    'reports/.gitignore',
  ]);
  assert.equal(files.some((file) => file.endsWith('.png')), false);
  for (const directory of OUTPUT_DIRECTORIES) {
    assert.equal(fs.readFileSync(path.join(root, directory, '.gitignore'), 'utf8'), '*\n!.gitignore\n');
  }
});

test('initializer refuses to overwrite an existing manifest', (t) => {
  const root = path.join(temporaryRoot(t), 'active', 'codex-v1');
  const first = initializeReferenceSet(root, {
    recordedAt: '2026-08-12T00:00:00.000Z',
  });
  const before = fs.readFileSync(first.manifestPath);

  assert.throws(
    () => initializeReferenceSet(root),
    /Refusing to overwrite existing reference manifest/,
  );
  assert.deepEqual(fs.readFileSync(first.manifestPath), before);
});

test('initializer refuses an active root inside the archive', (t) => {
  const root = path.join(temporaryRoot(t), 'v2.3-archive', 'active');
  assert.throws(
    () => initializeReferenceSet(root),
    /inside v2\.3-archive/,
  );
  assert.equal(fs.existsSync(root), false);
});
