// The viewer's theme from the --kc-viewer-* tokens of the page around it: a host themes the
// viewer as it themes the panels, and changes it while it shows (VS Code's theme switch). A
// token left unset, or set to no colour the page reads, takes the viewer's own colour, LIGHT or
// DARK as the page's colour scheme is.

import { DARK, LIGHT } from '@kupcad/viewer';

/** @import { Theme } from '@kupcad/viewer/types' */

/** Each colour of a viewer's theme, by the token that sets it. */
const TOKENS = /** @type {const} */ ({
  background: '--kc-viewer-background',
  grid: '--kc-viewer-grid',
  plate: '--kc-viewer-plate',
  edges: '--kc-viewer-edges',
  selection: '--kc-viewer-selection',
  cap: '--kc-viewer-cap',
  ghost: '--kc-viewer-ghost',
});
/** A hex colour with an alpha (#rgba, #rrggbbaa), which three.js can't read: its colour first. */
const HEX_WITH_ALPHA = /^(#[\da-f]{3})[\da-f]$|^(#[\da-f]{6})[\da-f]{2}$/i;
/** An rgba() colour: three.js reads it, warning of the alpha it leaves out. */
const RGBA = /^rgba\((\d+),\s*(\d+),\s*(\d+),\s*[\d.]+\)$/;
/** Two fills a colour the browser can't read leaves as they were: it reads as neither. */
const UNREAD = /** @type {const} */ (['#000000', '#ffffff']);
/** The attributes of the page's root and body a host themes it by (VS Code: a class, a style). */
const THEMED_BY = ['class', 'style'];

/** colorReader's, once made (null where the page has no 2D context). @type {ColorReader | null | undefined} */
let reader;

/**
 * What of a 2D context reads a colour: its fill, and the pixel it draws.
 * @typedef {Pick<CanvasRenderingContext2D, 'fillStyle' | 'clearRect' | 'fillRect' | 'getImageData'>} ColorReader
 */

/**
 * The theme the tokens set on `element` (inherited from the page) give.
 * @param {Element} element
 * @returns {Theme}
 */
export function themeFromTokens(element) {
  const style = getComputedStyle(element);
  const dark = globalThis.matchMedia?.('(prefers-color-scheme: dark)').matches ?? false;
  const fallback = dark ? DARK : LIGHT;
  /** @type {Theme} */
  const theme = { ...fallback };
  const context = colorReader();
  for (const [key, token] of /** @type {[keyof Theme, string][]} */ (Object.entries(TOKENS))) {
    theme[key] = viewerColor(style.getPropertyValue(token).trim(), context) || fallback[key];
  }
  return theme;
}

/**
 * `color` as the viewer can draw it: #rrggbb, the sRGB of a pixel `context` draws in it, so any
 * CSS colour the browser reads (three.js reads hex, rgb() and a name alone: a color-mix() or an
 * oklch() it drew black, and a context's fill keeps those as they are), and opaque, a theme's
 * colours being so; empty for one the browser doesn't read. Without a context (jsdom), the
 * colour as given, opaque.
 * @param {string} color
 * @param {ColorReader | null} context
 * @returns {string}
 */
export function viewerColor(color, context) {
  if (!color || !context) return opaque(color);
  const fills = UNREAD.map((unread) => {
    context.fillStyle = unread;
    context.fillStyle = color;
    return String(context.fillStyle);
  });
  if (fills[0] !== fills[1]) return '';
  context.clearRect(0, 0, 1, 1);
  context.fillRect(0, 0, 1, 1);
  const [r, g, b] = context.getImageData(0, 0, 1, 1).data;
  return `#${[r, g, b].map((byte) => byte.toString(16).padStart(2, '0')).join('')}`;
}

/**
 * What reads a CSS colour as the page does: a 2D context, made once; null where the page has
 * none.
 * @returns {ColorReader | null}
 */
function colorReader() {
  if (reader === undefined) {
    reader = document.createElement('canvas').getContext('2d', { willReadFrequently: true });
  }
  return reader;
}

/**
 * Gives `changed` the theme of `element`'s tokens now, and again whenever it changes: with the
 * page's colour scheme, or a class or style of its root or body.
 * @param {Element} element
 * @param {(theme: Theme) => void} changed
 * @returns {() => void} stops watching
 */
export function watchTokens(element, changed) {
  let last = '';
  const update = () => {
    const theme = themeFromTokens(element);
    const key = JSON.stringify(theme);
    if (key === last) return;
    last = key;
    changed(theme);
  };
  const observer = new MutationObserver(update);
  for (const node of [document.documentElement, document.body]) {
    observer.observe(node, { attributes: true, attributeFilter: THEMED_BY });
  }
  const scheme = globalThis.matchMedia?.('(prefers-color-scheme: dark)');
  scheme?.addEventListener('change', update);
  update();
  return () => {
    observer.disconnect();
    scheme?.removeEventListener('change', update);
  };
}

/**
 * `color` without the alpha of a hex or an rgba() colour that has one: a theme's colours are
 * opaque.
 * @param {string} color
 */
function opaque(color) {
  return color
    .replace(HEX_WITH_ALPHA, (_, short, long) => short ?? long)
    .replace(RGBA, (_, r, g, b) => `rgb(${r}, ${g}, ${b})`);
}
