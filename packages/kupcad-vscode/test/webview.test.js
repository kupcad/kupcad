import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import {
  buildCsp,
  createNonce,
  prepareWebviewHtml,
  findOnPath,
  resolveServerPath,
  DEV_SERVER_ORIGIN,
} from '../src/webview.js';

const NONCE_BYTES = 16;
const BIN_NAME = process.platform === 'win32' ? 'kupcad.EXE' : 'kupcad';
const POSIX = process.platform !== 'win32';

/**
 * A CSP's directives by name.
 * @param {string} csp
 * @returns {Record<string, string[]>}
 */
const cspDirectives = (csp) =>
  Object.fromEntries(
    csp.split('; ').map((d) => {
      const [name, ...values] = d.split(' ');
      return [name, values];
    }),
  );

describe('webview CSP', () => {
  it('is strict and scoped to the reported viewport port in production', () => {
    const d = cspDirectives(
      buildCsp({ cspSource: 'vscode-resource:', nonce: 'abc', viewportPort: 51234, isDev: false }),
    );
    expect(d['default-src']).toEqual(["'none'"]);
    expect(d['script-src']).toEqual(["'nonce-abc'"]);
    expect(d['style-src']).toEqual(['vscode-resource:']);
    expect(d['connect-src']).toEqual(['ws://127.0.0.1:51234']);
    const all = Object.values(d).flat();
    expect(all).not.toContain("'unsafe-eval'");
    expect(all).not.toContain("'unsafe-inline'");
    expect(all).not.toContain(DEV_SERVER_ORIGIN);
  });

  it('allows the Vite dev server only in development', () => {
    const d = cspDirectives(
      buildCsp({ cspSource: 'vscode-resource:', nonce: 'abc', viewportPort: 9001, isDev: true }),
    );
    expect(d['script-src']).toEqual(["'nonce-abc'", DEV_SERVER_ORIGIN]);
    expect(d['style-src']).toContain("'unsafe-inline'");
    expect(d['connect-src']).toEqual([
      'ws://127.0.0.1:9001',
      DEV_SERVER_ORIGIN,
      'ws://localhost:5173',
    ]);
  });

  it('blocks all connections until the viewport port is known', () => {
    const d = cspDirectives(
      buildCsp({ cspSource: 'x:', nonce: 'n', viewportPort: undefined, isDev: false }),
    );
    expect(d['connect-src']).toEqual(["'none'"]);
  });

  it('creates fresh base64 nonces of the expected size', () => {
    const a = createNonce();
    expect(Buffer.from(a, 'base64')).toHaveLength(NONCE_BYTES);
    expect(createNonce()).not.toBe(a);
  });
});

describe('webview HTML', () => {
  it('injects CSP, nonces scripts and rewrites bundled asset URLs', () => {
    const html =
      '<!doctype html><html><head><script type="module" src="/assets/index.js"></script>' +
      '<link rel="stylesheet" href="./assets/index.css"></head><body></body></html>';
    const out = prepareWebviewHtml(html, {
      csp: "default-src 'none'",
      nonce: 'n1',
      viewportPort: 9001,
      toWebviewUri: (rel) => `https://webview/${rel}`,
    });
    expect(out).toContain('<head><meta http-equiv="Content-Security-Policy"');
    expect(out).toContain(
      '<script nonce="n1" type="module" src="https://webview/assets/index.js">',
    );
    expect(out).toContain('href="https://webview/assets/index.css"');
    expect(out).toContain('<meta name="kupcad-viewport" content="ws://127.0.0.1:9001">');
  });

  it('leaves absolute/data URLs and existing nonces alone', () => {
    const html =
      '<head></head><script nonce="keep" src="https://cdn.example/a.js"></script><img src="data:image/png;base64,AA">';
    const out = prepareWebviewHtml(html, {
      csp: 'c',
      nonce: 'n',
      viewportPort: 1,
      toWebviewUri: () => 'REWRITTEN',
    });
    expect(out).not.toContain('REWRITTEN');
    expect(out).toContain('<script nonce="keep" src="https://cdn.example/a.js">');
    expect(out).not.toContain('nonce="n"');
  });

  it('escapes the CSP attribute and wraps a bundle without <head>', () => {
    const out = prepareWebviewHtml('<p>missing</p>', {
      csp: `a "b" <c> &`,
      nonce: 'n',
      viewportPort: undefined,
    });
    expect(out).toMatch(
      /^<!DOCTYPE html><html><head><meta http-equiv="Content-Security-Policy" content="a &quot;b&quot; &lt;c> &amp;">/,
    );
    expect(out).toContain('<meta name="kupcad-viewport" content="">');
    expect(out).toContain('<body><p>missing</p></body>');
  });
});

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
