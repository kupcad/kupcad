// What a release holds for a platform: `kupcad_<version>_<os>_<arch>`, a .zip on Windows and a
// .tar.gz elsewhere, with the binary at its top (core/scripts/package-release.sh), and
// checksums.txt, the SHA-256 of each archive.

import { createHash } from 'node:crypto';

/** The release's file of every archive's SHA-256. */
export const CHECKSUMS = 'checksums.txt';

/** Node's names for the platforms the core is built for, as its archives name them. */
const OS = /** @type {Record<string, string>} */ ({
  linux: 'linux',
  darwin: 'darwin',
  win32: 'windows',
});
const ARCH = /** @type {Record<string, string>} */ ({ x64: 'amd64', arm64: 'arm64' });

/**
 * @typedef {object} Asset
 * @property {string} archive the archive's name
 * @property {'tar.gz' | 'zip'} format
 * @property {string} binary the binary's name in it
 */

/**
 * The archive of `version` for a platform (Node's `process.platform` and `process.arch`), or null
 * for one the core isn't built for.
 * @param {string} version
 * @param {string} platform
 * @param {string} arch
 * @returns {Asset | null}
 */
export function assetFor(version, platform, arch) {
  const os = OS[platform];
  const cpu = ARCH[arch];
  if (!os || !cpu) return null;
  const windows = os === 'windows';
  const format = windows ? 'zip' : 'tar.gz';
  return {
    archive: `kupcad_${version}_${os}_${cpu}.${format}`,
    format,
    binary: windows ? 'kupcad.exe' : 'kupcad',
  };
}

/**
 * The SHA-256 a checksums.txt gives `name` (`<hex>  <name>` a line, as sha256sum writes it), or
 * null when it gives none.
 * @param {string} checksums
 * @param {string} name
 * @returns {string | null}
 */
export function checksumOf(checksums, name) {
  for (const line of checksums.split('\n')) {
    const [hash, file] = line.trim().split(/\s+\*?/);
    if (file === name && /^[0-9a-f]{64}$/i.test(hash)) return hash.toLowerCase();
  }
  return null;
}

/** @param {Uint8Array} bytes */
export const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');
