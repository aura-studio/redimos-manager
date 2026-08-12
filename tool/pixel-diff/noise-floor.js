'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const {
  comparePair,
  loadCaptureRun,
  readPng,
} = require('./active-diff');
const { loadReferenceManifest } = require('./reference-manifest');

const NOISE_PURPOSE = 'noise-floor';
const THRESHOLD_POLICY = 'strictly-greater-than-measured-noise';

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function isInside(root, target) {
  const relative = path.relative(root, target);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

function hasArchiveSegment(target) {
  return path.resolve(target).split(path.sep).includes('v2.3-archive');
}

function resolveManifestPath(activeRoot, relative, expectedRoot, label) {
  if (!nonEmptyString(relative) || path.isAbsolute(relative) || hasArchiveSegment(relative)) {
    throw new Error(`${label} must be a relative active path outside v2.3-archive`);
  }
  const resolved = path.resolve(activeRoot, relative);
  const allowed = path.resolve(activeRoot, expectedRoot);
  if (!isInside(allowed, resolved)) {
    throw new Error(`${label} must stay under ${expectedRoot}: ${relative}`);
  }
  return resolved;
}

function validateNoisePlan(manifest, activeRoot) {
  if (!Array.isArray(manifest.captureRuns)) {
    throw new Error('Manifest captureRuns must explicitly list noise measurement runs');
  }
  const captureByNumber = new Map();
  for (const [index, capture] of manifest.captureRuns.entries()) {
    const label = `captureRuns[${index}]`;
    if (capture == null || typeof capture !== 'object' || Array.isArray(capture)) {
      throw new Error(`${label} must be an object`);
    }
    if (!Number.isInteger(capture.runNumber) || capture.runNumber < 1) {
      throw new Error(`${label}.runNumber must be a positive integer`);
    }
    if (captureByNumber.has(capture.runNumber)) {
      throw new Error(`${label}.runNumber duplicates run-${capture.runNumber}`);
    }
    if (capture.purpose !== NOISE_PURPOSE) {
      throw new Error(`${label}.purpose must be "${NOISE_PURPOSE}"`);
    }
    const directory = resolveManifestPath(activeRoot, capture.directory, 'captures', `${label}.directory`);
    if (path.basename(directory) !== `run-${capture.runNumber}`) {
      throw new Error(`${label}.directory must end with run-${capture.runNumber}`);
    }
    const metadata = resolveManifestPath(activeRoot, capture.metadata, 'captures', `${label}.metadata`);
    if (metadata !== path.join(directory, 'capture-metadata.json')) {
      throw new Error(`${label}.metadata must be capture-metadata.json inside its run directory`);
    }
    captureByNumber.set(capture.runNumber, { ...capture, directory, metadata });
  }

  const measurement = manifest.noiseMeasurement;
  if (measurement == null || typeof measurement !== 'object' || Array.isArray(measurement)) {
    throw new Error('Manifest noiseMeasurement plan is required');
  }
  if (!['planned', 'measured'].includes(measurement.status)) {
    throw new Error('noiseMeasurement.status must be planned or measured');
  }
  if (!Array.isArray(measurement.runNumbers) || measurement.runNumbers.length < 3) {
    throw new Error('noiseMeasurement.runNumbers must explicitly list at least three runs');
  }
  const uniqueRuns = new Set(measurement.runNumbers);
  if (uniqueRuns.size !== measurement.runNumbers.length ||
      measurement.runNumbers.some((value) => !Number.isInteger(value) || value < 1)) {
    throw new Error('noiseMeasurement.runNumbers must contain unique positive integers');
  }
  const captures = measurement.runNumbers.map((runNumber) => {
    const capture = captureByNumber.get(runNumber);
    if (!capture) throw new Error(`noiseMeasurement references undeclared run-${runNumber}`);
    return capture;
  });
  if (measurement.thresholdPolicy !== THRESHOLD_POLICY) {
    throw new Error(`noiseMeasurement.thresholdPolicy must be "${THRESHOLD_POLICY}"`);
  }
  if (measurement.thresholdApproval !== 'pending') {
    throw new Error('noiseMeasurement.thresholdApproval must remain "pending" until independent approval');
  }
  if (measurement.legacyV23ThresholdImported !== false) {
    throw new Error('noiseMeasurement must explicitly set legacyV23ThresholdImported to false');
  }
  if (!nonEmptyString(measurement.rationale)) {
    throw new Error('noiseMeasurement.rationale must explain the new Codex/noise basis');
  }
  const report = resolveManifestPath(activeRoot, measurement.report, 'reports', 'noiseMeasurement.report');
  if (path.extname(report).toLowerCase() !== '.json') {
    throw new Error('noiseMeasurement.report must be a JSON file');
  }
  return { measurement, captures, report };
}

function sameBuildKey(metadata) {
  return JSON.stringify({
    schemaVersion: metadata.schemaVersion,
    referenceVersion: metadata.referenceVersion,
    viewport: metadata.viewport,
    physicalSize: metadata.physicalSize,
    renderingEnvironment: metadata.renderingEnvironment,
    fixtureRevision: metadata.fixtureRevision,
    buildRevision: metadata.buildRevision,
    fontRevision: metadata.fontRevision,
    fonts: metadata.fonts,
  });
}

function loadNoiseRuns(manifest, activeRoot, plan) {
  const runs = plan.captures.map((capture) => {
    const loaded = loadCaptureRun(capture.directory, manifest, {
      activeRoot,
      requireProvenance: true,
      requireManifestEnvironment: false,
    });
    if (loaded.metadataPath !== capture.metadata) {
      throw new Error(`run-${capture.runNumber} metadata path does not match manifest declaration`);
    }
    return {
      runNumber: capture.runNumber,
      ...loaded,
    };
  });
  const firstKey = sameBuildKey(runs[0].metadata);
  for (const run of runs.slice(1)) {
    if (sameBuildKey(run.metadata) !== firstKey) {
      throw new Error(
        `run-${run.runNumber} does not match run-${runs[0].runNumber} ` +
        'for build, fixture, font, Flutter, platform, viewport, or physical size',
      );
    }
  }
  return runs;
}

function candidate(value, runs, source = {}) {
  return {
    measuredNoiseFloor: value,
    minimumExclusive: value,
    sourceRuns: [...runs],
    ...source,
  };
}

function updateMaximum(target, key, value, runPair) {
  if (!(key in target) || value > target[key].measuredNoiseFloor) {
    target[key] = candidate(value, runPair);
  }
}

function calculatePairwiseNoise(manifest, runs, options = {}) {
  const results = [];
  for (const entry of manifest.screens) {
    const pairKey = `${entry.id}:${entry.theme}`;
    const images = runs.map((run) => readPng(run.captures.get(pairKey)));
    const floor = {
      screen: entry.id,
      theme: entry.theme,
      fullFrameDiffRatio: null,
      roiDiffRatios: {},
      maxGeometryDeviationPx: null,
      channelMAE: {},
      geometryUnmeasurable: [],
    };
    for (let left = 0; left < runs.length - 1; left++) {
      for (let right = left + 1; right < runs.length; right++) {
        const runPair = [runs[left].runNumber, runs[right].runNumber];
        const metrics = comparePair(images[left], images[right], entry, manifest.viewport.dpr, {
          expectedPhysical: options.expectedPhysical,
        });
        if (floor.fullFrameDiffRatio === null ||
            metrics.fullFrameDiffRatio > floor.fullFrameDiffRatio.measuredNoiseFloor) {
          floor.fullFrameDiffRatio = candidate(metrics.fullFrameDiffRatio, runPair);
        }
        for (const [roiId, roi] of Object.entries(metrics.roiDiffRatios)) {
          updateMaximum(floor.roiDiffRatios, roiId, roi.diffRatio, runPair);
        }
        if (floor.maxGeometryDeviationPx === null ||
            metrics.geometry.maxGeometryDeviationPx > floor.maxGeometryDeviationPx.measuredNoiseFloor) {
          floor.maxGeometryDeviationPx = candidate(metrics.geometry.maxGeometryDeviationPx, runPair);
        }
        for (const [anchorId, anchor] of Object.entries(metrics.geometry.anchors)) {
          for (const edge of anchor.unmeasurableEdges) {
            const value = `${anchorId}.${edge}`;
            if (!floor.geometryUnmeasurable.includes(value)) floor.geometryUnmeasurable.push(value);
          }
        }
        for (const [roiId, channels] of Object.entries(metrics.channelMAE)) {
          floor.channelMAE[roiId] ??= {};
          for (const [channel, value] of Object.entries(channels)) {
            updateMaximum(floor.channelMAE[roiId], channel, value, runPair);
          }
        }
      }
    }
    floor.geometryUnmeasurable.sort();
    results.push(floor);
  }
  return results;
}

function summarizeThresholdConstraints(pairs) {
  const constraints = {
    fullFrameDiffRatio: null,
    roiDiffRatios: {},
    maxGeometryDeviationPx: null,
    channelMAE: {},
  };
  for (const pair of pairs) {
    const source = { screen: pair.screen, theme: pair.theme };
    const full = pair.fullFrameDiffRatio;
    if (constraints.fullFrameDiffRatio === null ||
        full.measuredNoiseFloor > constraints.fullFrameDiffRatio.measuredNoiseFloor) {
      constraints.fullFrameDiffRatio = { ...full, ...source };
    }
    for (const [roiId, value] of Object.entries(pair.roiDiffRatios)) {
      if (!(roiId in constraints.roiDiffRatios) ||
          value.measuredNoiseFloor > constraints.roiDiffRatios[roiId].measuredNoiseFloor) {
        constraints.roiDiffRatios[roiId] = { ...value, ...source, roi: roiId };
      }
    }
    const geometry = pair.maxGeometryDeviationPx;
    if (constraints.maxGeometryDeviationPx === null ||
        geometry.measuredNoiseFloor > constraints.maxGeometryDeviationPx.measuredNoiseFloor) {
      constraints.maxGeometryDeviationPx = { ...geometry, ...source };
    }
    for (const channels of Object.values(pair.channelMAE)) {
      for (const [channel, value] of Object.entries(channels)) {
        if (!(channel in constraints.channelMAE) ||
            value.measuredNoiseFloor > constraints.channelMAE[channel].measuredNoiseFloor) {
          constraints.channelMAE[channel] = { ...value, ...source, channel };
        }
      }
    }
  }
  return constraints;
}

function validateThresholdProposal(proposal, noiseReport, noiseReportSha256) {
  if (proposal == null || typeof proposal !== 'object' || Array.isArray(proposal)) {
    throw new Error('Threshold proposal must be an object');
  }
  if (proposal.schemaVersion !== 1 || proposal.referenceVersion !== noiseReport.referenceVersion) {
    throw new Error('Threshold proposal schema/referenceVersion must match the noise report');
  }
  if (proposal.noiseReportSha256 !== noiseReportSha256) {
    throw new Error('Threshold proposal must bind the exact noise report SHA-256');
  }
  if (proposal.legacyV23ThresholdImported !== false ||
      proposal.derivation !== 'codex-reference-and-measured-noise') {
    throw new Error('Threshold proposal must explicitly reject importing the legacy v2.3 threshold');
  }
  if (!nonEmptyString(proposal.rationale) ||
      typeof proposal.margin !== 'number' || !Number.isFinite(proposal.margin) || proposal.margin <= 0) {
    throw new Error('Threshold proposal must record a positive margin and non-empty rationale');
  }
  const metrics = proposal.metrics;
  const constraints = noiseReport.thresholdConstraints;
  if (metrics == null || typeof metrics !== 'object' || Array.isArray(metrics)) {
    throw new Error('Threshold proposal metrics must be an object');
  }
  const above = (value, constraint, label) => {
    if (typeof value !== 'number' || !Number.isFinite(value) ||
        value <= constraint.measuredNoiseFloor) {
      throw new Error(`${label} must be strictly greater than measured noise ${constraint.measuredNoiseFloor}`);
    }
  };
  above(metrics.fullFrameDiffRatio, constraints.fullFrameDiffRatio, 'fullFrameDiffRatio');
  above(metrics.maxGeometryDeviationPx, constraints.maxGeometryDeviationPx, 'maxGeometryDeviationPx');
  for (const [roiId, constraint] of Object.entries(constraints.roiDiffRatios)) {
    above(metrics.roiDiffRatios?.[roiId], constraint, `roiDiffRatios.${roiId}`);
  }
  for (const [channel, constraint] of Object.entries(constraints.channelMAE)) {
    above(metrics.channelMAE?.[channel], constraint, `channelMAE.${channel}`);
  }
  return proposal;
}

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function measureNoiseFloor(options = {}) {
  if (!nonEmptyString(options.manifestPath)) {
    throw new Error('A manifest path is required (--manifest)');
  }
  const manifestPath = path.resolve(options.manifestPath);
  const activeRoot = path.dirname(manifestPath);
  const manifest = loadReferenceManifest(manifestPath, {
    mode: 'draft',
    checkFiles: false,
  });
  const plan = validateNoisePlan(manifest, activeRoot);
  const runs = loadNoiseRuns(manifest, activeRoot, plan);
  const pairs = calculatePairwiseNoise(manifest, runs);
  const thresholdConstraints = summarizeThresholdConstraints(pairs);
  const report = {
    schemaVersion: 1,
    referenceVersion: manifest.referenceVersion,
    measurement: 'maximum-pairwise-deviation',
    runNumbers: runs.map((run) => run.runNumber),
    pairCount: runs.length * (runs.length - 1) / 2,
    viewport: runs[0].metadata.viewport,
    physicalSize: runs[0].metadata.physicalSize,
    renderingEnvironment: runs[0].metadata.renderingEnvironment,
    fixtureRevision: runs[0].metadata.fixtureRevision,
    buildRevision: runs[0].metadata.buildRevision,
    fontRevision: runs[0].metadata.fontRevision,
    fonts: runs[0].metadata.fonts,
    thresholdPolicy: THRESHOLD_POLICY,
    thresholdApproval: 'pending',
    legacyV23ThresholdImported: false,
    rationale: plan.measurement.rationale,
    thresholdConstraints,
    pairs,
  };

  if (fs.existsSync(plan.report)) {
    throw new Error(`Refusing to overwrite existing noise report: ${plan.report}`);
  }
  fs.mkdirSync(path.dirname(plan.report), { recursive: true });
  fs.writeFileSync(plan.report, `${JSON.stringify(report, null, 2)}\n`, { flag: 'wx' });
  return {
    manifestPath,
    reportPath: plan.report,
    reportSha256: sha256File(plan.report),
    report,
  };
}

function main(argv) {
  if (argv.length !== 2 || argv[0] !== '--manifest') {
    console.error('Usage: node noise-floor.js --manifest <manifest.json>');
    process.exitCode = 2;
    return;
  }
  try {
    const result = measureNoiseFloor({ manifestPath: argv[1] });
    console.log(JSON.stringify(result, null, 2));
  } catch (error) {
    console.error(`[noise-floor] ${error.message}`);
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main(process.argv.slice(2));
}

module.exports = {
  NOISE_PURPOSE,
  THRESHOLD_POLICY,
  calculatePairwiseNoise,
  loadNoiseRuns,
  measureNoiseFloor,
  sameBuildKey,
  summarizeThresholdConstraints,
  validateNoisePlan,
  validateThresholdProposal,
};
