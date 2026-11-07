import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { pack } from './pack.js';

/** The folders the tests made, removed after each. @type {string[]} */
const made = [];
afterEach(() => {
  for (const folder of made.splice(0)) rmSync(folder, { recursive: true, force: true });
});

const folder = () => {
  const path = mkdtempSync(join(tmpdir(), 'kupcad-pack-test-'));
  made.push(path);
  return path;
};

/**
 * A release's archive of a system, as package-release.sh writes one: kupcad, its license, readme
 * and notices, and the libraries' licenses.
 * @param {string} archives
 * @param {string} name `kupcad_<version>_<system>.tar.gz`
 */
function archive(archives, name) {
  const files = folder();
  writeFileSync(join(files, 'kupcad'), `#!/bin/sh\necho ${name}\n`);
  for (const file of ['LICENSE', 'README.md', 'THIRD_PARTY_NOTICES.md']) {
    writeFileSync(join(files, file), file);
  }
  mkdirSync(join(files, 'licenses', 'manifold'), { recursive: true });
  writeFileSync(join(files, 'licenses', 'manifold', 'LICENSE'), 'Apache');
  const tar = spawnSync('tar', ['-czf', join(archives, name), '-C', files, '.']);
  expect(tar.status).toBe(0);
}

/** @param {string} path */
const json = (path) => JSON.parse(readFileSync(path, 'utf8'));

describe("a release's npm packages", () => {
  it("are each system's kupcad, and the command depending on them at the same version", () => {
    const archives = folder();
    archive(archives, 'kupcad_1.2.3_linux_amd64.tar.gz');
    archive(archives, 'kupcad_1.2.3_darwin_arm64.tar.gz');
    const out = join(folder(), 'npm');
    const folders = pack('1.2.3', archives, out, ['linux-x64', 'darwin-arm64']);
    expect(folders).toEqual([
      join(out, 'cli-linux-x64'),
      join(out, 'cli-darwin-arm64'),
      join(out, 'kupcad'),
    ]);

    const linux = json(join(out, 'cli-linux-x64', 'package.json'));
    expect(linux).toMatchObject({
      name: '@kupcad/cli-linux-x64',
      version: '1.2.3',
      os: ['linux'],
      cpu: ['x64'],
      libc: ['glibc'],
      license: 'AGPL-3.0-only',
    });
    expect(json(join(out, 'cli-darwin-arm64', 'package.json'))).not.toHaveProperty('libc');
    // Its kupcad, runnable, with what it ships with
    const binary = join(out, 'cli-linux-x64', 'bin', 'kupcad');
    expect(readFileSync(binary, 'utf8')).toContain('kupcad_1.2.3_linux_amd64');
    expect(statSync(binary).mode & 0o111).not.toBe(0);
    expect(
      readFileSync(join(out, 'cli-linux-x64', 'licenses', 'manifold', 'LICENSE'), 'utf8'),
    ).toBe('Apache');

    const command = json(join(out, 'kupcad', 'package.json'));
    expect(command).toMatchObject({
      name: 'kupcad',
      version: '1.2.3',
      bin: { kupcad: 'bin/kupcad.js' },
    });
    expect(command.optionalDependencies).toEqual({
      '@kupcad/cli-linux-x64': '1.2.3',
      '@kupcad/cli-darwin-arm64': '1.2.3',
    });
    // The workspace's own fields aren't published: npm can't read a catalog's versions
    expect(command).not.toHaveProperty('devDependencies');
    expect(command).not.toHaveProperty('scripts');
    expect(() => statSync(join(out, 'kupcad', 'lib', 'launch.test.js'))).toThrow('ENOENT');
    expect(statSync(join(out, 'kupcad', 'lib', 'launch.js')).isFile()).toBe(true);
  });

  it("refuses a release missing a system's archive", () => {
    expect(() => pack('1.2.3', folder(), join(folder(), 'npm'), ['linux-x64'])).toThrow(
      'kupcad_1.2.3_linux_amd64.tar.gz',
    );
  });
});
