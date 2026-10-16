// Pure helpers for the viewer webview and server discovery. Kept free of the `vscode`
// import so they can be unit tested with vitest.
import * as fs from 'fs';
import * as path from 'path';
import * as crypto from 'crypto';

export const DEV_SERVER_ORIGIN = 'http://localhost:5173';
export const VIEWPORT_HOST = '127.0.0.1';
export const VIEWPORT_READY_NOTIFICATION = 'kupcad/viewportReady';
export const VIEWPORT_PORT_ENV = 'KUPCAD_VIEWPORT_PORT';

export const createNonce = () => crypto.randomBytes(16).toString('base64');

/**
 * Strict CSP: no inline script except the nonce'd ones, no eval, network only to the
 * local viewport socket (and the Vite dev server in development).
 */
export const buildCsp = ({ cspSource, nonce, viewportPort, isDev }) => {
	const connect = [];
	if (viewportPort) connect.push(`ws://${VIEWPORT_HOST}:${viewportPort}`);
	const scriptSrc = [`'nonce-${nonce}'`];
	const styleSrc = [cspSource];
	if (isDev) {
		scriptSrc.push(DEV_SERVER_ORIGIN);
		styleSrc.push(DEV_SERVER_ORIGIN, "'unsafe-inline'"); // Vite injects <style> during HMR
		connect.push(DEV_SERVER_ORIGIN, DEV_SERVER_ORIGIN.replace(/^http/, 'ws'));
	}
	return [
		"default-src 'none'",
		`img-src ${cspSource} data: blob:`,
		`font-src ${cspSource}`,
		`style-src ${styleSrc.join(' ')}`,
		`script-src ${scriptSrc.join(' ')}`,
		`connect-src ${connect.length ? connect.join(' ') : "'none'"}`,
		"worker-src blob:",
	].join('; ');
};

const escapeAttr = (s) => String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');

/**
 * Injects the CSP + viewport port meta tags, adds the nonce to every <script>, and rewrites
 * relative asset URLs through `toWebviewUri` (webviews cannot load file paths directly).
 */
export const prepareWebviewHtml = (html, { csp, nonce, viewportPort, toWebviewUri }) => {
	let out = html;
	if (toWebviewUri) {
		out = out.replace(/(<(?:script|link|img)\b[^>]*?\s(?:src|href)=")(?!https?:|data:|#)([^"]+)(")/gi,
			(_, pre, url, post) => `${pre}${toWebviewUri(url.replace(/^\.?\//, ''))}${post}`);
	}
	out = out.replace(/<script\b(?![^>]*\snonce=)/gi, `<script nonce="${nonce}"`);

	const meta = `<meta http-equiv="Content-Security-Policy" content="${escapeAttr(csp)}">` +
		`<meta name="kupcad-viewport" content="${escapeAttr(viewportPort ? `ws://${VIEWPORT_HOST}:${viewportPort}` : '')}">`;
	if (/<head[^>]*>/i.test(out)) return out.replace(/<head[^>]*>/i, (m) => `${m}${meta}`);
	return `<!DOCTYPE html><html><head>${meta}</head><body>${out}</body></html>`;
};

export const devWebviewHtml = () => `<!DOCTYPE html>
<html>
  <head></head>
  <body>
    <div id="root"></div>
    <script type="module" src="${DEV_SERVER_ORIGIN}/src/main.tsx"></script>
  </body>
</html>`;

const isExecutable = (p) => {
	try {
		const st = fs.statSync(p);
		if (!st.isFile()) return false;
		if (process.platform === 'win32') return true;
		fs.accessSync(p, fs.constants.X_OK);
		return true;
	} catch {
		return false;
	}
};

/** Looks `name` up on PATH (adds PATHEXT suffixes on Windows). */
export const findOnPath = (name, env = process.env) => {
	const dirs = (env.PATH || env.Path || '').split(path.delimiter).filter(Boolean);
	const exts = process.platform === 'win32' ? (env.PATHEXT || '.EXE;.CMD').split(';') : [''];
	for (const dir of dirs) {
		for (const ext of exts) {
			const candidate = path.join(dir, name + ext);
			if (isExecutable(candidate)) return candidate;
		}
	}
	return undefined;
};

/**
 * Server resolution order: explicit `kupcad.serverPath` setting, `kupcad` on PATH, then the
 * monorepo dev build (only exists when running the extension from a source checkout).
 */
export const resolveServerPath = ({ configured, extensionPath, env = process.env }) => {
	if (configured) {
		const expanded = configured.replace(/^~(?=$|[\\/])/, env.HOME || env.USERPROFILE || '~');
		return isExecutable(expanded) ? expanded : undefined;
	}
	const onPath = findOnPath('kupcad', env);
	if (onPath) return onPath;
	const devPath = path.resolve(extensionPath, '../../core/zig-out/bin/kupcad');
	return isExecutable(devPath) ? devPath : undefined;
};
