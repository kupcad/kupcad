// A release of the core installed where the extension keeps its own: `<dir>/<version>/kupcad`.
// The archive for this platform is downloaded, checked against the release's checksums.txt
// before it is unpacked, and its binary written into a folder that takes the version's name only
// once it is whole, so a download cut short never looks installed.

import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import { errorText } from '../../errors.js';
import { extractFile } from './archive.js';
import { assetFor, CHECKSUMS, checksumOf, sha256 } from './assets.js';

/** @import { Release } from './releases.js' */

/** Executable by everyone, written by its owner. */
const EXECUTABLE = 0o755;

/** Why a release couldn't be installed, in words a person acts on. */
export class InstallError extends Error {
  /** @param {string} message */
  constructor(message) {
    super(message);
    this.name = 'InstallError';
  }
}

/**
 * @typedef {object} InstallOptions
 * @property {typeof fetch} get
 * @property {string} dir where installs go, a folder each
 * @property {string} platform Node's `process.platform`
 * @property {string} arch Node's `process.arch`
 * @property {(received: number, total: number | null) => void} [progress] the archive's bytes so far
 */

/**
 * Installs `release` for the platform.
 * @param {Release} release
 * @param {InstallOptions} options
 * @returns {Promise<string>} the binary's path
 * @throws {InstallError}
 */
export async function install(release, { get, dir, platform, arch, progress }) {
  const asset = assetFor(release.version, platform, arch);
  if (!asset) throw new InstallError(`kupcad isn't built for ${platform} on ${arch}`);
  const archiveUrl = release.assets[asset.archive];
  const checksumsUrl = release.assets[CHECKSUMS];
  if (!archiveUrl || !checksumsUrl) {
    throw new InstallError(`the release of kupcad ${release.version} has no ${asset.archive}`);
  }
  const expected = checksumOf(
    new TextDecoder().decode(await download(get, checksumsUrl)),
    asset.archive,
  );
  if (!expected)
    throw new InstallError(`${CHECKSUMS} of kupcad ${release.version} has no ${asset.archive}`);
  const archive = await download(get, archiveUrl, progress);
  if (sha256(archive) !== expected) {
    throw new InstallError(
      `${asset.archive} doesn't match its checksum: it was changed, or cut short`,
    );
  }
  const binary = extractFile(archive, asset.format, asset.binary);
  if (!binary) throw new InstallError(`${asset.archive} has no ${asset.binary}`);

  const target = path.join(dir, release.version);
  const partial = `${target}.partial`;
  await fs.rm(partial, { recursive: true, force: true });
  await fs.mkdir(partial, { recursive: true });
  await fs.writeFile(path.join(partial, asset.binary), binary, { mode: EXECUTABLE });
  await fs.rm(target, { recursive: true, force: true });
  await fs.rename(partial, target);
  return path.join(target, asset.binary);
}

/**
 * The bytes at `url`, read as they come.
 * @param {typeof fetch} get
 * @param {string} url
 * @param {(received: number, total: number | null) => void} [progress]
 * @returns {Promise<Uint8Array>}
 */
async function download(get, url, progress) {
  /** @type {Response} */
  let response;
  try {
    response = await get(url);
  } catch (error) {
    throw new InstallError(`couldn't download ${url}: ${errorText(error)}`);
  }
  if (!response.ok || !response.body) {
    throw new InstallError(`couldn't download ${url}: the server answered ${response.status}`);
  }
  const length = Number(response.headers.get('content-length'));
  const total = Number.isFinite(length) && length > 0 ? length : null;
  /** @type {Uint8Array[]} */
  const chunks = [];
  let received = 0;
  for await (const chunk of response.body) {
    chunks.push(chunk);
    received += chunk.byteLength;
    progress?.(received, total);
  }
  const bytes = new Uint8Array(received);
  let at = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, at);
    at += chunk.byteLength;
  }
  return bytes;
}

/**
 * The versions installed in `dir`: the folders holding a binary named `binary`.
 * @param {string} dir
 * @param {string} binary
 * @returns {Promise<string[]>}
 */
export async function installedVersions(dir, binary) {
  const entries = await fs.readdir(dir, { withFileTypes: true }).catch(() => []);
  const found = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.endsWith('.partial')) continue;
    const stat = await fs.stat(path.join(dir, entry.name, binary)).catch(() => null);
    if (stat?.isFile()) found.push(entry.name);
  }
  return found;
}
