// The viewer webview's HTML: the built page (dist-webview/index.html) with a strict Content
// Security Policy, its scripts nonced, its assets' URLs the webview's, and the viewport socket's
// URL in a meta tag. Free of the `vscode` import, so it is tested without VS Code.

import * as crypto from 'node:crypto';

/** Where the language server's viewport socket listens. */
export const VIEWPORT_HOST = '127.0.0.1';
const NONCE_BYTES = 16;

export const createNonce = () => crypto.randomBytes(NONCE_BYTES).toString('base64');

/** The socket the viewer connects to, at `port`. @param {number} port */
export const viewportUrl = (port) => `ws://${VIEWPORT_HOST}:${port}`;

/**
 * Strict CSP: no inline script but the nonced ones, no eval, and the network only to the
 * viewport socket, once its port is known. The page's own modules (`cspSource`, which
 * localResourceRoots holds to the built page) load too: a module a script imports isn't
 * covered by the script's nonce.
 * @param {{ cspSource: string, nonce: string, viewportPort: number | undefined }} options
 * @returns {string}
 */
export const buildCsp = ({ cspSource, nonce, viewportPort }) =>
  [
    "default-src 'none'",
    `img-src ${cspSource} data: blob:`,
    `font-src ${cspSource}`,
    `style-src ${cspSource}`,
    `script-src 'nonce-${nonce}' ${cspSource}`,
    `connect-src ${viewportPort ? viewportUrl(viewportPort) : "'none'"}`,
  ].join('; ');

/** @param {unknown} s */
const escapeAttr = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');

/**
 * Injects the CSP + viewport port meta tags, adds the nonce to every <script>, and rewrites
 * relative asset URLs through `toWebviewUri` (webviews cannot load file paths directly).
 * @param {string} html
 * @param {{ csp: string, nonce: string, viewportPort: number | undefined, toWebviewUri?: (rel: string) => string }} options
 * @returns {string}
 */
export const prepareWebviewHtml = (html, { csp, nonce, viewportPort, toWebviewUri }) => {
  let out = html;
  if (toWebviewUri) {
    out = out.replace(
      /(<(?:script|link|img)\b[^>]*?\s(?:src|href)=")(?!https?:|data:|#)([^"]+)(")/gi,
      (_, /** @type {string} */ pre, /** @type {string} */ url, /** @type {string} */ post) =>
        `${pre}${toWebviewUri(url.replace(/^\.?\//, ''))}${post}`,
    );
  }
  out = out.replace(/<script\b(?![^>]*\snonce=)/gi, `<script nonce="${nonce}"`);

  const meta =
    `<meta http-equiv="Content-Security-Policy" content="${escapeAttr(csp)}">` +
    `<meta name="kupcad-viewport" content="${escapeAttr(viewportPort ? viewportUrl(viewportPort) : '')}">`;
  if (/<head[^>]*>/i.test(out)) return out.replace(/<head[^>]*>/i, (m) => `${m}${meta}`);
  return `<!DOCTYPE html><html><head>${meta}</head><body>${out}</body></html>`;
};
