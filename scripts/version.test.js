import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { HOLDERS, check, nextVersion, setVersion, versions } from './version.js';

/** The repository's root, whose holders the tests copy. */
const ROOT = join(import.meta.dirname, '..');

/** @param {string} version */
const all = (version) => HOLDERS.map(({ path }) => ({ path, version }));

describe('nextVersion', () => {
  it('counts major, minor and patch releases as npm version does', () => {
    expect(nextVersion(all('1.2.3'), 'patch')).toBe('1.2.4');
    expect(nextVersion(all('1.2.3'), 'minor')).toBe('1.3.0');
    expect(nextVersion(all('1.2.3'), 'major')).toBe('2.0.0');
    expect(nextVersion(all('0.9.10'), 'patch')).toBe('0.9.11');
  });

  it("makes a pre-release's release the release it comes before, where that is one", () => {
    expect(nextVersion(all('1.2.3-rc.1'), 'patch')).toBe('1.2.3');
    expect(nextVersion(all('1.2.0-rc.1'), 'minor')).toBe('1.2.0');
    expect(nextVersion(all('1.2.3-rc.1'), 'minor')).toBe('1.3.0');
    expect(nextVersion(all('2.0.0-rc.1'), 'major')).toBe('2.0.0');
    expect(nextVersion(all('2.1.0-rc.1'), 'major')).toBe('3.0.0');
  });

  it('takes a version as it is, whatever the holders have', () => {
    const differing = [...all('1.2.3'), { path: 'other', version: '0.1.0' }];
    expect(nextVersion(differing, '2.0.0-rc.1')).toBe('2.0.0-rc.1');
    expect(nextVersion(differing, '0.1.0')).toBe('0.1.0');
  });

  it.each(['v1.2.3', '1.2', '01.2.3', '1.2.3-', '1.2.3-rc..1', '1.2.3+build', 'next'])(
    "refuses %s, which isn't a release or a version, saying what is",
    (wanted) => {
      expect(() => nextVersion(all('1.2.3'), wanted)).toThrow(
        /isn't one of major, minor, patch or a version/,
      );
    },
  );

  it('refuses a release after holders whose versions differ, naming them', () => {
    const differing = [...all('1.2.3'), { path: 'bindings/x.rb', version: '1.2.2' }];
    expect(() => nextVersion(differing, 'patch')).toThrow(
      /versions differ[^]*\n  bindings\/x\.rb: 1\.2\.2/,
    );
  });
});

describe('setVersion', () => {
  /** A copy of the repository's holders, at their paths. */
  let root = '';

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'kupcad-version-'));
    for (const { path } of HOLDERS) cpSync(join(ROOT, path), join(root, path));
  });

  afterEach(() => rmSync(root, { recursive: true, force: true }));

  it('sets the version of every holder, and changes nothing else of them', () => {
    setVersion(root, '10.20.30-rc.1');
    expect(versions(root)).toEqual(all('10.20.30-rc.1'));
    const changes = HOLDERS.map(({ path }) => {
      const before = readFileSync(join(ROOT, path), 'utf8').split('\n');
      const after = readFileSync(join(root, path), 'utf8').split('\n');
      const changed = after.filter((line, index) => line !== before[index]);
      return { path, lines: after.length - before.length, changed };
    });
    expect(changes).toEqual(
      HOLDERS.map(({ path, times = 1 }) => ({
        path,
        lines: 0,
        changed: Array(times).fill(expect.stringContaining('10.20.30-rc.1')),
      })),
    );
  });

  it("sets the gem's version in Gemfile.lock, its spec and its checksum, as Bundler writes them", () => {
    setVersion(root, '0.4.0');
    const lock = readFileSync(join(root, 'bindings/ruby/Gemfile.lock'), 'utf8');
    expect(lock).toMatch(/^PATH\n  remote: \.\n  specs:\n    kupcad \(0\.4\.0\)$/m);
    expect(lock).toMatch(/^CHECKSUMS\n(?: {2}.+\n)*? {2}kupcad \(0\.4\.0\)$/m);
  });

  it('refuses a Gemfile.lock whose spec and checksum name other versions, saying which', () => {
    const path = join(root, 'bindings/ruby/Gemfile.lock');
    const lock = readFileSync(path, 'utf8');
    writeFileSync(path, lock.replace(/(?<=^ {4}kupcad \()[^)]+/m, '0.4.0'));
    expect(() => versions(root)).toThrow(/Gemfile\.lock: its versions differ: 0\.4\.0, /);
  });

  it("changes no file when one's version isn't found, saying which", () => {
    const before = readFileSync(join(root, 'core/build.zig.zon'), 'utf8');
    writeFileSync(join(root, 'bindings/python/src/kupcad/_version.py'), '"""None here"""\n');
    expect(() => setVersion(root, '9.9.9')).toThrow(
      /_version\.py: its version is in it 0 times, not once/,
    );
    expect(readFileSync(join(root, 'core/build.zig.zon'), 'utf8')).toBe(before);
  });

  it('sets only the top-level version of a package.json, the same version nested before it kept', () => {
    const path = join(root, 'packages/kupcad-ui/package.json');
    writeFileSync(
      path,
      '{\n  "engines": {\n    "version": "0.3.0",\n  },\n  "version": "0.3.0",\n}\n',
    );
    setVersion(root, '0.4.0');
    expect(readFileSync(path, 'utf8')).toBe(
      '{\n  "engines": {\n    "version": "0.3.0",\n  },\n  "version": "0.4.0",\n}\n',
    );
  });
});

describe('check', () => {
  /** A copy of the repository's holders, at their paths, each at 0.4.0. */
  let root = '';

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'kupcad-version-'));
    for (const { path } of HOLDERS) cpSync(join(ROOT, path), join(root, path));
    setVersion(root, '0.4.0');
  });

  afterEach(() => rmSync(root, { recursive: true, force: true }));

  it('passes the version every holder has', () => {
    expect(() => check(root, '0.4.0')).not.toThrow();
  });

  // A frozen `bundle install`, as the release's, refuses that lock once version.rb says another
  it("names Gemfile.lock when it wasn't bumped with version.rb", () => {
    const path = join(root, 'bindings/ruby/lib/kupcad/version.rb');
    writeFileSync(path, readFileSync(path, 'utf8').replace('0.4.0', '0.5.0'));
    expect(() => check(root, '0.5.0')).toThrow(
      /these aren't 0\.5\.0[^]*\n {2}bindings\/ruby\/Gemfile\.lock: 0\.4\.0/,
    );
  });
});
