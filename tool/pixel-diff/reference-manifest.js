'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const SCREENS = Object.freeze([
  'inst-browse',
  'inst-console',
  'inst-monitor',
  'inst-logs',
  'inst-playground',
  'inst-config',
  'ep-overview',
  'ep-browser',
]);
// Stage 16.2: capture-only Service-entity screens. They participate in the
// capture channel and noise-floor measurement but OWN NO reference baseline:
// they can only ever be candidates, so the acceptance baseline below stays
// exactly SCREENS × THEMES.
const SERVICE_SCREENS = Object.freeze([
  'svc-empty',
  'svc-overview-running',
  'svc-overview-failed',
  'svc-monitor',
  'svc-logs',
  'svc-configure',
]);
const CAPTURE_SCREENS = Object.freeze([...SCREENS, ...SERVICE_SCREENS]);
const THEMES = Object.freeze(['light', 'dark']);
const APPROVALS = Object.freeze(['candidate', 'approved', 'rejected']);
const REQUIRED_VIEWPORT = Object.freeze({
  logicalWidth: 1280,
  logicalHeight: 800,
  dpr: 2,
});
const REQUIRED_PHYSICAL = Object.freeze({ width: 2560, height: 1600 });
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

class ManifestValidationError extends Error {
  constructor(manifestPath, issues) {
    const heading = manifestPath
      ? `Reference manifest validation failed: ${manifestPath}`
      : 'Reference manifest validation failed';
    super(`${heading}\n${issues.map(formatIssue).join('\n')}`);
    this.name = 'ManifestValidationError';
    this.issues = issues;
  }
}

function issue(code, fieldPath, message) {
  return { code, path: fieldPath, message };
}

function formatIssue(value) {
  return `  - [${value.code}] ${value.path}: ${value.message}`;
}

function isObject(value) {
  return value != null && typeof value === 'object' && !Array.isArray(value);
}

function hasKeys(value, keys, fieldPath, issues) {
  if (!isObject(value)) {
    issues.push(issue('invalid-type', fieldPath, 'must be an object'));
    return false;
  }
  let complete = true;
  for (const key of keys) {
    if (!(key in value)) {
      complete = false;
      issues.push(issue('missing-field', `${fieldPath}.${key}`, 'is required'));
    }
  }
  return complete;
}

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function validateEnvironment(value, fieldPath, issues) {
  if (!hasKeys(value, ['platform', 'flutter', 'fontMode'], fieldPath, issues)) {
    return;
  }
  for (const key of ['platform', 'flutter']) {
    if (!nonEmptyString(value[key])) {
      issues.push(issue('invalid-field', `${fieldPath}.${key}`, 'must be a non-empty string'));
    }
  }
  if (value.fontMode !== 'bundled') {
    issues.push(issue('invalid-font-mode', `${fieldPath}.fontMode`, 'must be "bundled"'));
  }
}

function validateViewport(value, mode, issues) {
  if (!hasKeys(value, ['logicalWidth', 'logicalHeight', 'dpr'], 'viewport', issues)) {
    return null;
  }
  const positive =
    Number.isInteger(value.logicalWidth) && value.logicalWidth > 0 &&
    Number.isInteger(value.logicalHeight) && value.logicalHeight > 0 &&
    typeof value.dpr === 'number' && Number.isFinite(value.dpr) && value.dpr > 0;
  if (!positive) {
    issues.push(issue('invalid-viewport', 'viewport', 'width/height must be positive integers and DPR must be positive'));
    return null;
  }
  if (mode === 'acceptance') {
    for (const [key, expected] of Object.entries(REQUIRED_VIEWPORT)) {
      if (value[key] !== expected) {
        issues.push(issue(
          'wrong-viewport',
          `viewport.${key}`,
          `expected ${expected}, received ${value[key]}`,
        ));
      }
    }
  }
  return value;
}

function containsArchiveSegment(filePath) {
  return filePath.split(/[\\/]+/).some((segment) => segment === 'v2.3-archive');
}

function isInside(root, target) {
  const relative = path.relative(root, target);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function resolveReferencePath(file, activeRoot, fieldPath, issues) {
  if (!nonEmptyString(file)) {
    issues.push(issue('invalid-file', fieldPath, 'must be a non-empty relative PNG path'));
    return null;
  }
  if (path.isAbsolute(file)) {
    issues.push(issue('absolute-path', fieldPath, 'must be relative to the active manifest root'));
    return null;
  }
  if (containsArchiveSegment(file)) {
    issues.push(issue('archive-path', fieldPath, 'must not reference v2.3-archive'));
    return null;
  }
  if (path.extname(file).toLowerCase() !== '.png') {
    issues.push(issue('invalid-file', fieldPath, 'must reference a PNG file'));
    return null;
  }
  const resolved = path.resolve(activeRoot, file);
  if (!isInside(activeRoot, resolved)) {
    issues.push(issue('path-escape', fieldPath, 'escapes the active manifest root'));
    return null;
  }
  return resolved;
}

function sha256File(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function validateNoiseMeasurement(measurement, activeRoot, referenceVersion, issues) {
  if (measurement === undefined) return;
  const fieldPath = 'noiseMeasurement';
  if (!hasKeys(
    measurement,
    [
      'status',
      'runNumbers',
      'report',
      'thresholdPolicy',
      'thresholdApproval',
      'legacyV23ThresholdImported',
      'rationale',
    ],
    fieldPath,
    issues,
  )) {
    return;
  }
  if (!['planned', 'measured'].includes(measurement.status)) {
    issues.push(issue('invalid-noise-measurement', `${fieldPath}.status`, 'must be planned or measured'));
  }
  if (!Array.isArray(measurement.runNumbers) || measurement.runNumbers.length < 3 ||
      new Set(measurement.runNumbers).size !== measurement.runNumbers.length ||
      measurement.runNumbers.some((value) => !Number.isInteger(value) || value < 1)) {
    issues.push(issue('invalid-noise-measurement', `${fieldPath}.runNumbers`, 'must list at least three unique positive integers'));
  }
  if (measurement.thresholdPolicy !== 'strictly-greater-than-measured-noise') {
    issues.push(issue('invalid-noise-measurement', `${fieldPath}.thresholdPolicy`, 'must require thresholds strictly greater than measured noise'));
  }
  if (measurement.thresholdApproval !== 'pending') {
    issues.push(issue('invalid-noise-measurement', `${fieldPath}.thresholdApproval`, 'must remain pending until independent approval'));
  }
  if (measurement.legacyV23ThresholdImported !== false) {
    issues.push(issue('invalid-noise-measurement', `${fieldPath}.legacyV23ThresholdImported`, 'must explicitly remain false'));
  }
  if (!nonEmptyString(measurement.rationale)) {
    issues.push(issue('invalid-noise-measurement', `${fieldPath}.rationale`, 'must explain the measured Codex noise basis'));
  }
  if (!nonEmptyString(measurement.report) || path.isAbsolute(measurement.report) ||
      containsArchiveSegment(measurement.report) || path.extname(measurement.report).toLowerCase() !== '.json') {
    issues.push(issue('invalid-noise-report', `${fieldPath}.report`, 'must be a relative JSON path under reports outside the archive'));
    return;
  }
  const reportRoot = path.resolve(activeRoot, 'reports');
  const reportPath = path.resolve(activeRoot, measurement.report);
  if (!isInside(reportRoot, reportPath)) {
    issues.push(issue('invalid-noise-report', `${fieldPath}.report`, 'must stay under the active reports directory'));
    return;
  }
  if (measurement.status !== 'measured') return;
  if (!/^[0-9a-f]{64}$/.test(measurement.reportSha256 ?? '')) {
    issues.push(issue('invalid-noise-report-hash', `${fieldPath}.reportSha256`, 'is required for measured status and must be a lowercase SHA-256 digest'));
    return;
  }
  if (!fs.existsSync(reportPath)) {
    issues.push(issue('missing-noise-report', `${fieldPath}.report`, `file does not exist: ${reportPath}`));
    return;
  }
  try {
    const stat = fs.lstatSync(reportPath);
    if (!stat.isFile() || stat.isSymbolicLink()) {
      throw new Error('must be a regular file and not a symbolic link');
    }
    const realReportRoot = fs.realpathSync(reportRoot);
    const realReport = fs.realpathSync(reportPath);
    if (!isInside(realReportRoot, realReport) || containsArchiveSegment(realReport)) {
      throw new Error('resolved file leaves the active reports directory or enters the archive');
    }
    const actualSha256 = sha256File(realReport);
    if (actualSha256 !== measurement.reportSha256) {
      issues.push(issue('noise-report-hash-mismatch', `${fieldPath}.reportSha256`, `expected ${measurement.reportSha256}, received ${actualSha256}`));
      return;
    }
    const report = JSON.parse(fs.readFileSync(realReport, 'utf8'));
    if (report.referenceVersion !== referenceVersion ||
        JSON.stringify(report.runNumbers) !== JSON.stringify(measurement.runNumbers) ||
        report.thresholdPolicy !== measurement.thresholdPolicy ||
        report.thresholdApproval !== 'pending' ||
        report.legacyV23ThresholdImported !== false) {
      issues.push(issue('noise-report-mismatch', `${fieldPath}.report`, 'must match referenceVersion, runNumbers, threshold policy, pending approval, and legacy exclusion'));
    }
  } catch (error) {
    issues.push(issue('invalid-noise-report', `${fieldPath}.report`, error.message));
  }
}

function readPngSize(filePath) {
  const fd = fs.openSync(filePath, 'r');
  try {
    const header = Buffer.alloc(24);
    const count = fs.readSync(fd, header, 0, header.length, 0);
    if (
      count !== header.length ||
      !header.subarray(0, 8).equals(PNG_SIGNATURE) ||
      header.toString('ascii', 12, 16) !== 'IHDR'
    ) {
      throw new Error('invalid PNG signature or truncated IHDR');
    }
    return { width: header.readUInt32BE(16), height: header.readUInt32BE(20) };
  } finally {
    fs.closeSync(fd);
  }
}

function validateRegion(region, fieldPath, viewport, issues) {
  if (!hasKeys(region, ['id', 'x', 'y', 'width', 'height'], fieldPath, issues)) {
    return;
  }
  if (!nonEmptyString(region.id)) {
    issues.push(issue('invalid-region', `${fieldPath}.id`, 'must be a non-empty string'));
  }
  const values = ['x', 'y', 'width', 'height'];
  if (values.some((key) => typeof region[key] !== 'number' || !Number.isFinite(region[key]))) {
    issues.push(issue('invalid-region', fieldPath, 'coordinates and dimensions must be finite numbers'));
    return;
  }
  if (region.x < 0 || region.y < 0 || region.width <= 0 || region.height <= 0) {
    issues.push(issue('invalid-region', fieldPath, 'must have a non-negative origin and positive dimensions'));
    return;
  }
  if (viewport &&
      (region.x + region.width > viewport.logicalWidth ||
       region.y + region.height > viewport.logicalHeight)) {
    issues.push(issue('region-out-of-bounds', fieldPath, 'extends beyond the logical viewport'));
  }
}

function validateHistory(history, mode, issues) {
  if (!Array.isArray(history) || history.length === 0) {
    issues.push(issue('missing-history', 'history', 'must contain at least one baseline history entry'));
    return;
  }
  let hasApprovedHistory = false;
  history.forEach((entry, index) => {
    const fieldPath = `history[${index}]`;
    if (!hasKeys(
      entry,
      ['reason', 'affected', 'renderingEnvironment', 'approval', 'recordedAt'],
      fieldPath,
      issues,
    )) {
      return;
    }
    if (!nonEmptyString(entry.reason)) {
      issues.push(issue('invalid-history', `${fieldPath}.reason`, 'must be a non-empty string'));
    }
    if (!Array.isArray(entry.affected) || entry.affected.length === 0 ||
        entry.affected.some((value) => !nonEmptyString(value))) {
      issues.push(issue('invalid-history', `${fieldPath}.affected`, 'must list at least one affected screen/theme or "all"'));
    }
    validateEnvironment(entry.renderingEnvironment, `${fieldPath}.renderingEnvironment`, issues);
    for (const key of ['fixtureRevision', 'buildRevision', 'fontRevision']) {
      if (key in entry && !/^[0-9a-f]{64}$/.test(entry[key])) {
        issues.push(issue('invalid-history', `${fieldPath}.${key}`, 'must be a lowercase SHA-256 digest'));
      }
    }
    if (!APPROVALS.includes(entry.approval)) {
      issues.push(issue('invalid-approval', `${fieldPath}.approval`, `must be one of ${APPROVALS.join(', ')}`));
    }
    if (!nonEmptyString(entry.recordedAt) || Number.isNaN(Date.parse(entry.recordedAt))) {
      issues.push(issue('invalid-history', `${fieldPath}.recordedAt`, 'must be an ISO-8601 date-time'));
    }
    if (entry.approval === 'approved') {
      hasApprovedHistory = true;
      if (!nonEmptyString(entry.reviewer)) {
        issues.push(issue('missing-reviewer', `${fieldPath}.reviewer`, 'is required for approved history'));
      }
    }
  });
  if (mode === 'acceptance' && !hasApprovedHistory) {
    issues.push(issue('missing-approval-history', 'history', 'must record reviewer approval for the accepted baseline'));
  }
}

function validateReferenceManifest(manifest, options = {}) {
  const mode = options.mode ?? 'acceptance';
  if (!['draft', 'acceptance'].includes(mode)) {
    throw new TypeError(`Unknown manifest validation mode: ${mode}`);
  }
  const manifestPath = options.manifestPath ? path.resolve(options.manifestPath) : null;
  const activeRoot = path.resolve(options.activeRoot ?? (manifestPath ? path.dirname(manifestPath) : process.cwd()));
  const checkFiles = options.checkFiles ?? mode === 'acceptance';
  const issues = [];

  if (!hasKeys(
    manifest,
    ['schemaVersion', 'referenceVersion', 'viewport', 'renderingEnvironment', 'screens', 'history'],
    '$',
    issues,
  )) {
    throw new ManifestValidationError(manifestPath, issues);
  }
  if (manifest.schemaVersion !== 1) {
    issues.push(issue('unsupported-schema', 'schemaVersion', 'must equal 1'));
  }
  if (!nonEmptyString(manifest.referenceVersion) ||
      !/^[a-z0-9][a-z0-9._-]*$/.test(manifest.referenceVersion)) {
    issues.push(issue('invalid-version', 'referenceVersion', 'must be a lowercase version identifier'));
  }

  const viewport = validateViewport(manifest.viewport, mode, issues);
  validateEnvironment(manifest.renderingEnvironment, 'renderingEnvironment', issues);
  validateHistory(manifest.history, mode, issues);
  validateNoiseMeasurement(manifest.noiseMeasurement, activeRoot, manifest.referenceVersion, issues);

  if (!Array.isArray(manifest.screens)) {
    issues.push(issue('invalid-type', 'screens', 'must be an array'));
  } else {
    const pairs = new Set();
    const files = new Set();
    manifest.screens.forEach((entry, index) => {
      const fieldPath = `screens[${index}]`;
      if (!isObject(entry)) {
        hasKeys(entry, ['id', 'theme', 'file', 'source', 'approval', 'regions'], fieldPath, issues);
        return;
      }
      hasKeys(entry, ['id', 'theme', 'file', 'source', 'approval', 'regions'], fieldPath, issues);
      if (!CAPTURE_SCREENS.includes(entry.id)) {
        issues.push(issue('invalid-screen', `${fieldPath}.id`, `must be one of ${CAPTURE_SCREENS.join(', ')}`));
      }
      if (!THEMES.includes(entry.theme)) {
        issues.push(issue('invalid-theme', `${fieldPath}.theme`, 'must be light or dark'));
      }
      const pair = `${entry.id}:${entry.theme}`;
      if (pairs.has(pair)) {
        issues.push(issue('duplicate-pair', fieldPath, `duplicates ${pair}`));
      }
      pairs.add(pair);
      if (files.has(entry.file)) {
        issues.push(issue('duplicate-file', `${fieldPath}.file`, `duplicates ${entry.file}`));
      }
      files.add(entry.file);

      if (
        nonEmptyString(entry.file) &&
        CAPTURE_SCREENS.includes(entry.id) &&
        THEMES.includes(entry.theme)
      ) {
        const expectedName = `${entry.id}-${entry.theme}.png`;
        if (path.basename(entry.file) !== expectedName) {
          issues.push(issue('wrong-filename', `${fieldPath}.file`, `must end with ${expectedName}`));
        }
      }
      if (!nonEmptyString(entry.source)) {
        issues.push(issue('missing-source', `${fieldPath}.source`, 'must describe the approved Codex reference source'));
      }
      if (entry.source === 'v2.3-html-mockup') {
        issues.push(issue('legacy-source', `${fieldPath}.source`, 'v2.3 HTML is archive evidence, not an active Codex target'));
      }
      if (!APPROVALS.includes(entry.approval)) {
        issues.push(issue('invalid-approval', `${fieldPath}.approval`, `must be one of ${APPROVALS.join(', ')}`));
      } else if (mode === 'acceptance' && entry.approval !== 'approved') {
        issues.push(issue('unapproved-reference', `${fieldPath}.approval`, `${pair} is ${entry.approval}, expected approved`));
      }

      if (!Array.isArray(entry.regions) || entry.regions.length === 0) {
        issues.push(issue('missing-region', `${fieldPath}.regions`, 'must contain at least one ROI'));
      } else {
        const regionIds = new Set();
        entry.regions.forEach((region, regionIndex) => {
          const regionPath = `${fieldPath}.regions[${regionIndex}]`;
          validateRegion(region, regionPath, viewport, issues);
          if (isObject(region) && nonEmptyString(region.id)) {
            if (regionIds.has(region.id)) {
              issues.push(issue('duplicate-region', `${regionPath}.id`, `duplicates ${region.id}`));
            }
            regionIds.add(region.id);
          }
        });
      }

      const resolved = resolveReferencePath(entry.file, activeRoot, `${fieldPath}.file`, issues);
      if (resolved && checkFiles) {
        if (!fs.existsSync(resolved)) {
          issues.push(issue('missing-reference', `${fieldPath}.file`, `file does not exist: ${resolved}`));
        } else {
          try {
            const realRoot = fs.realpathSync(activeRoot);
            const realFile = fs.realpathSync(resolved);
            if (!isInside(realRoot, realFile) || containsArchiveSegment(realFile)) {
              issues.push(issue('path-escape', `${fieldPath}.file`, 'resolved file leaves the active root or enters the archive'));
            } else {
              const size = readPngSize(realFile);
              if (size.width !== REQUIRED_PHYSICAL.width || size.height !== REQUIRED_PHYSICAL.height) {
                issues.push(issue(
                  'wrong-dimensions',
                  `${fieldPath}.file`,
                  `expected ${REQUIRED_PHYSICAL.width}x${REQUIRED_PHYSICAL.height}, received ${size.width}x${size.height}`,
                ));
              }
            }
          } catch (error) {
            issues.push(issue('invalid-reference', `${fieldPath}.file`, error.message));
          }
        }
      }
    });

    if (mode === 'acceptance') {
      for (const screen of SCREENS) {
        for (const theme of THEMES) {
          const pair = `${screen}:${theme}`;
          if (!pairs.has(pair)) {
            issues.push(issue('missing-pair', 'screens', `missing ${pair}`));
          }
        }
      }
      // The approved baseline is exactly SCREENS × THEMES: capture-only
      // Service screens can never join it (they have no approved reference),
      // so any extra entry fails coverage here.
      if (manifest.screens.length !== SCREENS.length * THEMES.length) {
        issues.push(issue('wrong-coverage', 'screens', `expected exactly ${SCREENS.length * THEMES.length} entries, received ${manifest.screens.length}`));
      }
    }
  }

  if (issues.length > 0) {
    throw new ManifestValidationError(manifestPath, issues);
  }
  return manifest;
}

function loadReferenceManifest(manifestPath, options = {}) {
  const absolute = path.resolve(manifestPath);
  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(absolute, 'utf8'));
  } catch (error) {
    throw new ManifestValidationError(absolute, [
      issue('parse-error', '$', error.message),
    ]);
  }
  return validateReferenceManifest(manifest, {
    ...options,
    manifestPath: absolute,
    activeRoot: options.activeRoot ?? path.dirname(absolute),
  });
}

function main(argv) {
  const draft = argv.includes('--draft');
  const args = argv.filter((value) => value !== '--draft');
  if (args.length !== 1) {
    console.error('Usage: node reference-manifest.js [--draft] <manifest.json>');
    process.exitCode = 2;
    return;
  }
  try {
    loadReferenceManifest(args[0], { mode: draft ? 'draft' : 'acceptance' });
    console.log(`[reference-manifest] valid (${draft ? 'draft' : 'acceptance'}): ${path.resolve(args[0])}`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main(process.argv.slice(2));
}

module.exports = {
  APPROVALS,
  CAPTURE_SCREENS,
  ManifestValidationError,
  REQUIRED_PHYSICAL,
  REQUIRED_VIEWPORT,
  SCREENS,
  SERVICE_SCREENS,
  THEMES,
  loadReferenceManifest,
  readPngSize,
  validateReferenceManifest,
};
