import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { PROTOCOL_VERSION } from '@kupcad/protocol';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { findOnPath, findServer } from './resolve.js';

const BIN_NAME = process.platform === 'win32' ? 'kupcad.exe' : 'kupcad';
const POSIX = process.platform !== 'win32';
const RANGE = '>=0.1.0 <0.2.0';

/** @type {string} */
let dir;
/** The version each executable says it is, by its path. @type {Map<string, string>} */
let versions;

/**
 * An executable at `relative` under the test's folder, saying it is `version`.
 * @param {string} relative
 * @param {string} version
 */
function kupcadAt(relative, version) {
  const file = path.join(dir, relative);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, '');
  fs.chmodSync(file, 0o755);
  versions.set(file, version);
  return file;
}

/** @param {string} file */
const probe = async (file) => {
  const version = versions.get(file);
  return version ? { version, protocolVersion: PROTOCOL_VERSION, os: 'test', arch: 'test' } : null;
};

/** A probe of kupcads that speak another protocol. @param {string} file */
const ofAnotherProtocol = async (file) => ({
  ...(await probe(file)),
  protocolVersion: PROTOCOL_VERSION + 1,
});

/** The options of a lookup in the test's folder, PATH the folders named. @param {object} more */
const options = (more = {}) => ({
  configured: '',
  managedDir: path.join(dir, 'storage', 'bin'),
  extensionPath: path.join(dir, 'packages', 'kupcad-vscode'),
  range: RANGE,
  probe,
  env: { PATH: '' },
  ...more,
});

/** @param {...string} dirs */
const pathEnv = (...dirs) => ({
  PATH: dirs.map((d) => path.join(dir, d)).join(path.delimiter),
  PATHEXT: '.EXE',
});

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kupcad-resolve-'));
  versions = new Map();
});
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

describe('findServer', () => {
  it("takes the setting's kupcad whatever its version, saying when it is out of range", async () => {
    const mine = kupcadAt(`mine/${BIN_NAME}`, '0.3.0');
    kupcadAt(`storage/bin/0.1.2/${BIN_NAME}`, '0.1.2');
    const { found, notes } = await findServer(options({ configured: mine }));
    expect(found).toEqual({ path: mine, version: '0.3.0', source: 'setting' });
    expect(notes).toEqual([
      `kupcad.serverPath (${mine}) is kupcad 0.3.0, of protocol version ${PROTOCOL_VERSION}; this extension runs ${RANGE}`,
    ]);
  });

  it("finds nothing else when the setting's isn't kupcad: the user chose it", async () => {
    kupcadAt(`storage/bin/0.1.2/${BIN_NAME}`, '0.1.2');
    const { found, notes } = await findServer(options({ configured: path.join(dir, 'missing') }));
    expect(found).toBeNull();
    expect(notes[0]).toMatch(/is no kupcad executable/);
  });

  it('expands ~ in the setting', async () => {
    const mine = kupcadAt(BIN_NAME, '0.1.0');
    const { found } = await findServer(
      options({ configured: `~/${BIN_NAME}`, env: { HOME: dir } }),
    );
    expect(found?.path).toBe(mine);
  });

  it('takes the newest of its own installs in range, before PATH and the monorepo build', async () => {
    kupcadAt(`storage/bin/0.1.2/${BIN_NAME}`, '0.1.2');
    const newest = kupcadAt(`storage/bin/0.1.10/${BIN_NAME}`, '0.1.10');
    kupcadAt(`storage/bin/0.2.0/${BIN_NAME}`, '0.2.0');
    kupcadAt(`onpath/${BIN_NAME}`, '0.1.5');
    const { found, notes } = await findServer(options({ env: pathEnv('onpath') }));
    expect(found).toEqual({ path: newest, version: '0.1.10', source: 'managed' });
    expect(notes).toEqual([expect.stringMatching(/0\.2\.0\/kupcad(\.exe)? is kupcad 0\.2\.0/)]);
  });

  it('passes over a kupcad on PATH out of range, or of another protocol, for the monorepo build', async () => {
    kupcadAt(`onpath/${BIN_NAME}`, '0.0.9');
    const development = kupcadAt(`core/zig-out/bin/${BIN_NAME}`, '0.1.0');
    const { found, notes } = await findServer(options({ env: pathEnv('onpath') }));
    expect(found).toEqual({ path: development, version: '0.1.0', source: 'development' });
    expect(notes).toHaveLength(1);

    const none = await findServer(options({ env: pathEnv('onpath'), probe: ofAnotherProtocol }));
    expect(none.found).toBeNull();
    expect(none.notes).toHaveLength(2);
  });

  it('finds nothing where there is nothing', async () => {
    expect(await findServer(options())).toEqual({ found: null, notes: [] });
  });
});

describe('findOnPath', () => {
  it.runIf(POSIX)('skips files on PATH that are not executable', () => {
    const plain = path.join(dir, 'plain');
    fs.mkdirSync(plain);
    fs.writeFileSync(path.join(plain, 'kupcad'), '');
    fs.chmodSync(path.join(plain, 'kupcad'), 0o644);
    const runnable = kupcadAt('bin/kupcad', '0.1.0');
    expect(findOnPath('kupcad', pathEnv('plain', 'bin'))).toBe(runnable);
    expect(findOnPath('kupcad', pathEnv('plain'))).toBeUndefined();
  });
});
