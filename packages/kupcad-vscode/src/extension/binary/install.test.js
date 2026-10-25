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

/**
 * `get`, its answers redirected to `to`, as GitHub redirects a download to its storage.
 * @param {typeof fetch} get
 * @param {string} to
 * @returns {typeof fetch}
 */
const redirectedTo = (get, to) => async (url) => {
  const response = await get(url);
  Object.defineProperty(response, 'url', { value: `${to}${new URL(String(url)).pathname}` });
  return response;
};

/** An attestation that holds, of whatever was downloaded. */
const attested = async () => {};

/** A network that is down. */
const offline = async () => {
  throw new TypeError('fetch failed');
};

/** A release whose files are in the repository's release downloads. */
const release = {
  version: VERSION,
  prerelease: false,
  assets: {
    [ARCHIVE]: 'https://github.com/kupcad/kupcad/releases/download/v0.1.2/archive',
    'checksums.txt': 'https://github.com/kupcad/kupcad/releases/download/v0.1.2/checksums',
  },
};

/** An install of the release, served whole, into the test's `bin` folder. */
function servedRelease() {
  const bytes = archive();
  const get = serving({
    'https://github.com/kupcad/kupcad/releases/download/v0.1.2/archive': bytes,
    'https://github.com/kupcad/kupcad/releases/download/v0.1.2/checksums': `${sha256(bytes)}  ${ARCHIVE}\n`,
  });
  return { get, attest: attested, dir: path.join(dir, 'bin'), platform: 'linux', arch: 'x64' };
}

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
        'https://github.com/kupcad/kupcad/releases/download/v0.1.2/archive': bytes,
        'https://github.com/kupcad/kupcad/releases/download/v0.1.2/checksums': `${sha256(bytes)}  ${ARCHIVE}\n`,
      });
      /** @type {[number, number | null][]} */
      const progress = [];
      const bin = path.join(dir, 'bin');
      const installed = await install(release, {
        get,
        attest: attested,
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

  it.runIf(POSIX)(
    "takes a download GitHub's storage serves, and refuses one redirected anywhere else",
    async () => {
      const served = servedRelease();
      const github = {
        ...served,
        get: redirectedTo(served.get, 'https://release-assets.githubusercontent.com'),
      };
      expect(await install(release, github)).toBe(path.join(served.dir, VERSION, 'kupcad'));
      fs.rmSync(served.dir, { recursive: true, force: true });
      const elsewhere = { ...served, get: redirectedTo(served.get, 'https://evil.example') };
      await expect(install(release, elsewhere)).rejects.toThrow(
        "couldn't download https://github.com/kupcad/kupcad/releases/download/v0.1.2/checksums: it came from evil.example, not GitHub",
      );
      expect(await installedVersions(served.dir, 'kupcad')).toEqual([]);
    },
  );

  it("refuses an archive that doesn't match its checksum, and installs nothing", async () => {
    const bytes = archive();
    const get = serving({
      'https://github.com/kupcad/kupcad/releases/download/v0.1.2/archive': bytes,
      'https://github.com/kupcad/kupcad/releases/download/v0.1.2/checksums': `${'0'.repeat(64)}  ${ARCHIVE}\n`,
    });
    const bin = path.join(dir, 'bin');
    await expect(
      install(release, { get, attest: attested, dir: bin, platform: 'linux', arch: 'x64' }),
    ).rejects.toThrow(
      new InstallError(`${ARCHIVE} doesn't match its checksum: it was changed, or cut short`),
    );
    expect(await installedVersions(bin, 'kupcad')).toEqual([]);
  });

  it.runIf(POSIX)(
    "refuses an archive its release workflow didn't attest, and installs nothing",
    async () => {
      const served = servedRelease();
      /** @type {[string, string][]} */
      const asked = [];
      const forged = async (/** @type {string} */ digest, /** @type {string} */ version) => {
        asked.push([digest, version]);
        throw new Error("it has no attestation: kupcad's release workflow didn't build it");
      };
      await expect(install(release, { ...served, attest: forged })).rejects.toThrow(
        new InstallError(
          `${ARCHIVE} isn't kupcad's own release: it has no attestation: kupcad's release workflow didn't build it`,
        ),
      );
      // Asked of the archive the checksums name, for the release's version
      expect(asked[0][1]).toBe(VERSION);
      expect(asked[0][0]).toMatch(/^[0-9a-f]{64}$/);
      expect(await installedVersions(served.dir, 'kupcad')).toEqual([]);
    },
  );

  it('says what is missing: a build for the platform, the archive, its checksum, the server', async () => {
    const get = serving({
      'https://github.com/kupcad/kupcad/releases/download/v0.1.2/checksums': 'nothing',
    });
    const at = { get, attest: attested, dir, platform: 'linux', arch: 'x64' };
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
      "couldn't download https://github.com/kupcad/kupcad/releases/download/v0.1.2/checksums: fetch failed",
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

describe('installs together', () => {
  it.runIf(POSIX)(
    'installs one release three times at once (three windows): each ends with it',
    async () => {
      const at = servedRelease();
      const all = await Promise.all([
        install(release, at),
        install(release, at),
        install(release, at),
      ]);
      const installed = path.join(at.dir, VERSION, 'kupcad');
      expect(all).toEqual([installed, installed, installed]);
      expect(await probe(installed)).toEqual(SAYS);
      // No partial folder is left
      expect(fs.readdirSync(at.dir)).toEqual([VERSION]);
    },
  );

  it.runIf(POSIX)(
    'keeps an install of the version already there, and replaces a folder of it without its binary',
    async () => {
      const at = servedRelease();
      const installed = path.join(at.dir, VERSION, 'kupcad');
      fs.mkdirSync(path.dirname(installed), { recursive: true });
      fs.writeFileSync(installed, 'the one running', { mode: 0o755 });
      expect(await install(release, at)).toBe(installed);
      expect(fs.readFileSync(installed, 'utf8')).toBe('the one running');

      fs.rmSync(installed);
      fs.writeFileSync(path.join(at.dir, VERSION, 'stray'), '');
      expect(await install(release, at)).toBe(installed);
      expect(await probe(installed)).toEqual(SAYS);
    },
  );

  it('counts no partial folder as installed', async () => {
    const bin = path.join(dir, 'bin');
    fs.mkdirSync(path.join(bin, `${VERSION}.0e7c.partial`), { recursive: true });
    fs.writeFileSync(path.join(bin, `${VERSION}.0e7c.partial`, 'kupcad'), '');
    expect(await installedVersions(bin, 'kupcad')).toEqual([]);
  });
});
