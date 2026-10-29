// Writes the updater's latest.json for a release (the release workflow, once the desktop
// installers are named as the release names them, kupcad-desktop_<version>_<os>_<arch>): each
// installer whose signature is beside it (`<file>.sig`, which `tauri build` makes with
// createUpdaterArtifacts), under the platform the app's updater looks it up by, with where the
// release keeps it. A Linux entry names its package (linux-x86_64-deb, …): the updater looks for
// the one the app was installed from first, so an app installed from a .deb gets a .deb, never
// the AppImage it couldn't install.
//
//   node scripts/updater-manifest.js <version> <owner/repo> <folder> > latest.json

import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

/** The updater's names of the release's architectures. */
const ARCHES = { amd64: 'x86_64', arm64: 'aarch64' };
/** What the updater adds to a platform for each kind of installer, by the end of its name. */
const KINDS = {
  '.app.tar.gz': '',
  '.AppImage': '-appimage',
  '.deb': '-deb',
  '.rpm': '-rpm',
  '_setup.exe': '',
};

const [version, repo, folder] = process.argv.slice(2);
if (!version || !repo || !folder) {
  console.error('usage: node scripts/updater-manifest.js <version> <owner/repo> <folder>');
  process.exit(1);
}

const prefix = `kupcad-desktop_${version}_`;
/** @type {Record<string, { signature: string, url: string }>} */
const platforms = {};
for (const sig of readdirSync(folder).filter((name) => name.endsWith('.sig'))) {
  const file = sig.slice(0, -'.sig'.length);
  const [, os, arch, kind] = file.startsWith(prefix)
    ? (/^(darwin|linux|windows)_(amd64|arm64)(.+)$/.exec(file.slice(prefix.length)) ?? [])
    : [];
  if (!os || !(kind in KINDS))
    throw new Error(`${sig}: not the signature of an installer the updater takes`);
  if (!existsSync(join(folder, file))) throw new Error(`${sig}: ${file} isn't beside it`);
  const platform = `${os}-${ARCHES[/** @type {'amd64' | 'arm64'} */ (arch)]}${KINDS[/** @type {keyof KINDS} */ (kind)]}`;
  if (platform in platforms) throw new Error(`${sig}: a second installer for ${platform}`);
  platforms[platform] = {
    signature: readFileSync(join(folder, sig), 'utf8').trim(),
    url: `https://github.com/${repo}/releases/download/v${version}/${file}`,
  };
}
if (Object.keys(platforms).length === 0) throw new Error(`no signed installers in ${folder}`);

const latest = {
  version,
  notes: `https://github.com/${repo}/releases/tag/v${version}`,
  pub_date: new Date().toISOString(),
  platforms,
};
console.log(JSON.stringify(latest, null, 2));
