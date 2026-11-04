// The release's version, in every file that carries it: the core's build.zig.zon (what
// `kupcad --version` prints), the package.json of the npm packages, the VS Code extension and the
// desktop app, the desktop app's tauri.conf.json, the Ruby gem's version.rb (and so its
// Gemfile.lock, which `bundle lock` writes) and the Python package's _version.py. `bump` sets
// them all, as `npm version` sets a package's; the Release workflow checks a tag against them
// with `check`.
//
//   pnpm bump <major | minor | patch | version>     (node scripts/version.js bump ...)
//   node scripts/version.js check <version>

import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

/** The repository's root. */
const ROOT = join(import.meta.dirname, '..');
/** A version, as a tag names it after its `v`: major.minor.patch, with a pre-release (`-rc.1`) or not. */
const VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
/** What `bump` takes besides a version. */
const RELEASES = ['major', 'minor', 'patch'];
/** The top-level "version" of a package.json or a tauri.conf.json. */
const JSON_VERSION = /(?<=^ {2}"version": ")[^"]+(?=",$)/gm;
/** The packages carrying the version, each packages/kupcad-<name>. */
const PACKAGES = ['protocol', 'wasm', 'ui', 'editor', 'playground', 'files', 'vscode', 'desktop'];

/**
 * Each file that carries the version, by its path from the root, and its pattern: the version,
 * once in the file.
 */
export const HOLDERS = [
  { path: 'core/build.zig.zon', pattern: /(?<=^ *\.version = ")[^"]+(?=",$)/gm },
  ...PACKAGES.map((name) => ({
    path: `packages/kupcad-${name}/package.json`,
    pattern: JSON_VERSION,
  })),
  { path: 'packages/kupcad-desktop/src-tauri/tauri.conf.json', pattern: JSON_VERSION },
  { path: 'bindings/ruby/lib/kupcad/version.rb', pattern: /(?<=^ *VERSION = ')[^']+(?='$)/gm },
  { path: 'bindings/python/src/kupcad/_version.py', pattern: /(?<=^__version__ = ")[^"]+(?="$)/gm },
];

/**
 * The version of each holder under `root`.
 * @param {string} root
 * @returns {{ path: string, version: string }[]}
 */
export function versions(root) {
  return HOLDERS.map((holder) => ({ path: holder.path, version: read(root, holder).version }));
}

/**
 * Sets every holder under `root` to `version`. Each is read first, so one whose version isn't
 * found fails the change before any file is written.
 * @param {string} root
 * @param {string} version
 */
export function setVersion(root, version) {
  const files = HOLDERS.map((holder) => ({ ...holder, text: read(root, holder).text }));
  for (const { path, pattern, text } of files)
    writeFileSync(join(root, path), text.replace(pattern, version));
}

/**
 * The version `wanted` sets: a version itself, or the major, minor or patch release after the
 * holders' version (`current`, which must be one), as `npm version` counts them: a
 * pre-release's is the release it comes before where that is one (0.2.0-rc.1's minor is 0.2.0).
 * @param {{ path: string, version: string }[]} current
 * @param {string} wanted
 */
export function nextVersion(current, wanted) {
  if (VERSION.test(wanted)) return wanted;
  if (!RELEASES.includes(wanted)) {
    throw new Error(
      `${wanted} isn't one of ${RELEASES.join(', ')} or a version (1.2.0, 1.2.0-rc.1)`,
    );
  }
  const found = new Set(current.map(({ version }) => version));
  if (found.size > 1)
    throw new Error(`the versions differ: set them all with a version${listed(current)}`);
  const [version] = found;
  const [, major, minor, patch, pre] = VERSION.exec(version) ?? [];
  if (major === undefined) throw new Error(`${current[0].path}: ${version} isn't a version`);
  const [x, y, z] = [major, minor, patch].map(Number);
  switch (wanted) {
    case 'major':
      return pre && y === 0 && z === 0 ? `${x}.0.0` : `${x + 1}.0.0`;
    case 'minor':
      return pre && z === 0 ? `${x}.${y}.0` : `${x}.${y + 1}.0`;
    default:
      return pre ? `${x}.${y}.${z}` : `${x}.${y}.${z + 1}`;
  }
}

/**
 * The text of `holder`'s file under `root`, and the version in it.
 * @param {string} root
 * @param {{ path: string, pattern: RegExp }} holder
 */
function read(root, { path, pattern }) {
  const text = readFileSync(join(root, path), 'utf8');
  const found = text.match(pattern) ?? [];
  if (found.length !== 1)
    throw new Error(`${path}: its version is in it ${found.length} times, not once`);
  return { text, version: found[0] };
}

/**
 * Holders and their versions, a line each.
 * @param {{ path: string, version: string }[]} holders
 */
function listed(holders) {
  return holders.map(({ path, version }) => `\n  ${path}: ${version}`).join('');
}

/** @param {string} wanted */
function bump(wanted) {
  const current = versions(ROOT);
  const version = nextVersion(current, wanted);
  setVersion(ROOT, version);
  console.log(`${[...new Set(current.map((holder) => holder.version))].join(', ')} -> ${version}`);
  const locked = spawnSync('bundle', ['lock'], {
    cwd: join(ROOT, 'bindings/ruby'),
    stdio: 'inherit',
  });
  if (locked.status !== 0) {
    throw new Error(
      `${version} is set, but not in bindings/ruby/Gemfile.lock: run \`bundle lock\` there`,
    );
  }
  console.log(
    `Commit, then tag the commit and push the tag: git tag v${version} && git push origin v${version}`,
  );
}

/** @param {string} wanted */
function check(wanted) {
  const other = versions(ROOT).filter(({ version }) => version !== wanted);
  if (other.length > 0) {
    throw new Error(
      `these aren't ${wanted} (\`pnpm bump ${wanted}\` sets them all):${listed(other)}`,
    );
  }
}

if (import.meta.main) {
  const [command = '', wanted] = process.argv.slice(2);
  const run = new Map([
    ['bump', bump],
    ['check', check],
  ]).get(command);
  try {
    if (!run || !wanted) {
      throw new Error(
        'usage: pnpm bump <major | minor | patch | version>, or node scripts/version.js check <version>',
      );
    }
    run(wanted);
  } catch (error) {
    console.error(`version: ${error instanceof Error ? error.message : error}`);
    process.exitCode = 1;
  }
}
