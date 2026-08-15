'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const {
  CAPTURE_SCREENS,
  REQUIRED_PHYSICAL,
  REQUIRED_VIEWPORT,
  THEMES,
  readPngSize,
} = require('./reference-manifest');

const METADATA_FILE = 'capture-metadata.json';
const FIXTURE_FILES = Object.freeze([
  'test/screen_fixtures.dart',
  'test/pixel_capture_test.dart',
  'test/golden_fonts.dart',
]);
const BUILD_ROOTS = Object.freeze(['lib']);
const BUILD_FILES = Object.freeze(['pubspec.yaml', 'pubspec.lock']);
const BUNDLED_FONT_FILES = Object.freeze([
  'assets/fonts/Inter-Variable.ttf',
  'assets/fonts/JetBrainsMono-Variable.ttf',
]);

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function expectedCaptureNames() {
  // Stage 16.2: the capture channel is the full 14-screen set — the 8 golden
  // screens plus the 6 capture-only Service screens.
  return CAPTURE_SCREENS.flatMap((screen) =>
    THEMES.map((theme) => `${screen}-${theme}.png`),
  ).sort();
}

function hasSegment(target, segment) {
  return path.resolve(target).split(path.sep).includes(segment);
}

function hashFiles(repoRoot, relativeFiles, label) {
  const hash = crypto.createHash('sha256');
  for (const relative of [...relativeFiles].sort()) {
    const file = path.join(repoRoot, relative);
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
      throw new Error(`${label} file is missing: ${file}`);
    }
    hash.update(relative);
    hash.update('\0');
    hash.update(fs.readFileSync(file));
    hash.update('\0');
  }
  return hash.digest('hex');
}

function listFiles(root, relativeDirectory) {
  const directory = path.join(root, relativeDirectory);
  if (!fs.existsSync(directory) || !fs.statSync(directory).isDirectory()) {
    throw new Error(`Build input directory is missing: ${directory}`);
  }
  const files = [];
  const visit = (current, relative) => {
    for (const name of fs.readdirSync(current).sort()) {
      const absolute = path.join(current, name);
      const childRelative = path.join(relative, name);
      const stat = fs.lstatSync(absolute);
      if (stat.isSymbolicLink()) {
        throw new Error(`Build input must not be a symlink: ${absolute}`);
      }
      if (stat.isDirectory()) visit(absolute, childRelative);
      else if (stat.isFile()) files.push(childRelative);
    }
  };
  visit(directory, relativeDirectory);
  return files;
}

function fixtureRevision(repoRoot) {
  const files = listFiles(repoRoot, 'test')
    .filter((relative) => path.extname(relative) === '.dart');
  if (files.length === 0) {
    throw new Error('Capture fixture must include at least one Dart test file');
  }
  return hashFiles(repoRoot, files, 'Capture fixture');
}

function buildRevision(repoRoot) {
  const files = [
    ...BUILD_FILES,
    ...BUILD_ROOTS.flatMap((directory) => listFiles(repoRoot, directory)),
  ];
  return hashFiles(repoRoot, files, 'Build input');
}

function defaultFontInputs(repoRoot, options = {}) {
  const inputs = BUNDLED_FONT_FILES.map((relative) => ({
    id: path.basename(relative),
    source: 'bundled',
    file: path.join(repoRoot, relative),
  }));
  const home = options.home ?? os.homedir();
  const flutterRoot = options.flutterRoot ?? process.env.FLUTTER_ROOT ?? path.join(home, 'flutter');
  const materialIcons = path.join(
    flutterRoot,
    'bin',
    'cache',
    'artifacts',
    'material_fonts',
    'MaterialIcons-Regular.otf',
  );
  if (fs.existsSync(materialIcons)) {
    inputs.push({ id: 'MaterialIcons-Regular.otf', source: 'flutter-sdk', file: materialIcons });
  }
  const pingFangBase = '/System/Library/Fonts/PingFang.ttc';
  if (fs.existsSync(pingFangBase)) {
    inputs.push({ id: 'PingFang.ttc', source: 'platform', file: pingFangBase });
  } else {
    const assetRoot = '/System/Library/AssetsV2/com_apple_MobileAsset_Font7';
    if (fs.existsSync(assetRoot)) {
      const candidate = fs.readdirSync(assetRoot).sort()
        .map((name) => path.join(assetRoot, name, 'AssetData', 'PingFang.ttc'))
        .find((file) => fs.existsSync(file));
      if (candidate) inputs.push({ id: 'PingFang.ttc', source: 'platform-asset', file: candidate });
    }
  }
  return inputs;
}

function fontProvenance(repoRoot, options = {}) {
  const inputs = options.fontInputs ?? defaultFontInputs(repoRoot, options);
  const seen = new Set();
  const fonts = inputs.map((input) => {
    if (!nonEmptyString(input.id) || !nonEmptyString(input.source) || !nonEmptyString(input.file)) {
      throw new Error('Font inputs must provide non-empty id, source, and file');
    }
    if (seen.has(input.id)) throw new Error(`Duplicate font input id: ${input.id}`);
    seen.add(input.id);
    const file = path.resolve(input.file);
    if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
      throw new Error(`Font input is missing: ${file}`);
    }
    return {
      id: input.id,
      source: input.source,
      sha256: sha256File(file),
    };
  }).sort((a, b) => a.id.localeCompare(b.id));
  const hash = crypto.createHash('sha256');
  for (const font of fonts) {
    hash.update(font.id);
    hash.update('\0');
    hash.update(font.source);
    hash.update('\0');
    hash.update(font.sha256);
    hash.update('\0');
  }
  return { fontRevision: hash.digest('hex'), fonts };
}

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function parseRunNumber(value) {
  if (!/^[1-9][0-9]*$/.test(String(value))) {
    throw new Error(`Run number must be a positive integer: ${value}`);
  }
  return Number(value);
}

function finalizeCaptureRun(runDirectory, options = {}) {
  const runDir = path.resolve(runDirectory);
  const runNumber = parseRunNumber(options.runNumber);
  const expectedBasename = `run-${runNumber}`;
  if (path.basename(runDir) !== expectedBasename) {
    throw new Error(`Capture directory must end with ${expectedBasename}: ${runDir}`);
  }
  if (!hasSegment(runDir, 'captures') ||
      hasSegment(runDir, 'references') ||
      hasSegment(runDir, 'v2.3-archive')) {
    throw new Error(`Capture run must stay under active captures and outside references/archive: ${runDir}`);
  }
  if (!fs.existsSync(runDir) || !fs.statSync(runDir).isDirectory()) {
    throw new Error(`Capture run directory does not exist: ${runDir}`);
  }

  const metadataPath = path.join(runDir, METADATA_FILE);
  if (fs.existsSync(metadataPath)) {
    throw new Error(`Refusing to overwrite capture metadata: ${metadataPath}`);
  }

  const expected = expectedCaptureNames();
  const actual = fs.readdirSync(runDir)
    .filter((name) => name.toLowerCase().endsWith('.png'))
    .sort();
  const missing = expected.filter((name) => !actual.includes(name));
  const extra = actual.filter((name) => !expected.includes(name));
  if (missing.length || extra.length) {
    const details = [];
    if (missing.length) details.push(`missing: ${missing.join(', ')}`);
    if (extra.length) details.push(`unexpected: ${extra.join(', ')}`);
    throw new Error(`Capture set must contain exactly ${expected.length} PNGs (${details.join('; ')})`);
  }

  const files = expected.map((name) => {
    const file = path.join(runDir, name);
    const size = readPngSize(file);
    if (size.width !== REQUIRED_PHYSICAL.width ||
        size.height !== REQUIRED_PHYSICAL.height) {
      throw new Error(
        `${name} must be ${REQUIRED_PHYSICAL.width}x${REQUIRED_PHYSICAL.height}; ` +
        `received ${size.width}x${size.height}`,
      );
    }
    const match = /^(.*)-(light|dark)\.png$/.exec(name);
    return {
      screen: match[1],
      theme: match[2],
      file: name,
      width: size.width,
      height: size.height,
      sha256: sha256File(file),
    };
  });

  const repoRoot = path.resolve(options.repoRoot ?? path.join(__dirname, '..', '..'));
  const flutterVersion = options.flutterVersion;
  if (typeof flutterVersion !== 'string' || flutterVersion.trim().length === 0) {
    throw new Error('Flutter version metadata is required');
  }
  const capturedAt = options.capturedAt ?? new Date().toISOString();
  if (Number.isNaN(Date.parse(capturedAt))) {
    throw new Error(`capturedAt must be an ISO-8601 date-time: ${capturedAt}`);
  }

  const fontInfo = fontProvenance(repoRoot, options);
  const metadata = {
    schemaVersion: 2,
    referenceVersion: 'codex-v1',
    runNumber,
    capturedAt,
    viewport: { ...REQUIRED_VIEWPORT },
    physicalSize: { ...REQUIRED_PHYSICAL },
    renderingEnvironment: {
      platform: options.platform ?? `${os.platform()} ${os.release()}`,
      flutter: flutterVersion.trim(),
      fontMode: 'bundled',
    },
    fixtureRevision: fixtureRevision(repoRoot),
    buildRevision: buildRevision(repoRoot),
    fontRevision: fontInfo.fontRevision,
    fonts: fontInfo.fonts,
    files,
  };
  fs.writeFileSync(
    metadataPath,
    `${JSON.stringify(metadata, null, 2)}\n`,
    { flag: 'wx' },
  );
  return { metadataPath, metadata };
}

function main(argv) {
  if (argv.length !== 3) {
    console.error(
      'Usage: node finalize-capture-run.js <run-directory> <run-number> <flutter-version>',
    );
    process.exitCode = 2;
    return;
  }
  try {
    const result = finalizeCaptureRun(argv[0], {
      runNumber: argv[1],
      flutterVersion: argv[2],
    });
    console.log(`[capture-run] metadata: ${result.metadataPath}`);
  } catch (error) {
    console.error(`[capture-run] ${error.message}`);
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main(process.argv.slice(2));
}

module.exports = {
  BUILD_FILES,
  BUILD_ROOTS,
  BUNDLED_FONT_FILES,
  FIXTURE_FILES,
  METADATA_FILE,
  buildRevision,
  expectedCaptureNames,
  finalizeCaptureRun,
  fixtureRevision,
  fontProvenance,
  parseRunNumber,
};
