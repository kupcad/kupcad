import { execFileSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { extractFile } from './archive.js';
import { assetFor, checksumOf, sha256 } from './assets.js';

/** The release's binary. */
const BINARY = new Uint8Array(70_000).map((_, i) => (i * 7) % 251);
/** @type {string} */
let dir;

/**
 * The archive `command` makes (`tar -czf`, `zip -qr`) of the `members` of a folder `make` fills.
 * @param {string} archive its file's name
 * @param {(folder: string) => void} make
 * @param {string[]} command
 * @param {string[]} members
 */
function packed(archive, make, command, members) {
  const files = path.join(dir, archive.replace(/\W/g, '_'));
  fs.mkdirSync(files);
  make(files);
  const out = path.join(dir, archive);
  execFileSync(command[0], [...command.slice(1), out, ...members], { cwd: files });
  return new Uint8Array(fs.readFileSync(out));
}

/**
 * A release's archive, as package-release.sh lays it out: the binary at the top.
 * @param {string} binary its name for the binary
 * @param {string} archive
 * @param {string[]} command
 */
function archived(binary, archive, command) {
  const layout = (/** @type {string} */ files) => {
    fs.writeFileSync(path.join(files, binary), BINARY);
    fs.writeFileSync(path.join(files, 'LICENSE'), 'AGPL');
    fs.mkdirSync(path.join(files, 'licenses'));
    fs.writeFileSync(path.join(files, 'licenses', 'manifold'), 'Apache');
  };
  return packed(archive, layout, command, ['LICENSE', 'licenses', binary]);
}

/**
 * A .tar.gz of the `members` of a folder `make` fills.
 * @param {string} name
 * @param {(folder: string) => void} make
 * @param {string[]} members
 */
const tarGz = (name, make, members) => packed(`${name}.tar.gz`, make, ['tar', '-czf'], members);

/** @param {string} folder */
const binaryIn = (folder) => fs.writeFileSync(path.join(folder, 'kupcad'), BINARY);

beforeAll(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kupcad-archive-'));
});
afterAll(() => fs.rmSync(dir, { recursive: true, force: true }));

describe('extractFile', () => {
  it("takes the binary out of a .tar.gz, and nothing for a name it hasn't", () => {
    const tar = archived('kupcad', 'release.tar.gz', ['tar', '-czf']);
    expect(extractFile(tar, 'tar.gz', 'kupcad')).toEqual(BINARY);
    expect(extractFile(tar, 'tar.gz', 'kupcad.exe')).toBeNull();
    expect(extractFile(tar, 'tar.gz', 'licenses')).toBeNull();
  });

  it('takes it named ./kupcad, and after the header of a name too long for ustar (pax or GNU)', () => {
    const dotted = tarGz('dotted', binaryIn, ['./kupcad']);
    expect(extractFile(dotted, 'tar.gz', 'kupcad')).toEqual(BINARY);
    const long = `licenses-${'x'.repeat(120)}`;
    const afterLong = tarGz(
      'long',
      (folder) => {
        fs.writeFileSync(path.join(folder, long), 'Apache');
        binaryIn(folder);
      },
      [long, 'kupcad'],
    );
    expect(extractFile(afterLong, 'tar.gz', 'kupcad')).toEqual(BINARY);
  });

  it('takes no link named kupcad: only a file is', () => {
    const linked = tarGz(
      'linked',
      (folder) => fs.symlinkSync('/bin/sh', path.join(folder, 'kupcad')),
      ['kupcad'],
    );
    expect(extractFile(linked, 'tar.gz', 'kupcad')).toBeNull();
  });

  it('takes it out of a .zip, deflated or stored', () => {
    for (const command of [
      ['zip', '-qr'],
      ['zip', '-qr0'],
    ]) {
      const zip = archived('kupcad.exe', `release${command[1]}.zip`, command);
      expect(extractFile(zip, 'zip', 'kupcad.exe')).toEqual(BINARY);
      expect(extractFile(zip, 'zip', 'kupcad')).toBeNull();
    }
  });

  it('says so of a zip that is no zip', () => {
    expect(() => extractFile(new Uint8Array(100), 'zip', 'kupcad.exe')).toThrow(/no zip/);
  });
});

describe('assets', () => {
  it('names the archive of each platform the core is built for, and none for another', () => {
    expect(assetFor('0.1.0', 'linux', 'x64')).toEqual({
      archive: 'kupcad_0.1.0_linux_amd64.tar.gz',
      format: 'tar.gz',
      binary: 'kupcad',
    });
    expect(assetFor('0.1.0', 'darwin', 'arm64')?.archive).toBe('kupcad_0.1.0_darwin_arm64.tar.gz');
    expect(assetFor('0.1.0', 'win32', 'arm64')).toEqual({
      archive: 'kupcad_0.1.0_windows_arm64.zip',
      format: 'zip',
      binary: 'kupcad.exe',
    });
    expect(assetFor('0.1.0', 'freebsd', 'x64')).toBeNull();
    expect(assetFor('0.1.0', 'linux', 'ia32')).toBeNull();
  });

  it("reads an archive's SHA-256 from checksums.txt, as sha256sum writes it", () => {
    const hash = sha256(BINARY);
    const checksums = `${'0'.repeat(64)}  kupcad_0.1.0_linux_amd64.tar.gz\n${hash} *kupcad_0.1.0_darwin_arm64.tar.gz\n`;
    expect(checksumOf(checksums, 'kupcad_0.1.0_darwin_arm64.tar.gz')).toBe(hash);
    expect(checksumOf(checksums, 'kupcad_0.1.0_linux_amd64.tar.gz')).toBe('0'.repeat(64));
    expect(checksumOf(checksums, 'kupcad_0.1.0_windows_amd64.zip')).toBeNull();
    expect(checksumOf('not a checksum  kupcad.zip', 'kupcad.zip')).toBeNull();
  });
});
