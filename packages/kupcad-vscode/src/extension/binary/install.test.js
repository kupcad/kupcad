import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { sha256 } from './assets.js';
import { install, InstallError, installedVersions } from './install.js';
import { probe } from './probe.js';

const POSIX = process.platform !== 'win32';
const VERSION = '0.1.2';
const ARCHIVE = `kupcad_${VERSION}_linux_amd64.tar.gz`;
/** What the release's binary says when asked its version. */
const SAYS = { version: VERSION, protocolVersion: 1, os: 'linux', arch: 'x86_64' };

/** @type {string} */
let dir;

/** The release's linux archive, as package-release.sh makes it: a script standing in for kupcad. */
function archive() {
  const files = path.join(dir, 'files');
  fs.mkdirSync(files);
  fs.writeFileSync(path.join(files, 'kupcad'), `#!/bin/sh\necho '${JSON.stringify(SAYS)}'\n`);
  // Incompressible, so the archive comes in several chunks
  fs.writeFileSync(path.join(files, 'LICENSE'), randomBytes(5000));
  const out = path.join(dir, ARCHIVE);
  execFileSync('tar', ['-czf', out, 'LICENSE', 'kupcad'], { cwd: files });
  return new Uint8Array(fs.readFileSync(out));
}

/**
 * A server of the release's files, by URL, in chunks as a network gives them.
 * @param {Record<string, Uint8Array | string>} files
 * @returns {typeof fetch}
 */
const serving = (files) => async (url) => {
  const body = files[String(url)];
  if (body === undefined) return new Response('', { status: 404 });
  const bytes = typeof body === 'string' ? new TextEncoder().encode(body) : body;
  const stream = new ReadableStream({
    start(controller) {
      for (let at = 0; at < bytes.length; at += 1000)
        controller.enqueue(bytes.slice(at, at + 1000));
      controller.close();
    },
  });
  return new Response(stream, { headers: { 'content-length': String(bytes.length) } });
};

/** A network that is down. */
const offline = async () => {
  throw new TypeError('fetch failed');
};

/** A release whose files are at example.com. */
const release = {
  version: VERSION,
  prerelease: false,
  assets: {
    [ARCHIVE]: 'https://example.com/archive',
    'checksums.txt': 'https://example.com/checksums',
  },
};

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kupcad-install-'));
});
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

describe('install', () => {
  it.runIf(POSIX)(
    'downloads the archive, checks it, and unpacks its binary, executable, under its version',
    async () => {
      const bytes = archive();
      const get = serving({
        'https://example.com/archive': bytes,
        'https://example.com/checksums': `${sha256(bytes)}  ${ARCHIVE}\n`,
      });
      /** @type {[number, number | null][]} */
      const progress = [];
      const bin = path.join(dir, 'bin');
      const installed = await install(release, {
        get,
        dir: bin,
        platform: 'linux',
        arch: 'x64',
        progress: (got, total) => progress.push([got, total]),
      });
      expect(installed).toBe(path.join(bin, VERSION, 'kupcad'));
      expect(await probe(installed)).toEqual(SAYS);
      expect(progress.at(-1)).toEqual([bytes.length, bytes.length]);
      expect(progress.length).toBeGreaterThan(1);
      expect(await installedVersions(bin, 'kupcad')).toEqual([VERSION]);
    },
  );

  it("refuses an archive that doesn't match its checksum, and installs nothing", async () => {
    const bytes = archive();
    const get = serving({
      'https://example.com/archive': bytes,
      'https://example.com/checksums': `${'0'.repeat(64)}  ${ARCHIVE}\n`,
    });
    const bin = path.join(dir, 'bin');
    await expect(
      install(release, { get, dir: bin, platform: 'linux', arch: 'x64' }),
    ).rejects.toThrow(
      new InstallError(`${ARCHIVE} doesn't match its checksum: it was changed, or cut short`),
    );
    expect(await installedVersions(bin, 'kupcad')).toEqual([]);
  });

  it('says what is missing: a build for the platform, the archive, its checksum, the server', async () => {
    const get = serving({ 'https://example.com/checksums': 'nothing' });
    const at = { get, dir, platform: 'linux', arch: 'x64' };
    await expect(install(release, { ...at, platform: 'aix' })).rejects.toThrow(
      "kupcad isn't built for aix on x64",
    );
    await expect(install({ ...release, assets: {} }, at)).rejects.toThrow(`has no ${ARCHIVE}`);
    await expect(install(release, at)).rejects.toThrow(
      `checksums.txt of kupcad ${VERSION} has no ${ARCHIVE}`,
    );
    await expect(install(release, { ...at, get: serving({}) })).rejects.toThrow(
      'the server answered 404',
    );
    await expect(install(release, { ...at, get: offline })).rejects.toThrow(
      "couldn't download https://example.com/checksums: fetch failed",
    );
  });
});

describe('probe', () => {
  it.runIf(POSIX)("reads a kupcad's version, and nothing of a program that isn't one", async () => {
    const script = (/** @type {string} */ name, /** @type {string} */ body) => {
      const file = path.join(dir, name);
      fs.writeFileSync(file, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
      return file;
    };
    expect(await probe(script('kupcad', `echo '${JSON.stringify(SAYS)}'`))).toEqual(SAYS);
    expect(await probe(script('other', 'echo hello'))).toBeNull();
    expect(await probe(script('failing', 'exit 3'))).toBeNull();
    expect(await probe(path.join(dir, 'missing'))).toBeNull();
  });
});
