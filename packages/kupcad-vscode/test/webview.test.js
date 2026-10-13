import { describe, it, expect } from 'vitest';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { buildCsp, prepareWebviewHtml, findOnPath, resolveServerPath } from '../src/webview.js';

describe('webview CSP', () => {
	it('is strict and scoped to the reported viewport port', () => {
		const csp = buildCsp({ cspSource: 'vscode-resource:', nonce: 'abc', viewportPort: 51234, isDev: false });
		expect(csp).toContain("default-src 'none'");
		expect(csp).toContain("script-src 'nonce-abc'");
		expect(csp).toContain('connect-src ws://127.0.0.1:51234');
		expect(csp).not.toContain('unsafe-eval');
		expect(csp).not.toContain('localhost:5173');
	});

	it('injects CSP, nonces scripts and rewrites bundled asset URLs', () => {
		const html = '<!doctype html><html><head><script type="module" src="/assets/index.js"></script>' +
			'<link rel="stylesheet" href="./assets/index.css"></head><body></body></html>';
		const out = prepareWebviewHtml(html, {
			csp: "default-src 'none'", nonce: 'n1', viewportPort: 9001,
			toWebviewUri: (rel) => `https://webview/${rel}`,
		});
		expect(out).toContain('http-equiv="Content-Security-Policy"');
		expect(out).toContain('<script nonce="n1" type="module" src="https://webview/assets/index.js">');
		expect(out).toContain('href="https://webview/assets/index.css"');
		expect(out).toContain('content="ws://127.0.0.1:9001"');
	});

	it('produces a non-empty document for an empty bundle', () => {
		const out = prepareWebviewHtml('', { csp: "default-src 'none'", nonce: 'n', viewportPort: undefined });
		expect(out).toContain('<head><meta http-equiv="Content-Security-Policy"');
	});
});

describe('server path resolution', () => {
	it('prefers the configured path, then PATH', () => {
		const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kupcad-'));
		const bin = path.join(dir, process.platform === 'win32' ? 'kupcad.EXE' : 'kupcad');
		fs.writeFileSync(bin, '');
		fs.chmodSync(bin, 0o755);
		try {
			expect(resolveServerPath({ configured: bin, extensionPath: '/nonexistent' })).toBe(bin);
			expect(findOnPath('kupcad', { PATH: dir, PATHEXT: '.EXE' })).toBe(bin);
			expect(resolveServerPath({ configured: '', extensionPath: '/nonexistent/a/b', env: { PATH: dir, PATHEXT: '.EXE' } })).toBe(bin);
			expect(resolveServerPath({ configured: path.join(dir, 'missing'), extensionPath: '/x' })).toBeUndefined();
		} finally {
			fs.rmSync(dir, { recursive: true, force: true });
		}
	});
});
