import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { findOnPath, resolveServerPath } from './resolve.js';

const BIN_NAME = process.platform === 'win32' ? 'kupcad.EXE' : 'kupcad';
const POSIX = process.platform !== 'win32';

/** @param {string[]} dirs */
const pathEnv = (...dirs) => ({ PATH: dirs.join(path.delimiter), PATHEXT: '.EXE' });

describe('server path resolution', () => {
  /** @type {string} */
  let dir;
  /** @type {string} */
  let bin;
  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kupcad-'));
    bin = path.join(dir, BIN_NAME);
    fs.writeFileSync(bin, '');
    fs.chmodSync(bin, 0o755);
  });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  it('prefers the configured path, then PATH', () => {
    const other = fs.mkdtempSync(path.join(os.tmpdir(), 'kupcad-other-'));
    try {
      fs.copyFileSync(bin, path.join(other, BIN_NAME));
      fs.chmodSync(path.join(other, BIN_NAME), 0o755);
      expect(
        resolveServerPath({ configured: bin, extensionPath: '/nonexistent', env: pathEnv(other) }),
      ).toBe(bin);
      expect(findOnPath('kupcad', pathEnv(dir))).toBe(bin);
      expect(
        resolveServerPath({ configured: '', extensionPath: '/nonexistent/a/b', env: pathEnv(dir) }),
      ).toBe(bin);
    } finally {
      fs.rmSync(other, { recursive: true, force: true });
    }
  });

  it('never falls back when the configured path is unusable', () => {
    expect(
      resolveServerPath({
        configured: path.join(dir, 'missing'),
        extensionPath: '/x',
        env: pathEnv(dir),
      }),
    ).toBeUndefined();
    expect(
      resolveServerPath({ configured: dir, extensionPath: '/x', env: pathEnv(dir) }),
    ).toBeUndefined(); // a directory
  });

  it('expands ~ in the configured path', () => {
    expect(
      resolveServerPath({ configured: `~/${BIN_NAME}`, extensionPath: '/x', env: { HOME: dir } }),
    ).toBe(bin);
  });

  it.runIf(POSIX)('skips non-executable files on PATH', () => {
    const plain = fs.mkdtempSync(path.join(os.tmpdir(), 'kupcad-noexec-'));
    try {
      fs.writeFileSync(path.join(plain, 'kupcad'), '');
      fs.chmodSync(path.join(plain, 'kupcad'), 0o644);
      expect(findOnPath('kupcad', pathEnv(plain, dir))).toBe(bin);
      expect(findOnPath('kupcad', pathEnv(plain))).toBeUndefined();
    } finally {
      fs.rmSync(plain, { recursive: true, force: true });
    }
  });

  it('falls back to the monorepo dev build last', () => {
    // extensionPath/../../core/zig-out/bin/kupcad
    const extensionPath = path.join(dir, 'packages', 'kupcad-vscode');
    const devBin = path.join(dir, 'core', 'zig-out', 'bin', 'kupcad');
    fs.mkdirSync(path.dirname(devBin), { recursive: true });
    fs.copyFileSync(bin, devBin);
    fs.chmodSync(devBin, 0o755);
    expect(resolveServerPath({ configured: '', extensionPath, env: { PATH: '' } })).toBe(devBin);
    expect(resolveServerPath({ configured: '', extensionPath, env: pathEnv(dir) })).toBe(bin);
    fs.rmSync(devBin);
    expect(resolveServerPath({ configured: '', extensionPath, env: { PATH: '' } })).toBeUndefined();
  });
});
