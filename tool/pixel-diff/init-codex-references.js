'use strict';

const fs = require('fs');
const path = require('path');

const {
  REQUIRED_VIEWPORT,
  SCREENS,
  THEMES,
  validateReferenceManifest,
} = require('./reference-manifest');

const DEFAULT_ACTIVE_ROOT = path.join(
  __dirname,
  'visual-evidence',
  'active',
  'codex-v1',
);
const OUTPUT_DIRECTORIES = Object.freeze([
  'references',
  'captures',
  'reports',
]);
const OUTPUT_IGNORE = '*\n!.gitignore\n';
const REFERENCE_SOURCE = [
  'user-approved-codex-comparison',
  'approved-warm-neutral-palette',
  'preserved-redimos-information-architecture',
].join('+');
const REGIONS = Object.freeze([
  Object.freeze({ id: 'railSidebar', x: 0, y: 0, width: 344, height: 800 }),
  Object.freeze({ id: 'topBars', x: 344, y: 0, width: 936, height: 92 }),
  Object.freeze({ id: 'detail', x: 344, y: 92, width: 936, height: 684 }),
  Object.freeze({ id: 'statusbar', x: 344, y: 776, width: 936, height: 24 }),
]);

function hasArchiveSegment(target) {
  return path.resolve(target).split(path.sep).includes('v2.3-archive');
}

function candidateEnvironment(flutterVersion = 'pending-capture') {
  return {
    platform: 'macOS',
    flutter: flutterVersion,
    fontMode: 'bundled',
  };
}

function createCandidateManifest({ recordedAt, flutterVersion } = {}) {
  const environment = candidateEnvironment(flutterVersion);
  const timestamp = recordedAt ?? new Date().toISOString();
  const screens = SCREENS.flatMap((id) => THEMES.map((theme) => ({
    id,
    theme,
    file: `references/${id}-${theme}.png`,
    source: REFERENCE_SOURCE,
    approval: 'candidate',
    regions: REGIONS.map((region) => ({ ...region })),
  })));
  return {
    schemaVersion: 1,
    referenceVersion: 'codex-v1',
    viewport: { ...REQUIRED_VIEWPORT },
    renderingEnvironment: environment,
    screens,
    history: [{
      reason: 'Initialize 8x2 Codex reference candidate slots without approving baseline images',
      affected: ['all'],
      renderingEnvironment: { ...environment },
      approval: 'candidate',
      recordedAt: timestamp,
    }],
  };
}

function ensureOutputIgnore(directory) {
  const ignorePath = path.join(directory, '.gitignore');
  if (fs.existsSync(ignorePath)) {
    if (fs.readFileSync(ignorePath, 'utf8') !== OUTPUT_IGNORE) {
      throw new Error(`Refusing to replace existing output ignore policy: ${ignorePath}`);
    }
    return;
  }
  fs.writeFileSync(ignorePath, OUTPUT_IGNORE, { flag: 'wx' });
}

function initializeReferenceSet(activeRoot = DEFAULT_ACTIVE_ROOT, options = {}) {
  const root = path.resolve(activeRoot);
  if (hasArchiveSegment(root)) {
    throw new Error(`Refusing to initialize active references inside v2.3-archive: ${root}`);
  }
  const manifestPath = path.join(root, 'manifest.json');
  if (fs.existsSync(manifestPath)) {
    throw new Error(`Refusing to overwrite existing reference manifest: ${manifestPath}`);
  }

  const manifest = createCandidateManifest(options);
  validateReferenceManifest(manifest, {
    mode: 'draft',
    checkFiles: false,
    activeRoot: root,
  });

  fs.mkdirSync(root, { recursive: true });
  for (const name of OUTPUT_DIRECTORIES) {
    const directory = path.join(root, name);
    fs.mkdirSync(directory, { recursive: true });
    ensureOutputIgnore(directory);
  }
  fs.writeFileSync(
    manifestPath,
    `${JSON.stringify(manifest, null, 2)}\n`,
    { flag: 'wx' },
  );
  return { activeRoot: root, manifestPath, manifest };
}

function main(argv) {
  if (argv.length > 1) {
    console.error('Usage: node init-codex-references.js [active-root]');
    process.exitCode = 2;
    return;
  }
  try {
    const result = initializeReferenceSet(argv[0] ?? DEFAULT_ACTIVE_ROOT);
    console.log(`[codex-references] initialized candidate manifest: ${result.manifestPath}`);
    console.log('[codex-references] 16 candidate slots created; no reference PNG was generated or approved');
  } catch (error) {
    console.error(`[codex-references] ${error.message}`);
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main(process.argv.slice(2));
}

module.exports = {
  DEFAULT_ACTIVE_ROOT,
  OUTPUT_DIRECTORIES,
  REFERENCE_SOURCE,
  REGIONS,
  createCandidateManifest,
  initializeReferenceSet,
};
