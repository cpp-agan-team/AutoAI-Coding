#!/usr/bin/env node

import { createHash } from 'node:crypto';
import {
  lstatSync,
  readFileSync,
  readdirSync,
  statSync,
} from 'node:fs';
import { basename, join, resolve } from 'node:path';
import { gunzipSync } from 'node:zlib';

const DIGEST = /^sha256:[0-9a-f]{64}$/;
const VERSION = /^[0-9]+\.[0-9]+\.[0-9]+$/;
const REVISION = /^[0-9a-f]{40,64}$/;
const SAFE_PATH = /^[A-Za-z0-9._/-]+$/;
const RELEASE_PATHS = Object.freeze([
  'setup_ai_harness.sh',
  'VERSION',
  'README.md',
  'PROJECT_ATTRIBUTION.md',
]);

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function closedObject(value, keys, label) {
  if (!isObject(value)) throw new Error(`${label} must be an object`);
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length ||
      actual.some((key, index) => key !== expected[index])) {
    throw new Error(`${label} must contain exactly: ${expected.join(', ')}`);
  }
}

function sha256(file) {
  return `sha256:${createHash('sha256').update(readFileSync(file)).digest('hex')}`;
}

function parseCanonicalJson(file, label) {
  const raw = readFileSync(file);
  let value;
  try {
    value = JSON.parse(raw);
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
  const canonical = Buffer.from(`${JSON.stringify(value, null, 2)}\n`);
  if (!raw.equals(canonical)) {
    throw new Error(`${label} is not canonical JSON`);
  }
  return value;
}

function safeRelativePath(value, root, label) {
  if (typeof value !== 'string' || !SAFE_PATH.test(value) || value.startsWith('/') ||
      value.endsWith('/') || value.includes('//') || value.split('/').some((part) =>
        part === '' || part === '.' || part === '..') ||
      !value.startsWith(`${root}/`)) {
    throw new Error(`${label} is unsafe or outside the release root`);
  }
}

function parseArgs(argv) {
  let directory = null;
  let version = null;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--dir') {
      if (!argv[index + 1]) throw new Error('--dir requires a directory');
      directory = resolve(argv[++index]);
    } else if (argument === '--version') {
      if (!argv[index + 1]) throw new Error('--version requires a value');
      version = argv[++index];
    } else if (argument === '-h' || argument === '--help') {
      process.stdout.write(
        'Usage: node tools/release/verify-integrity.mjs --dir <directory> [--version <x.y.z>]\n',
      );
      process.exit(0);
    } else {
      throw new Error(`unknown argument: ${argument}`);
    }
  }
  if (!directory) throw new Error('--dir is required');
  if (version !== null && !VERSION.test(version)) throw new Error('--version is invalid');
  return { directory, version };
}

function loadSingleStatement(directory, requestedVersion) {
  const directoryStat = lstatSync(directory);
  if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) {
    throw new Error('artifact directory must be a non-symlink directory');
  }
  const candidates = readdirSync(directory)
    .filter((name) => /^autoai-coding-\d+\.\d+\.\d+\.integrity\.json$/.test(name))
    .sort();
  if (requestedVersion !== null) {
    const expected = `autoai-coding-${requestedVersion}.integrity.json`;
    if (!candidates.includes(expected)) throw new Error(`missing integrity statement: ${expected}`);
    return join(directory, expected);
  }
  if (candidates.length !== 1) {
    throw new Error('artifact directory must contain exactly one integrity statement');
  }
  return join(directory, candidates[0]);
}

function validateStatement(statement, requestedVersion) {
  closedObject(statement, [
    'schema_version',
    'authenticity',
    'package',
    'version',
    'generated_at',
    'source',
    'artifact',
    'content_manifest',
  ], 'integrity statement');
  if (statement.schema_version !== 1) throw new Error('unsupported integrity schema_version');
  if (statement.authenticity !== 'integrity-only') {
    throw new Error('statement must not claim unverified authenticity');
  }
  if (statement.package !== 'autoai-coding') throw new Error('unexpected package name');
  if (!VERSION.test(statement.version) ||
      (requestedVersion !== null && statement.version !== requestedVersion)) {
    throw new Error('statement version mismatch');
  }
  if (typeof statement.generated_at !== 'string' ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(statement.generated_at) ||
      !Number.isFinite(Date.parse(statement.generated_at)) ||
      new Date(statement.generated_at).toISOString().replace('.000Z', 'Z') !==
        statement.generated_at) {
    throw new Error('statement generated_at is invalid');
  }
  closedObject(statement.source, ['revision', 'dirty'], 'statement.source');
  if (!REVISION.test(statement.source.revision) || typeof statement.source.dirty !== 'boolean') {
    throw new Error('statement source identity is invalid');
  }
  closedObject(statement.artifact, ['name', 'size', 'sha256'], 'statement.artifact');
  closedObject(statement.content_manifest, ['name', 'sha256'], 'statement.content_manifest');
  const base = `autoai-coding-${statement.version}`;
  if (statement.artifact.name !== `${base}.tar.gz` ||
      statement.content_manifest.name !== `${base}.content-manifest.json`) {
    throw new Error('statement sidecar names do not match version');
  }
  if (!Number.isInteger(statement.artifact.size) || statement.artifact.size <= 0 ||
      !DIGEST.test(statement.artifact.sha256) ||
      !DIGEST.test(statement.content_manifest.sha256)) {
    throw new Error('statement digest or size is invalid');
  }
}

function validateManifest(manifest, version) {
  closedObject(manifest, ['schema_version', 'package', 'version', 'root', 'files'],
    'content manifest');
  const root = `autoai-coding-${version}`;
  if (manifest.schema_version !== 1 || manifest.package !== 'autoai-coding' ||
      manifest.version !== version || manifest.root !== root ||
      !Array.isArray(manifest.files) || manifest.files.length === 0) {
    throw new Error('content manifest identity is invalid');
  }
  const requiredFiles = new Map(RELEASE_PATHS.map((relative) => [
    `${root}/${relative}`,
    relative === 'setup_ai_harness.sh' ? '0755' : '0644',
  ]));
  if (manifest.files.length !== requiredFiles.size) {
    throw new Error('content manifest does not match the release allowlist');
  }
  const seen = new Set();
  let previous = null;
  for (const [index, entry] of manifest.files.entries()) {
    closedObject(entry, ['path', 'type', 'mode', 'size', 'sha256'],
      `content manifest files[${index}]`);
    safeRelativePath(entry.path, root, `content manifest files[${index}].path`);
    if (seen.has(entry.path)) throw new Error(`duplicate manifest path: ${entry.path}`);
    seen.add(entry.path);
    if (previous !== null && Buffer.compare(Buffer.from(previous), Buffer.from(entry.path)) >= 0) {
      throw new Error('content manifest paths are not in canonical byte order');
    }
    previous = entry.path;
    if (entry.type !== 'file' || !/^[0-7]{4}$/.test(entry.mode) ||
        !Number.isInteger(entry.size) || entry.size < 0 || !DIGEST.test(entry.sha256)) {
      throw new Error(`invalid content entry: ${entry.path}`);
    }
    if (!requiredFiles.has(entry.path) || requiredFiles.get(entry.path) !== entry.mode) {
      throw new Error(`release allowlist or mode mismatch: ${entry.path}`);
    }
  }
  return { root, expectedFiles: seen };
}

function expectedDirectories(root, files) {
  const directories = new Set([root, `${root}/`]);
  for (const file of files) {
    const parts = file.split('/');
    parts.pop();
    while (parts.length > 0) {
      const directory = parts.join('/');
      directories.add(directory);
      directories.add(`${directory}/`);
      parts.pop();
    }
  }
  return directories;
}

function tarString(header, start, length, label) {
  const field = header.subarray(start, start + length);
  const end = field.indexOf(0);
  if (end !== -1 && field.subarray(end).some((byte) => byte !== 0)) {
    throw new Error(`${label} has bytes after its terminator`);
  }
  const bytes = end === -1 ? field : field.subarray(0, end);
  if ([...bytes].some((byte) => byte < 0x20 || byte > 0x7e)) {
    throw new Error(`${label} contains non-portable bytes`);
  }
  return bytes.toString('ascii');
}

function tarOctal(header, start, length, label) {
  const field = header.subarray(start, start + length);
  if ((field[0] & 0x80) !== 0) throw new Error(`${label} uses unsupported base-256 encoding`);
  if ([...field].some((byte) =>
    byte !== 0 && byte !== 0x20 && (byte < 0x30 || byte > 0x37))) {
    throw new Error(`${label} contains non-octal bytes`);
  }
  const terminator = field.indexOf(0);
  if (terminator !== -1 &&
      field.subarray(terminator).some((byte) => byte !== 0 && byte !== 0x20)) {
    throw new Error(`${label} has bytes after its terminator`);
  }
  const value = (terminator === -1 ? field : field.subarray(0, terminator))
    .toString('ascii').trim();
  if (!/^[0-7]+$/.test(value)) throw new Error(`${label} is not canonical octal`);
  const parsed = Number.parseInt(value, 8);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error(`${label} is out of range`);
  return parsed;
}

function tarChecksum(header) {
  let sum = 0;
  for (let index = 0; index < header.length; index += 1) {
    sum += index >= 148 && index < 156 ? 0x20 : header[index];
  }
  return sum;
}

function parseArchive(archive, root, expectedFiles, expectedMtime) {
  let bytes;
  try {
    bytes = gunzipSync(readFileSync(archive));
  } catch (error) {
    throw new Error(`artifact is not valid gzip data: ${error.message}`);
  }
  if (bytes.length === 0 || bytes.length % 512 !== 0) {
    throw new Error('tar payload length is not block aligned');
  }
  const seen = new Set();
  const allowedDirectories = expectedDirectories(root, expectedFiles);
  const files = new Map();
  let offset = 0;
  let zeroBlocks = 0;
  while (offset < bytes.length) {
    const header = bytes.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) {
      zeroBlocks += 1;
      offset += 512;
      continue;
    }
    if (zeroBlocks > 0) throw new Error('non-zero tar entry follows an end marker');
    const storedChecksum = tarOctal(header, 148, 8, 'tar checksum');
    if (storedChecksum !== tarChecksum(header)) throw new Error('tar header checksum mismatch');
    const magic = header.subarray(257, 263);
    if (!magic.equals(Buffer.from('ustar\0', 'ascii'))) {
      throw new Error('artifact must use the ustar format');
    }
    const namePart = tarString(header, 0, 100, 'tar name');
    const prefix = tarString(header, 345, 155, 'tar prefix');
    const name = prefix ? `${prefix}/${namePart}` : namePart;
    const mode = tarOctal(header, 100, 8, `tar mode for ${name}`);
    const uid = tarOctal(header, 108, 8, `tar uid for ${name}`);
    const gid = tarOctal(header, 116, 8, `tar gid for ${name}`);
    const size = tarOctal(header, 124, 12, `tar size for ${name}`);
    const mtime = tarOctal(header, 136, 12, `tar mtime for ${name}`);
    const typeByte = header[156];
    const linkName = tarString(header, 157, 100, `tar link name for ${name}`);
    if (!SAFE_PATH.test(name) || name.startsWith('/') || name.includes('//') ||
        name.split('/').some((part) => part === '..' || part === '.')) {
      throw new Error(`unsafe archive path: ${name}`);
    }
    if (seen.has(name)) throw new Error(`duplicate archive path: ${name}`);
    seen.add(name);
    if (uid !== 0 || gid !== 0 || mtime !== expectedMtime) {
      throw new Error(`archive owner or timestamp drift detected: ${name}`);
    }
    const dataStart = offset + 512;
    const dataEnd = dataStart + size;
    if (dataEnd > bytes.length) throw new Error(`truncated archive entry: ${name}`);
    if (typeByte === 0 || typeByte === 0x30) {
      if (linkName !== '') throw new Error(`regular file has a link target: ${name}`);
      if (!expectedFiles.has(name)) throw new Error(`unexpected archive file: ${name}`);
      files.set(name, {
        mode: mode.toString(8).padStart(4, '0'),
        size,
        bytes: bytes.subarray(dataStart, dataEnd),
      });
    } else if (typeByte === 0x35) {
      if (size !== 0 || linkName !== '') throw new Error(`invalid directory entry: ${name}`);
      if (!allowedDirectories.has(name)) throw new Error(`unexpected archive directory: ${name}`);
      if (mode !== 0o755) throw new Error(`archive directory mode drift detected: ${name}`);
    } else {
      throw new Error(`unsupported archive entry type: ${name}`);
    }
    const nextOffset = dataStart + Math.ceil(size / 512) * 512;
    if (bytes.subarray(dataEnd, nextOffset).some((byte) => byte !== 0)) {
      throw new Error(`archive entry has non-zero padding: ${name}`);
    }
    offset = nextOffset;
  }
  if (zeroBlocks < 2) throw new Error('tar payload is missing its end markers');
  for (const file of expectedFiles) {
    if (!seen.has(file)) throw new Error(`archive is missing manifest file: ${file}`);
  }
  return files;
}

function sha256Bytes(bytes) {
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
}

function verifyArchiveContents(archive, manifest, root, expectedFiles, generatedAt) {
  const expectedMtime = Date.parse(generatedAt) / 1000;
  const files = parseArchive(archive, root, expectedFiles, expectedMtime);
  if (files.size !== expectedFiles.size) {
    throw new Error('archive file set differs from the content manifest');
  }
  for (const entry of manifest.files) {
    const actual = files.get(entry.path);
    if (!actual || actual.size !== entry.size || actual.mode !== entry.mode ||
        sha256Bytes(actual.bytes) !== entry.sha256) {
      throw new Error(`content drift detected: ${entry.path}`);
    }
  }
  const versionEntry = files.get(`${root}/VERSION`);
  if (!versionEntry || versionEntry.bytes.toString('utf8') !== `${manifest.version}\n`) {
    throw new Error('packaged VERSION content mismatch');
  }
  const setupEntry = files.get(`${root}/setup_ai_harness.sh`);
  if (!setupEntry) throw new Error('packaged setup script is missing');
  const escapedVersion = manifest.version.replace(/\./g, '\\.');
  const versionPattern = new RegExp(
    `^AUTOAI_HARNESS_VERSION=[\"']${escapedVersion}[\"']$`,
    'm',
  );
  if (!versionPattern.test(setupEntry.bytes.toString('utf8'))) {
    throw new Error('packaged setup version constant does not match VERSION');
  }
}

function verify(directory, requestedVersion) {
  const statementFile = loadSingleStatement(directory, requestedVersion);
  const statementStat = lstatSync(statementFile);
  if (!statementStat.isFile() || statementStat.isSymbolicLink()) {
    throw new Error('integrity statement is not a regular file');
  }
  const statement = parseCanonicalJson(statementFile, 'integrity statement');
  validateStatement(statement, requestedVersion);

  const archive = join(directory, statement.artifact.name);
  const manifestFile = join(directory, statement.content_manifest.name);
  for (const [file, label] of [[archive, 'artifact'], [manifestFile, 'content manifest']]) {
    const stat = lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`${label} is not a regular file`);
  }
  if (statSync(archive).size !== statement.artifact.size ||
      sha256(archive) !== statement.artifact.sha256) {
    throw new Error('artifact size or digest mismatch');
  }
  if (sha256(manifestFile) !== statement.content_manifest.sha256) {
    throw new Error('content manifest digest mismatch');
  }

  const checksumFile = `${archive}.sha256`;
  const checksumStat = lstatSync(checksumFile);
  if (!checksumStat.isFile() || checksumStat.isSymbolicLink() ||
      readFileSync(checksumFile, 'utf8') !== `${statement.artifact.sha256}\n`) {
    throw new Error('artifact checksum sidecar mismatch');
  }

  const manifest = parseCanonicalJson(manifestFile, 'content manifest');
  const { root, expectedFiles } = validateManifest(manifest, statement.version);
  verifyArchiveContents(archive, manifest, root, expectedFiles, statement.generated_at);

  return {
    schema_version: 1,
    status: 'valid',
    authenticity: statement.authenticity,
    package: statement.package,
    version: statement.version,
    artifact: basename(archive),
    artifact_sha256: statement.artifact.sha256,
    source_revision: statement.source.revision,
    source_dirty: statement.source.dirty,
    files_verified: manifest.files.length,
  };
}

function main() {
  try {
    const options = parseArgs(process.argv.slice(2));
    process.stdout.write(`${JSON.stringify(verify(options.directory, options.version), null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`${JSON.stringify({
      schema_version: 1,
      status: 'invalid',
      reason: error.message,
    }, null, 2)}\n`);
    process.exitCode = 1;
  }
}

main();
