// The systems a native kupcad is published for, each an npm package of its own
// (`@kupcad/cli-darwin-arm64`, …) that npm installs only on its system (its `os`, `cpu` and, on
// Linux, `libc`), and which of them the system running is.

/**
 * A system kupcad is built for: npm's names of it, and the release archive's.
 * @typedef {object} Platform
 * @property {NodeJS.Platform} os npm's `os` (Node's `process.platform`)
 * @property {string} cpu npm's `cpu` (Node's `process.arch`)
 * @property {string} archive the release archive's system, `kupcad_<version>_<archive>.tar.gz`
 */

/** @type {Readonly<Record<string, Platform>>} by key, `<os>-<cpu>` */
export const PLATFORMS = Object.freeze({
  'darwin-arm64': { os: 'darwin', cpu: 'arm64', archive: 'darwin_arm64' },
  'darwin-x64': { os: 'darwin', cpu: 'x64', archive: 'darwin_amd64' },
  'linux-arm64': { os: 'linux', cpu: 'arm64', archive: 'linux_arm64' },
  'linux-x64': { os: 'linux', cpu: 'x64', archive: 'linux_amd64' },
  'win32-arm64': { os: 'win32', cpu: 'arm64', archive: 'windows_arm64' },
  'win32-x64': { os: 'win32', cpu: 'x64', archive: 'windows_amd64' },
});

/** The npm package of the native kupcad for the system `key`. @param {string} key */
export const packageOf = (key) => `@kupcad/cli-${key}`;

/** The file kupcad is on `os`. @param {NodeJS.Platform} os */
export const binaryOf = (os) => (os === 'win32' ? 'kupcad.exe' : 'kupcad');

/**
 * The key of the system running in PLATFORMS, or null where none is built for it: a system or
 * a processor of no build, or Linux with a C library other than glibc (Alpine's musl), which
 * the Linux builds need.
 * @param {{ platform: string, arch: string, glibc: () => boolean }} [system]
 * @returns {string | null}
 */
export function platformKey(system = runningSystem()) {
  const key = `${system.platform}-${system.arch}`;
  if (!Object.hasOwn(PLATFORMS, key)) return null;
  if (system.platform === 'linux' && !system.glibc()) return null;
  return key;
}

/** The system Node runs on. */
function runningSystem() {
  return {
    platform: process.platform,
    arch: process.arch,
    // Node's report names the glibc it runs on, and none where it runs on musl
    glibc: () => {
      const header = /** @type {{ header?: { glibcVersionRuntime?: string } }} */ (
        process.report?.getReport()
      )?.header;
      return header?.glibcVersionRuntime !== undefined;
    },
  };
}
