// Where the `kupcad` to run is: the `kupcad.serverPath` setting, the extension's own installs,
// `kupcad` on PATH, or the monorepo's build, each asked its version. Free of the `vscode` import,
// so it is tested without VS Code.

import * as fs from 'node:fs';
import * as path from 'node:path';
import { isCompatible } from '@kupcad/protocol';
import { installedVersions } from './install.js';
import { compareVersions, parseVersion, satisfies } from './versions.js';

/** @import { VersionInfo } from '@kupcad/protocol/types' */
/** @import { Version } from './versions.js' */

/** @param {string} p */
const isExecutable = (p) => {
  try {
    const st = fs.statSync(p);
    if (!st.isFile()) return false;
    if (process.platform === 'win32') return true;
    fs.accessSync(p, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
};

/**
 * Looks `name` up on PATH (adds PATHEXT suffixes on Windows).
 * @param {string} name
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {string | undefined}
 */
export const findOnPath = (name, env = process.env) => {
  const dirs = (env.PATH || env.Path || '').split(path.delimiter).filter(Boolean);
  const exts = process.platform === 'win32' ? (env.PATHEXT || '.EXE;.CMD').split(';') : [''];
  for (const dir of dirs) {
    for (const ext of exts) {
      const candidate = path.join(dir, name + ext);
      if (isExecutable(candidate)) return candidate;
    }
  }
  return undefined;
};

/**
 * Expands a `~` at the start of a configured path to the home folder.
 * @param {string} configured
 * @param {NodeJS.ProcessEnv} env
 */
const expandHome = (configured, env) =>
  configured.replace(/^~(?=$|[\\/])/, env.HOME || env.USERPROFILE || '~');

/**
 * @typedef {object} Found
 * @property {string} path
 * @property {string} version
 * @property {'setting' | 'managed' | 'path' | 'development'} source
 */

/**
 * @typedef {object} FindOptions
 * @property {string | undefined} configured the `kupcad.serverPath` setting
 * @property {string} managedDir where the extension's own installs are, a folder per version
 * @property {string} extensionPath
 * @property {string} range the core versions the extension runs with
 * @property {(path: string) => Promise<VersionInfo | null>} probe
 * @property {NodeJS.ProcessEnv} [env]
 */

/**
 * The kupcad to run, in this order: the `kupcad.serverPath` setting, whatever its version (a note
 * says when it is out of range: the user chose it); the newest of the extension's own installs in
 * range; `kupcad` on PATH; the monorepo's build (when the extension runs from a source checkout).
 * Those three are run only when their version is in range and they speak this extension's
 * protocol: an old binary on PATH never runs under a newer extension. The notes say what was
 * passed over, and why.
 * @param {FindOptions} options
 * @returns {Promise<{ found: Found | null, notes: string[] }>}
 */
export async function findServer({
  configured,
  managedDir,
  extensionPath,
  range,
  probe,
  env = process.env,
}) {
  /** @type {string[]} */
  const notes = [];
  if (configured) {
    const file = expandHome(configured, env);
    const info = isExecutable(file) ? await probe(file) : null;
    if (!info) {
      notes.push(`kupcad.serverPath (${file}) is no kupcad executable`);
      return { found: null, notes };
    }
    if (!fits(info, range))
      notes.push(`kupcad.serverPath (${file}) is ${describe(info)}; this extension runs ${range}`);
    return { found: { path: file, version: info.version, source: 'setting' }, notes };
  }

  const binary = process.platform === 'win32' ? 'kupcad.exe' : 'kupcad';
  /** @type {{ path: string, source: Found['source'] }[]} */
  const candidates = [];
  const managed = (await installedVersions(managedDir, binary))
    .map((version) => ({ version, parsed: parseVersion(version) }))
    .filter((v) => v.parsed !== null)
    .toSorted((a, b) =>
      compareVersions(/** @type {Version} */ (b.parsed), /** @type {Version} */ (a.parsed)),
    );
  for (const { version } of managed)
    candidates.push({ path: path.join(managedDir, version, binary), source: 'managed' });
  const onPath = findOnPath('kupcad', env);
  if (onPath) candidates.push({ path: onPath, source: 'path' });
  const development = path.resolve(extensionPath, '../../core/zig-out/bin', binary);
  if (isExecutable(development)) candidates.push({ path: development, source: 'development' });

  for (const candidate of candidates) {
    const info = await probe(candidate.path);
    if (!info) {
      notes.push(`${candidate.path} is no kupcad executable`);
    } else if (!fits(info, range)) {
      notes.push(`${candidate.path} is ${describe(info)}; this extension runs ${range}`);
    } else {
      return { found: { ...candidate, version: info.version }, notes };
    }
  }
  return { found: null, notes };
}

/**
 * Whether a kupcad is one this extension runs: its version in range, and its protocol this
 * extension's.
 * @param {VersionInfo} info
 * @param {string} range
 */
function fits(info, range) {
  const version = parseVersion(info.version);
  return version !== null && satisfies(version, range) && isCompatible(info.protocolVersion);
}

/** @param {VersionInfo} info */
const describe = (info) => `kupcad ${info.version}, of protocol version ${info.protocolVersion}`;
