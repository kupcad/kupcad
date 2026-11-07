// The npm packages of a release's kupcad, made of its archives, each a folder to publish:
// `@kupcad/cli-<os>-<cpu>` for each system (its native kupcad, licenses and notices, installed
// by npm only on that system), and `kupcad`, the command that runs the one installed, which
// depends on them all (optionally: npm installs the one for its system). The release workflow
// publishes them after the GitHub release, and the first versions were published by hand:
//
//   node packages/kupcad-cli/scripts/pack.js <version> <folder of the release's archives> <out>
//   npm publish <out>/cli-<os>-<cpu> (each), then npm publish <out>/kupcad

import { spawnSync } from 'node:child_process';
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { binaryOf, packageOf, PLATFORMS } from '../lib/platforms.js';

/** The `kupcad` package's folder, which its published copy is made of. */
const PACKAGE = join(import.meta.dirname, '..');
/** What of an archive a system's package carries beside kupcad. */
const BESIDE = ['LICENSE', 'README.md', 'THIRD_PARTY_NOTICES.md', 'licenses'];

/**
 * Makes the packages of `version` in `out` (made fresh), of the archives in `archives`:
 * `out/cli-<key>` for each system of `keys`, and `out/kupcad`.
 * @param {string} version
 * @param {string} archives
 * @param {string} out
 * @param {string[]} [keys] the systems, all of PLATFORMS unless given
 * @returns {string[]} the folders made, each system's before kupcad's
 */
export function pack(version, archives, out, keys = Object.keys(PLATFORMS)) {
  rmSync(out, { recursive: true, force: true });
  mkdirSync(out, { recursive: true });
  const made = keys.map((key) => systemPackage(version, archives, out, key));
  made.push(commandPackage(version, out, keys));
  return made;
}

/**
 * `@kupcad/cli-<key>`: the system's kupcad, unpacked from its archive, with what it ships with.
 * @param {string} version
 * @param {string} archives
 * @param {string} out
 * @param {string} key
 */
function systemPackage(version, archives, out, key) {
  const platform = PLATFORMS[key];
  const extension = platform.os === 'win32' ? 'zip' : 'tar.gz';
  const archive = join(archives, `kupcad_${version}_${platform.archive}.${extension}`);
  if (!existsSync(archive)) throw new Error(`${archive} isn't there`);
  const unpacked = mkdtempSync(join(tmpdir(), 'kupcad-cli-'));
  try {
    unpack(archive, unpacked);
    const folder = join(out, `cli-${key}`);
    const binary = binaryOf(platform.os);
    mkdirSync(join(folder, 'bin'), { recursive: true });
    cpSync(join(unpacked, binary), join(folder, 'bin', binary));
    chmodSync(join(folder, 'bin', binary), 0o755);
    for (const name of BESIDE)
      cpSync(join(unpacked, name), join(folder, name), { recursive: true });
    const manifest = {
      name: packageOf(key),
      version,
      description: `The kupcad command for ${platform.os} on ${platform.cpu}, which the kupcad package runs.`,
      license: 'AGPL-3.0-only',
      repository: {
        type: 'git',
        url: 'git+https://github.com/kupcad/kupcad.git',
        directory: 'packages/kupcad-cli',
      },
      homepage: 'https://kupcad.org',
      os: [platform.os],
      cpu: [platform.cpu],
      // The Linux builds link glibc (2.28 or later), so npm leaves them out on musl
      ...(platform.os === 'linux' ? { libc: ['glibc'] } : {}),
      files: ['bin', ...BESIDE],
      publishConfig: { access: 'public' },
    };
    writeFileSync(join(folder, 'package.json'), `${JSON.stringify(manifest, null, 2)}\n`);
    return folder;
  } finally {
    rmSync(unpacked, { recursive: true, force: true });
  }
}

/**
 * `kupcad`: this package as published, at `version`, each system's package an optional
 * dependency of it at the same version. Its development's own fields (scripts, the tools it is
 * tested with, named by the workspace's catalog) aren't published.
 * @param {string} version
 * @param {string} out
 * @param {string[]} keys
 */
function commandPackage(version, out, keys) {
  const folder = join(out, 'kupcad');
  for (const name of ['bin', 'lib', 'README.md']) {
    cpSync(join(PACKAGE, name), join(folder, name), {
      recursive: true,
      filter: (path) => !path.endsWith('.test.js'),
    });
  }
  const {
    scripts: _scripts,
    devDependencies: _tools,
    ...manifest
  } = JSON.parse(readFileSync(join(PACKAGE, 'package.json'), 'utf8'));
  manifest.version = version;
  manifest.optionalDependencies = Object.fromEntries(keys.map((key) => [packageOf(key), version]));
  writeFileSync(join(folder, 'package.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  return folder;
}

/**
 * Unpacks `archive` (a .tar.gz, or a Windows build's .zip) into `into`.
 * @param {string} archive
 * @param {string} into
 */
function unpack(archive, into) {
  const tools = archive.endsWith('.zip')
    ? // unzip where it is (Linux's tar reads no zip); bsdtar reads one (macOS, Windows)
      [
        ['unzip', ['-q', archive, '-d', into]],
        ['tar', ['-xf', archive, '-C', into]],
      ]
    : [['tar', ['-xzf', archive, '-C', into]]];
  for (const [tool, args] of /** @type {[string, string[]][]} */ (tools)) {
    const run = spawnSync(tool, args, { stdio: 'inherit' });
    if (run.error && /** @type {NodeJS.ErrnoException} */ (run.error).code === 'ENOENT') continue;
    if (run.status === 0) return;
    throw new Error(`${tool} couldn't unpack ${archive}`);
  }
  throw new Error(`Nothing here unpacks ${archive}: install unzip`);
}

if (import.meta.main) {
  const [version, archives, out] = process.argv.slice(2);
  if (!version || !archives || !out) {
    console.error('usage: node packages/kupcad-cli/scripts/pack.js <version> <archives> <out>');
    process.exitCode = 2;
  } else {
    for (const folder of pack(version, archives, out)) console.log(folder);
  }
}
