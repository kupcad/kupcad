import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { updaterManifest } from './updater-manifest.js';

const VERSION = '0.2.0';
const REPO = 'kupcad/kupcad';
const PUBLISHED = new Date('2026-11-05T12:00:00Z');

/** @type {string} */
let dist;
beforeEach(() => {
  dist = mkdtempSync(join(tmpdir(), 'kupcad-updater-'));
});
afterEach(() => rmSync(dist, { recursive: true, force: true }));

/**
 * Puts the release's installers in the folder, each named as the release names it, signed (its
 * `.sig` beside it) or not.
 * @param {string[]} names what follows `kupcad-desktop_<version>_`
 * @param {{ signed?: boolean }} [how]
 */
function installers(names, { signed = true } = {}) {
  for (const name of names) {
    const file = `kupcad-desktop_${VERSION}_${name}`;
    writeFileSync(join(dist, file), 'installer');
    if (signed) writeFileSync(join(dist, `${file}.sig`), `signature of ${name}\n`);
  }
}

/** @param {string} name what follows `kupcad-desktop_<version>_` */
const url = (name) =>
  `https://github.com/${REPO}/releases/download/v${VERSION}/kupcad-desktop_${VERSION}_${name}`;

describe("the updater's latest.json", () => {
  it('lists each signed installer under the platform the updater looks it up by', () => {
    installers([
      'darwin_arm64.app.tar.gz',
      'darwin_amd64.app.tar.gz',
      'linux_amd64.AppImage',
      'linux_amd64.deb',
      'linux_amd64.rpm',
      'linux_arm64.deb',
      'windows_amd64_setup.exe',
    ]);
    // The disk image and the checksums are no updater's
    installers(['darwin_arm64.dmg'], { signed: false });
    writeFileSync(join(dist, 'checksums.txt'), '');
    expect(updaterManifest(VERSION, REPO, dist, PUBLISHED)).toEqual({
      version: VERSION,
      notes: `https://github.com/${REPO}/releases/tag/v${VERSION}`,
      pub_date: '2026-11-05T12:00:00.000Z',
      platforms: {
        'darwin-aarch64': {
          signature: 'signature of darwin_arm64.app.tar.gz',
          url: url('darwin_arm64.app.tar.gz'),
        },
        'darwin-x86_64': {
          signature: 'signature of darwin_amd64.app.tar.gz',
          url: url('darwin_amd64.app.tar.gz'),
        },
        // A Linux app finds the package it was installed from
        'linux-x86_64-appimage': {
          signature: 'signature of linux_amd64.AppImage',
          url: url('linux_amd64.AppImage'),
        },
        'linux-x86_64-deb': {
          signature: 'signature of linux_amd64.deb',
          url: url('linux_amd64.deb'),
        },
        'linux-x86_64-rpm': {
          signature: 'signature of linux_amd64.rpm',
          url: url('linux_amd64.rpm'),
        },
        'linux-aarch64-deb': {
          signature: 'signature of linux_arm64.deb',
          url: url('linux_arm64.deb'),
        },
        'windows-x86_64': {
          signature: 'signature of windows_amd64_setup.exe',
          url: url('windows_amd64_setup.exe'),
        },
      },
    });
  });

  it('refuses a second installer for a platform', () => {
    installers(['windows_amd64_setup.exe', 'windows_amd64.app.tar.gz']);
    expect(() => updaterManifest(VERSION, REPO, dist)).toThrow(
      'a second installer for windows-x86_64',
    );
  });

  it('refuses a signature with no installer beside it', () => {
    writeFileSync(join(dist, `kupcad-desktop_${VERSION}_linux_amd64.deb.sig`), 'signature');
    expect(() => updaterManifest(VERSION, REPO, dist)).toThrow(
      `kupcad-desktop_${VERSION}_linux_amd64.deb isn't beside it`,
    );
  });

  it("refuses a signature of what the updater doesn't install, or of another version", () => {
    for (const name of [
      `kupcad-desktop_${VERSION}_linux_amd64.tar.gz`,
      `kupcad-desktop_${VERSION}_freebsd_amd64.deb`,
      'kupcad-desktop_0.1.9_linux_amd64.deb',
    ]) {
      rmSync(dist, { recursive: true, force: true });
      dist = mkdtempSync(join(tmpdir(), 'kupcad-updater-'));
      writeFileSync(join(dist, name), 'installer');
      writeFileSync(join(dist, `${name}.sig`), 'signature');
      expect(() => updaterManifest(VERSION, REPO, dist)).toThrow(
        'not the signature of an installer the updater takes',
      );
    }
  });

  it('refuses a release with no signed installer', () => {
    installers(['darwin_arm64.dmg'], { signed: false });
    expect(() => updaterManifest(VERSION, REPO, dist)).toThrow('no signed installers');
  });

  it('is written by the release workflow as before: node scripts/updater-manifest.js <version> <repo> <folder>', () => {
    installers(['linux_amd64.deb']);
    const script = join(import.meta.dirname, 'updater-manifest.js');
    const written = JSON.parse(
      execFileSync(process.execPath, [script, VERSION, REPO, dist], { encoding: 'utf8' }),
    );
    expect(Object.keys(written.platforms)).toEqual(['linux-x86_64-deb']);
    expect(written.version).toBe(VERSION);
  });
});
