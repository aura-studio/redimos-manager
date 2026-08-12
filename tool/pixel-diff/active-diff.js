'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { PNG } = require('pngjs');
const pixelmatch = require('pixelmatch');

const {
  ManifestValidationError,
  REQUIRED_PHYSICAL,
  REQUIRED_VIEWPORT,
  loadReferenceManifest,
  readPngSize,
} = require('./reference-manifest');

const METADATA_FILE = 'capture-metadata.json';
const CHANNELS = Object.freeze(['r', 'g', 'b', 'a']);
const EDGE_SEARCH_WINDOW_PX = 8;
const EDGE_MIN_GRADIENT = 8;
const REPORT_FILES = Object.freeze(['expected', 'actual', 'diff', 'metrics']);

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function hasSegment(target, segment) {
  return path.resolve(target).split(path.sep).includes(segment);
}

function isInside(root, target) {
  const relative = path.relative(root, target);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function deepEqual(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function readPng(filePath) {
  const fd = fs.openSync(filePath, 'r');
  try {
    const header = Buffer.alloc(29);
    if (fs.readSync(fd, header, 0, header.length, 0) !== header.length) {
      throw new Error('truncated PNG header');
    }
    if (header[24] !== 8 || (header[25] !== 2 && header[25] !== 6) || header[28] !== 0) {
      throw new Error(
        `unsupported PNG color space (bitDepth ${header[24]}, colorType ${header[25]}, interlace ${header[28]}); ` +
        'expected 8-bit non-interlaced RGB/RGBA',
      );
    }
  } finally {
    fs.closeSync(fd);
  }
  return PNG.sync.read(fs.readFileSync(filePath));
}

function loadCaptureRun(runDirectory, manifest, options = {}) {
  const runDir = path.resolve(runDirectory);
  if (!/^run-[1-9][0-9]*$/.test(path.basename(runDir))) {
    throw new Error(`Capture run directory must be named run-N with a positive integer: ${runDir}`);
  }
  const runNumber = Number(path.basename(runDir).slice(4));
  const activeRoot = path.resolve(options.activeRoot ?? path.dirname(path.dirname(runDir)));
  const capturesRoot = path.join(activeRoot, 'captures');
  if (!isInside(capturesRoot, runDir) ||
      hasSegment(runDir, 'references') ||
      hasSegment(runDir, 'v2.3-archive')) {
    throw new Error(`Capture run must stay under the active captures directory and outside references/archive: ${runDir}`);
  }
  if (!fs.existsSync(runDir) || !fs.statSync(runDir).isDirectory()) {
    throw new Error(`Capture run directory does not exist: ${runDir}`);
  }
  if (!fs.existsSync(capturesRoot) ||
      !isInside(fs.realpathSync(capturesRoot), fs.realpathSync(runDir))) {
    throw new Error(`Capture run resolves outside the active captures directory: ${runDir}`);
  }

  const runReal = fs.realpathSync(runDir);
  const metadataPath = path.join(runDir, METADATA_FILE);
  if (!fs.existsSync(metadataPath)) {
    throw new Error(`Capture metadata is missing: ${metadataPath}`);
  }
  if (fs.lstatSync(metadataPath).isSymbolicLink() ||
      !isInside(runReal, fs.realpathSync(metadataPath))) {
    throw new Error(`Capture metadata must be a regular file inside the run directory: ${metadataPath}`);
  }
  let metadata;
  try {
    metadata = JSON.parse(fs.readFileSync(metadataPath, 'utf8'));
  } catch (error) {
    throw new Error(`Capture metadata is not valid JSON: ${error.message}`);
  }

  if (![1, 2].includes(metadata.schemaVersion)) {
    throw new Error('Capture metadata schemaVersion must equal 1 or 2');
  }
  if (options.requireProvenance && metadata.schemaVersion !== 2) {
    throw new Error(`Capture run-${runNumber} must use metadata schemaVersion 2 with build/font provenance`);
  }
  if (metadata.referenceVersion !== manifest.referenceVersion) {
    throw new Error(
      `Capture referenceVersion ${metadata.referenceVersion} does not match manifest ${manifest.referenceVersion}`,
    );
  }
  if (metadata.runNumber !== runNumber) {
    throw new Error(`Capture metadata runNumber ${metadata.runNumber} does not match directory run-${runNumber}`);
  }
  if (!deepEqual(metadata.viewport, REQUIRED_VIEWPORT) || !deepEqual(metadata.viewport, manifest.viewport)) {
    throw new Error('Capture viewport must be 1280x800 at DPR 2 and match the manifest viewport');
  }
  if (!deepEqual(metadata.physicalSize, REQUIRED_PHYSICAL)) {
    throw new Error(`Capture physicalSize must be ${REQUIRED_PHYSICAL.width}x${REQUIRED_PHYSICAL.height}`);
  }
  if (Number.isNaN(Date.parse(metadata.capturedAt ?? ''))) {
    throw new Error('Capture metadata capturedAt must be an ISO-8601 date-time');
  }
  const environment = metadata.renderingEnvironment ?? {};
  if (!nonEmptyString(environment.platform) || !nonEmptyString(environment.flutter) ||
      environment.fontMode !== 'bundled') {
    throw new Error('Capture renderingEnvironment must record platform, flutter, and fontMode "bundled"');
  }
  if (options.requireManifestEnvironment !== false &&
      !deepEqual(environment, manifest.renderingEnvironment)) {
    throw new Error(
      'Capture renderingEnvironment must exactly match the approved manifest renderingEnvironment',
    );
  }
  if (!/^[0-9a-f]{64}$/.test(metadata.fixtureRevision ?? '')) {
    throw new Error('Capture metadata fixtureRevision must be a lowercase SHA-256 hex digest');
  }
  if (metadata.schemaVersion === 2) {
    for (const field of ['buildRevision', 'fontRevision']) {
      if (!/^[0-9a-f]{64}$/.test(metadata[field] ?? '')) {
        throw new Error(`Capture metadata ${field} must be a lowercase SHA-256 hex digest`);
      }
    }
    if (!Array.isArray(metadata.fonts) || metadata.fonts.length === 0) {
      throw new Error('Capture metadata fonts must list at least one rendered font source');
    }
    const fontIds = new Set();
    for (const [index, font] of metadata.fonts.entries()) {
      if (font == null || typeof font !== 'object' || Array.isArray(font) ||
          !nonEmptyString(font.id) || !nonEmptyString(font.source) ||
          !/^[0-9a-f]{64}$/.test(font.sha256 ?? '')) {
        throw new Error(`Capture metadata fonts[${index}] must record id, source, and sha256`);
      }
      if (fontIds.has(font.id)) {
        throw new Error(`Capture metadata font id is duplicated: ${font.id}`);
      }
      fontIds.add(font.id);
    }
  }

  if (!Array.isArray(metadata.files)) {
    throw new Error('Capture metadata files must be an array');
  }
  const manifestPairs = new Map(manifest.screens.map((entry) => [`${entry.id}:${entry.theme}`, entry]));
  if (metadata.files.length !== manifestPairs.size) {
    throw new Error(
      `Capture set must contain exactly ${manifestPairs.size} entries, received ${metadata.files.length}`,
    );
  }
  const actualPngNames = fs.readdirSync(runDir)
    .filter((name) => name.toLowerCase().endsWith('.png'))
    .sort();
  const metadataPngNames = metadata.files.map((file) => file.file).sort();
  if (!deepEqual(actualPngNames, metadataPngNames)) {
    throw new Error(
      `Capture directory PNGs must exactly match metadata files; ` +
      `directory=${actualPngNames.join(', ')} metadata=${metadataPngNames.join(', ')}`,
    );
  }

  const seen = new Set();
  const captures = new Map();
  for (const file of metadata.files) {
    const pair = `${file.screen}:${file.theme}`;
    if (!manifestPairs.has(pair)) {
      throw new Error(`Capture entry ${pair} is not declared by the manifest`);
    }
    if (seen.has(pair)) {
      throw new Error(`Capture entry ${pair} is duplicated`);
    }
    seen.add(pair);
    const expectedName = `${file.screen}-${file.theme}.png`;
    if (file.file !== expectedName) {
      throw new Error(`Capture entry ${pair} must be named ${expectedName}, received ${file.file}`);
    }
    if (file.width !== REQUIRED_PHYSICAL.width || file.height !== REQUIRED_PHYSICAL.height) {
      throw new Error(
        `Capture ${file.file} metadata must record ${REQUIRED_PHYSICAL.width}x${REQUIRED_PHYSICAL.height}, ` +
        `received ${file.width}x${file.height}`,
      );
    }
    if (!/^[0-9a-f]{64}$/.test(file.sha256 ?? '')) {
      throw new Error(`Capture ${file.file} must record a lowercase SHA-256 hex digest`);
    }
    const capturePath = path.join(runDir, file.file);
    if (!fs.existsSync(capturePath)) {
      throw new Error(`Capture file does not exist: ${capturePath}`);
    }
    if (fs.lstatSync(capturePath).isSymbolicLink() ||
        !fs.lstatSync(capturePath).isFile() ||
        !isInside(runReal, fs.realpathSync(capturePath))) {
      throw new Error(`Capture file must be a regular file inside the run directory: ${capturePath}`);
    }
    const actualHash = sha256File(capturePath);
    if (actualHash !== file.sha256) {
      throw new Error(`Capture ${file.file} sha256 mismatch: metadata ${file.sha256}, actual ${actualHash}`);
    }
    const size = readPngSize(capturePath);
    if (size.width !== REQUIRED_PHYSICAL.width || size.height !== REQUIRED_PHYSICAL.height) {
      throw new Error(
        `Capture ${file.file} must be ${REQUIRED_PHYSICAL.width}x${REQUIRED_PHYSICAL.height}, ` +
        `received ${size.width}x${size.height}`,
      );
    }
    captures.set(pair, capturePath);
  }
  for (const pair of manifestPairs.keys()) {
    if (!seen.has(pair)) {
      throw new Error(`Capture set is missing ${pair}`);
    }
  }
  return { metadata, metadataPath, captures };
}

function luminanceAt(png, x, y) {
  const index = (y * png.width + x) * 4;
  return 0.299 * png.data[index] + 0.587 * png.data[index + 1] + 0.114 * png.data[index + 2];
}

function scanEdge(png, orientation, center, spanStart, spanEnd, window) {
  const limit = orientation === 'vertical' ? png.width : png.height;
  const from = Math.max(0, center - window);
  const to = Math.min(limit - 2, center + window - 1);
  if (from > to || spanStart >= spanEnd) {
    return { position: null, gradient: 0 };
  }
  let best = null;
  for (let c = from; c <= to; c++) {
    let sum = 0;
    for (let s = spanStart; s < spanEnd; s++) {
      const before = orientation === 'vertical' ? luminanceAt(png, c, s) : luminanceAt(png, s, c);
      const after = orientation === 'vertical' ? luminanceAt(png, c + 1, s) : luminanceAt(png, s, c + 1);
      sum += Math.abs(after - before);
    }
    const gradient = sum / (spanEnd - spanStart);
    if (best === null || gradient > best.gradient ||
        (gradient === best.gradient && Math.abs(c - center) < Math.abs(best.position - center))) {
      best = { position: c, gradient };
    }
  }
  if (best.gradient < EDGE_MIN_GRADIENT) {
    return { position: null, gradient: best.gradient };
  }
  return best;
}

function edgeDelta(reference, actual, orientation, center, spanStart, spanEnd, window) {
  const ref = scanEdge(reference, orientation, center, spanStart, spanEnd, window);
  const act = scanEdge(actual, orientation, center, spanStart, spanEnd, window);
  if (ref.position === null || act.position === null) {
    return { delta: 0, measurable: false };
  }
  return { delta: act.position - ref.position, measurable: true };
}

function measureAnchor(reference, actual, region, dpr, options = {}) {
  const window = options.window ?? EDGE_SEARCH_WINDOW_PX;
  const x0 = Math.round(region.x * dpr);
  const y0 = Math.round(region.y * dpr);
  const x1 = Math.round((region.x + region.width) * dpr);
  const y1 = Math.round((region.y + region.height) * dpr);
  const rowStart = Math.max(0, y0);
  const rowEnd = Math.min(reference.height, y1);
  const colStart = Math.max(0, x0);
  const colEnd = Math.min(reference.width, x1);

  const boundary = { delta: 0, measurable: true, boundary: true };
  const left = x0 === 0
    ? boundary
    : edgeDelta(reference, actual, 'vertical', x0, rowStart, rowEnd, window);
  const right = x1 === reference.width
    ? boundary
    : edgeDelta(reference, actual, 'vertical', x1 - 1, rowStart, rowEnd, window);
  const top = y0 === 0
    ? boundary
    : edgeDelta(reference, actual, 'horizontal', y0, colStart, colEnd, window);
  const bottom = y1 === reference.height
    ? boundary
    : edgeDelta(reference, actual, 'horizontal', y1 - 1, colStart, colEnd, window);

  const unmeasurableEdges = [];
  for (const [name, edge] of [['left', left], ['right', right], ['top', top], ['bottom', bottom]]) {
    if (!edge.measurable) unmeasurableEdges.push(name);
  }
  const x = left.delta / dpr;
  const y = top.delta / dpr;
  const width = (right.delta - left.delta) / dpr;
  const height = (bottom.delta - top.delta) / dpr;
  const maxAbs = Math.max(Math.abs(x), Math.abs(y), Math.abs(width), Math.abs(height));
  return { x, y, width, height, maxAbs, unmeasurableEdges };
}

function compareRegion(reference, actual, rect) {
  const differing = { count: 0, samples: 0, sums: { r: 0, g: 0, b: 0, a: 0 } };
  for (let y = rect.y0; y < rect.y1; y++) {
    let index = (y * reference.width + rect.x0) * 4;
    for (let x = rect.x0; x < rect.x1; x++, index += 4) {
      const dr = Math.abs(actual.data[index] - reference.data[index]);
      const dg = Math.abs(actual.data[index + 1] - reference.data[index + 1]);
      const db = Math.abs(actual.data[index + 2] - reference.data[index + 2]);
      const da = Math.abs(actual.data[index + 3] - reference.data[index + 3]);
      if (dr || dg || db || da) differing.count++;
      differing.samples++;
      differing.sums.r += dr;
      differing.sums.g += dg;
      differing.sums.b += db;
      differing.sums.a += da;
    }
  }
  return differing;
}

function comparePair(reference, actual, entry, dpr, options = {}) {
  if (reference.width !== actual.width || reference.height !== actual.height) {
    throw new Error(
      `Dimension mismatch for ${entry.id}:${entry.theme}: ` +
      `reference ${reference.width}x${reference.height}, actual ${actual.width}x${actual.height}`,
    );
  }
  if (reference.depth !== actual.depth || reference.colorType !== actual.colorType) {
    throw new Error(
      `Color-space mismatch for ${entry.id}:${entry.theme}: ` +
      `reference depth/type ${reference.depth}/${reference.colorType}, ` +
      `actual ${actual.depth}/${actual.colorType}`,
    );
  }
  const expectedPhysical = options.expectedPhysical ?? REQUIRED_PHYSICAL;
  if (reference.width !== expectedPhysical.width || reference.height !== expectedPhysical.height) {
    throw new Error(
      `Images for ${entry.id}:${entry.theme} must be ${expectedPhysical.width}x${expectedPhysical.height}, ` +
      `received ${reference.width}x${reference.height}`,
    );
  }

  const full = compareRegion(reference, actual, {
    x0: 0, y0: 0, x1: reference.width, y1: reference.height,
  });
  const roiDiffRatios = {};
  const channelMAE = {};
  const anchors = {};
  let maxGeometryDeviationPx = 0;
  for (const region of entry.regions) {
    const rect = {
      x0: Math.round(region.x * dpr),
      y0: Math.round(region.y * dpr),
      x1: Math.round((region.x + region.width) * dpr),
      y1: Math.round((region.y + region.height) * dpr),
    };
    const result = compareRegion(reference, actual, rect);
    roiDiffRatios[region.id] = {
      diffRatio: result.count / result.samples,
      differingPixels: result.count,
      comparedPixels: result.samples,
    };
    channelMAE[region.id] = {};
    for (const channel of CHANNELS) {
      channelMAE[region.id][channel] = result.sums[channel] / (result.samples * 255);
    }
    const anchor = measureAnchor(reference, actual, region, dpr);
    anchors[region.id] = anchor;
    maxGeometryDeviationPx = Math.max(maxGeometryDeviationPx, anchor.maxAbs);
  }

  return {
    screen: entry.id,
    theme: entry.theme,
    reference: entry.file,
    fullFrameDiffRatio: full.count / full.samples,
    differingPixels: full.count,
    comparedPixels: full.samples,
    roiDiffRatios,
    geometry: { maxGeometryDeviationPx, anchors },
    channelMAE,
  };
}

function loadThresholds(thresholdsPath, manifest) {
  let envelope;
  try {
    envelope = JSON.parse(fs.readFileSync(path.resolve(thresholdsPath), 'utf8'));
  } catch (error) {
    throw new Error(`Thresholds file is not valid JSON: ${error.message}`);
  }
  if (envelope == null || typeof envelope !== 'object' || Array.isArray(envelope)) {
    throw new Error('Thresholds file must be a JSON object');
  }
  const envelopeKeys = new Set([
    'schemaVersion', 'referenceVersion', 'approval', 'reviewer', 'reason', 'approvedAt', 'metrics',
  ]);
  for (const key of Object.keys(envelope)) {
    if (!envelopeKeys.has(key)) throw new Error(`Unknown thresholds envelope field: ${key}`);
  }
  if (envelope.schemaVersion !== 1) throw new Error('Thresholds schemaVersion must equal 1');
  if (envelope.referenceVersion !== manifest.referenceVersion) {
    throw new Error(
      `Thresholds referenceVersion ${envelope.referenceVersion} does not match manifest ${manifest.referenceVersion}`,
    );
  }
  if (envelope.approval !== 'approved') {
    throw new Error('Thresholds approval must be "approved"');
  }
  if (!nonEmptyString(envelope.reviewer) || !nonEmptyString(envelope.reason)) {
    throw new Error('Approved thresholds must record reviewer and reason');
  }
  if (Number.isNaN(Date.parse(envelope.approvedAt ?? ''))) {
    throw new Error('Approved thresholds must record an ISO-8601 approvedAt date-time');
  }

  const thresholds = envelope.metrics;
  if (thresholds == null || typeof thresholds !== 'object' || Array.isArray(thresholds)) {
    throw new Error('Thresholds metrics must be a JSON object');
  }
  const allowed = new Set(['fullFrameDiffRatio', 'roiDiffRatios', 'maxGeometryDeviationPx', 'channelMAE']);
  for (const key of Object.keys(thresholds)) {
    if (!allowed.has(key)) throw new Error(`Unknown thresholds metric: ${key}`);
  }
  if (Object.keys(thresholds).length === 0) {
    throw new Error('Thresholds metrics must configure at least one metric');
  }
  const checkNumber = (value, label, maximum = Number.POSITIVE_INFINITY) => {
    if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > maximum) {
      const range = Number.isFinite(maximum) ? ` between 0 and ${maximum}` : ' non-negative';
      throw new Error(`${label} must be a finite number${range}`);
    }
  };
  if ('fullFrameDiffRatio' in thresholds) checkNumber(thresholds.fullFrameDiffRatio, 'fullFrameDiffRatio', 1);
  if ('maxGeometryDeviationPx' in thresholds) checkNumber(thresholds.maxGeometryDeviationPx, 'maxGeometryDeviationPx');
  if ('roiDiffRatios' in thresholds) {
    const value = thresholds.roiDiffRatios;
    if (typeof value === 'number') {
      checkNumber(value, 'roiDiffRatios', 1);
    } else if (value != null && typeof value === 'object' && !Array.isArray(value)) {
      const declared = new Set(manifest.screens.flatMap((entry) => entry.regions.map((region) => region.id)));
      for (const [roiId, threshold] of Object.entries(value)) {
        if (!declared.has(roiId)) {
          throw new Error(`roiDiffRatios threshold references undeclared ROI: ${roiId}`);
        }
        checkNumber(threshold, `roiDiffRatios.${roiId}`, 1);
      }
      for (const entry of manifest.screens) {
        for (const region of entry.regions) {
          if (!(region.id in value)) {
            throw new Error(`roiDiffRatios threshold is missing ROI ${region.id} declared by ${entry.id}:${entry.theme}`);
          }
        }
      }
    } else {
      throw new Error('roiDiffRatios must be a number or an object keyed by manifest ROI id');
    }
  }
  if ('channelMAE' in thresholds) {
    const value = thresholds.channelMAE;
    if (typeof value === 'number') {
      checkNumber(value, 'channelMAE', 1);
    } else if (value != null && typeof value === 'object' && !Array.isArray(value)) {
      const keys = Object.keys(value);
      if (keys.length !== CHANNELS.length || !CHANNELS.every((channel) => channel in value)) {
        throw new Error(`channelMAE object must declare exactly ${CHANNELS.join(', ')}`);
      }
      for (const channel of CHANNELS) checkNumber(value[channel], `channelMAE.${channel}`, 1);
    } else {
      throw new Error('channelMAE must be a number or an object keyed by channel');
    }
  }
  return { ...envelope, metrics: thresholds };
}

function evaluateThresholds(metrics, thresholds) {
  const violations = [];
  const exceed = (metric, scope, value, threshold) => {
    if (value > threshold) {
      violations.push({ metric, scope, value, threshold });
    }
  };
  if ('fullFrameDiffRatio' in thresholds) {
    exceed('fullFrameDiffRatio', 'fullFrame', metrics.fullFrameDiffRatio, thresholds.fullFrameDiffRatio);
  }
  if ('roiDiffRatios' in thresholds) {
    for (const [roiId, roi] of Object.entries(metrics.roiDiffRatios)) {
      const threshold = typeof thresholds.roiDiffRatios === 'number'
        ? thresholds.roiDiffRatios
        : thresholds.roiDiffRatios[roiId];
      exceed('roiDiffRatio', roiId, roi.diffRatio, threshold);
    }
  }
  if ('maxGeometryDeviationPx' in thresholds) {
    for (const [anchorId, anchor] of Object.entries(metrics.geometry.anchors)) {
      for (const edge of anchor.unmeasurableEdges) {
        violations.push({
          metric: 'geometryAnchorMeasurability',
          scope: `${anchorId}.${edge}`,
          value: null,
          threshold: 'measurable edge required',
        });
      }
    }
    exceed(
      'maxGeometryDeviationPx',
      'anchors',
      metrics.geometry.maxGeometryDeviationPx,
      thresholds.maxGeometryDeviationPx,
    );
  }
  if ('channelMAE' in thresholds) {
    for (const [roiId, channels] of Object.entries(metrics.channelMAE)) {
      for (const channel of CHANNELS) {
        const threshold = typeof thresholds.channelMAE === 'number'
          ? thresholds.channelMAE
          : thresholds.channelMAE[channel];
        exceed('channelMAE', `${roiId}.${channel}`, channels[channel], threshold);
      }
    }
  }
  return violations;
}

function resolveReportsRoot(activeRoot, reportsDir) {
  const allowedRoot = path.join(path.resolve(activeRoot), 'reports');
  const root = path.resolve(reportsDir ?? allowedRoot);
  if (!isInside(allowedRoot, root)) {
    throw new Error(`Reports directory must stay under the active reports directory: ${root}`);
  }
  if (!fs.existsSync(allowedRoot) || !fs.statSync(allowedRoot).isDirectory()) {
    throw new Error(`Active reports directory does not exist: ${allowedRoot}`);
  }
  const realAllowed = fs.realpathSync(allowedRoot);
  if (!isInside(fs.realpathSync(activeRoot), realAllowed)) {
    throw new Error(`Active reports directory resolves outside the active root: ${allowedRoot}`);
  }
  if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
    throw new Error(`Reports directory does not exist: ${root}`);
  }
  if (!isInside(realAllowed, fs.realpathSync(root))) {
    throw new Error(`Reports directory resolves outside the active reports directory: ${root}`);
  }
  return root;
}

function writeFailureArtifacts(reportRoot, baseName, referencePath, actualPath, reference, actual, metrics) {
  const diff = new PNG({ width: reference.width, height: reference.height });
  pixelmatch(reference.data, actual.data, diff.data, reference.width, reference.height, {
    threshold: 0,
    includeAA: true,
  });
  const files = {
    expected: path.join(reportRoot, `${baseName}-expected.png`),
    actual: path.join(reportRoot, `${baseName}-actual.png`),
    diff: path.join(reportRoot, `${baseName}-diff.png`),
    metrics: path.join(reportRoot, `${baseName}-metrics.json`),
  };
  const exclusive = { flag: 'wx' };
  fs.writeFileSync(files.expected, fs.readFileSync(referencePath), exclusive);
  fs.writeFileSync(files.actual, fs.readFileSync(actualPath), exclusive);
  fs.writeFileSync(files.diff, PNG.sync.write(diff), exclusive);
  fs.writeFileSync(files.metrics, `${JSON.stringify(metrics, null, 2)}\n`, exclusive);
  return files;
}

function runActiveDiff(options = {}) {
  if (!nonEmptyString(options.manifestPath)) {
    throw new Error('An acceptance manifest path is required (--manifest)');
  }
  if (!nonEmptyString(options.runDir)) {
    throw new Error('A capture run directory is required (--run captures/run-N)');
  }
  const manifestPath = path.resolve(options.manifestPath);
  const manifest = loadReferenceManifest(manifestPath, { mode: 'acceptance' });
  const activeRoot = path.dirname(manifestPath);
  const { metadata, captures } = loadCaptureRun(options.runDir, manifest, { activeRoot });
  const thresholds = options.thresholdsPath ? loadThresholds(options.thresholdsPath, manifest) : null;
  const reportsRoot = resolveReportsRoot(activeRoot, options.reportsDir);
  const dpr = manifest.viewport.dpr;

  const pairs = [];
  const evidence = new Map();
  for (const entry of manifest.screens) {
    const pair = `${entry.id}:${entry.theme}`;
    const referencePath = path.join(activeRoot, entry.file);
    const actualPath = captures.get(pair);
    const reference = readPng(referencePath);
    const actual = readPng(actualPath);
    const metrics = comparePair(reference, actual, entry, dpr);
    metrics.capture = path.join(path.basename(path.dirname(actualPath)), path.basename(actualPath));
    if (thresholds) {
      metrics.violations = evaluateThresholds(metrics, thresholds.metrics);
      metrics.passed = metrics.violations.length === 0;
    } else {
      metrics.passed = null;
    }
    evidence.set(pair, { referencePath, actualPath });
    pairs.push(metrics);
  }

  const failed = thresholds ? pairs.filter((pair) => !pair.passed) : [];
  let reportRunRoot = null;
  if (failed.length > 0) {
    fs.mkdirSync(reportsRoot, { recursive: true });
    reportRunRoot = path.join(reportsRoot, `run-${metadata.runNumber}`);
    try {
      fs.mkdirSync(reportRunRoot);
    } catch (error) {
      if (error.code === 'EEXIST') {
        throw new Error(`Refusing to overwrite existing failure report run: ${reportRunRoot}`);
      }
      throw error;
    }
    for (const metrics of failed) {
      const pair = `${metrics.screen}:${metrics.theme}`;
      const { referencePath, actualPath } = evidence.get(pair);
      const reference = readPng(referencePath);
      const actual = readPng(actualPath);
      metrics.reportFiles = writeFailureArtifacts(
        reportRunRoot,
        `${metrics.screen}-${metrics.theme}`,
        referencePath,
        actualPath,
        reference,
        actual,
        metrics,
      );
    }
  }

  return {
    manifest: manifestPath,
    referenceVersion: manifest.referenceVersion,
    runNumber: metadata.runNumber,
    capturedAt: metadata.capturedAt,
    renderingEnvironment: metadata.renderingEnvironment,
    fixtureRevision: metadata.fixtureRevision,
    thresholds: thresholds ? {
      file: path.resolve(options.thresholdsPath),
      approval: thresholds.approval,
      reviewer: thresholds.reviewer,
      approvedAt: thresholds.approvedAt,
    } : null,
    reportsRoot,
    reportRunRoot,
    pairs,
    passed: thresholds ? failed.length === 0 : null,
  };
}

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!['--manifest', '--run', '--thresholds', '--reports'].includes(key) || value === undefined) {
      throw new Error(`Unknown or incomplete argument: ${key}`);
    }
    if (parsed[key] !== undefined) {
      throw new Error(`Duplicate argument: ${key}`);
    }
    parsed[key] = value;
  }
  return parsed;
}

function main(argv) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (error) {
    console.error(error.message);
    console.error(
      'Usage: node active-diff.js --manifest <manifest.json> --run <captures/run-N> ' +
      '[--thresholds <thresholds.json>] [--reports <dir>]',
    );
    process.exitCode = 2;
    return;
  }
  try {
    const result = runActiveDiff({
      manifestPath: args['--manifest'],
      runDir: args['--run'],
      thresholdsPath: args['--thresholds'],
      reportsDir: args['--reports'],
    });
    console.log(JSON.stringify(result, null, 2));
    if (result.passed === false) {
      process.exitCode = 1;
    }
  } catch (error) {
    if (error instanceof ManifestValidationError) {
      console.error(error.message);
    } else {
      console.error(`[active-diff] ${error.message}`);
    }
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main(process.argv.slice(2));
}

module.exports = {
  CHANNELS,
  EDGE_MIN_GRADIENT,
  EDGE_SEARCH_WINDOW_PX,
  METADATA_FILE,
  REPORT_FILES,
  comparePair,
  evaluateThresholds,
  loadCaptureRun,
  loadThresholds,
  measureAnchor,
  readPng,
  runActiveDiff,
};
