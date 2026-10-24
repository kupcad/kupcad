import { describe, expect, it } from 'vitest';
import { buildCsp, createNonce, prepareWebviewHtml } from './webview-html.js';

const NONCE_BYTES = 16;

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
  it('is strict and scoped to the reported viewport port', () => {
    const d = cspDirectives(
      buildCsp({ cspSource: 'vscode-resource:', nonce: 'abc', viewportPort: 51234 }),
    );
    expect(d['default-src']).toEqual(["'none'"]);
    expect(d['script-src']).toEqual(["'nonce-abc'", 'vscode-resource:']);
    expect(d['style-src']).toEqual(['vscode-resource:']);
    expect(d['connect-src']).toEqual(['ws://127.0.0.1:51234']);
    const all = Object.values(d).flat();
    expect(all).not.toContain("'unsafe-eval'");
    expect(all).not.toContain("'unsafe-inline'");
    expect(d['worker-src']).toBeUndefined();
  });

  it('blocks all connections until the viewport port is known', () => {
    const d = cspDirectives(buildCsp({ cspSource: 'x:', nonce: 'n', viewportPort: undefined }));
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
