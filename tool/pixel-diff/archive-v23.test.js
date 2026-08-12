'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const ARCHIVE_SCRIPT = path.join(__dirname, 'archive-v23.sh');

function temporaryRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'redimos-archive-v23-'));
  t.after(() => {
    spawnSync('chmod', ['-R', 'u+w', root]);
    fs.rmSync(root, { recursive: true, force: true });
  });
  return root;
}

function writeFiles(directory, count, extension, prefix) {
  fs.mkdirSync(directory, { recursive: true });
  for (let index = 1; index <= count; index++) {
    fs.writeFileSync(
      path.join(directory, `${prefix}-${String(index).padStart(2, '0')}.${extension}`),
      `${prefix}:${index}\n`,
    );
  }
}

function run(root, command, args = []) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: 'utf8',
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: 'Archive Test',
      GIT_AUTHOR_EMAIL: 'archive-test@example.invalid',
      GIT_COMMITTER_NAME: 'Archive Test',
      GIT_COMMITTER_EMAIL: 'archive-test@example.invalid',
    },
  });
  if (result.status !== 0) {
    throw new Error(`${command} ${args.join(' ')} failed (${result.status}):\n${result.stdout}${result.stderr}`);
  }
  return result;
}

function fixtureRepo(t, overrides = {}) {
  const root = path.join(temporaryRoot(t), 'repo');
  const toolRoot = path.join(root, 'tool', 'pixel-diff');
  fs.mkdirSync(toolRoot, { recursive: true });
  fs.copyFileSync(ARCHIVE_SCRIPT, path.join(toolRoot, 'archive-v23.sh'));
  fs.writeFileSync(path.join(toolRoot, 'README.md'), '# archive fixture\n');
  fs.writeFileSync(path.join(toolRoot, 'config.js'), "'use strict';\n");
  writeFiles(path.join(root, 'test', 'goldens'), overrides.goldens ?? 16, 'png', 'golden');
  writeFiles(path.join(toolRoot, 'out', 'flutter'), overrides.flutter ?? 8, 'png', 'flutter');
  writeFiles(path.join(toolRoot, 'out', 'mockup'), overrides.mockup ?? 8, 'png', 'mockup');
  writeFiles(path.join(toolRoot, 'out', 'diff'), overrides.diff ?? 40, 'png', 'diff');
  writeFiles(path.join(toolRoot, 'out'), overrides.reports ?? 4, 'md', 'report');
  fs.writeFileSync(path.join(root, '.archive-test-marker'), 'fixture\n');
  run(root, 'git', ['init', '-q']);
  run(root, 'git', ['add', '.archive-test-marker']);
  run(root, 'git', ['commit', '-q', '-m', 'archive fixture']);
  return {
    root,
    script: path.join(toolRoot, 'archive-v23.sh'),
    archiveRoot: path.join(toolRoot, 'v2.3-archive'),
  };
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

test('archive script copies and independently verifies the complete immutable v2.3 evidence set', (t) => {
  const fixture = fixtureRepo(t);
  const first = run(fixture.root, 'bash', [fixture.script]);
  assert.match(first.stdout, /archived and verified 79 files/);

  const sumsPath = path.join(fixture.archiveRoot, 'SHA256SUMS');
  const entries = fs.readFileSync(sumsPath, 'utf8').trim().split('\n').map((line) => {
    const match = /^([0-9a-f]{64})  (.+)$/.exec(line);
    assert.ok(match, `invalid SHA256SUMS entry: ${line}`);
    return { expected: match[1], relative: match[2] };
  });
  assert.equal(entries.length, 79);
  assert.equal(new Set(entries.map((entry) => entry.relative)).size, 79);
  for (const entry of entries) {
    const file = path.join(fixture.archiveRoot, entry.relative);
    assert.equal(sha256(file), entry.expected, `checksum mismatch: ${entry.relative}`);
    assert.equal(fs.statSync(file).mode & 0o222, 0, `archived file remains writable: ${entry.relative}`);
  }
  assert.equal(fs.statSync(fixture.archiveRoot).mode & 0o222, 0);
  assert.equal(fs.readdirSync(path.join(fixture.archiveRoot, 'goldens')).length, 16);
  assert.equal(fs.readdirSync(path.join(fixture.archiveRoot, 'captures', 'flutter')).length, 8);
  assert.equal(fs.readdirSync(path.join(fixture.archiveRoot, 'captures', 'mockup')).length, 8);
  assert.equal(fs.readdirSync(path.join(fixture.archiveRoot, 'diagnostics', 'diff')).length, 40);
  assert.equal(fs.readdirSync(path.join(fixture.archiveRoot, 'reports')).length, 4);
  assert.match(
    fs.readFileSync(path.join(fixture.archiveRoot, 'ARCHIVE-METADATA.txt'), 'utf8'),
    /policy: historical evidence only; excluded from active reference discovery and comparison/,
  );

  const repeated = spawnSync('bash', [fixture.script], {
    cwd: fixture.root,
    encoding: 'utf8',
  });
  assert.notEqual(repeated.status, 0);
  assert.match(repeated.stderr, /refusing to overwrite existing archive/);
  assert.equal(fs.readFileSync(sumsPath, 'utf8').trim().split('\n').length, 79);
});

test('archive script rejects incomplete inputs before creating an archive', (t) => {
  const fixture = fixtureRepo(t, { diff: 39 });
  const result = spawnSync('bash', [fixture.script], {
    cwd: fixture.root,
    encoding: 'utf8',
  });

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /diff diagnostics: expected 40 files, found 39/);
  assert.equal(fs.existsSync(fixture.archiveRoot), false);
});
