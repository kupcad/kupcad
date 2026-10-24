// The viewer's theme from the --kc-viewer-* tokens of the page around it: a host themes the
// viewer as it themes the panels, and changes it while it shows (VS Code's theme switch). A
// token left unset takes the viewer's own colour, LIGHT or DARK as the page's colour scheme is.

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
/** The attributes of the page's root and body a host themes it by (VS Code: a class, a style). */
const THEMED_BY = ['class', 'style'];

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
  for (const [key, token] of /** @type {[keyof Theme, string][]} */ (Object.entries(TOKENS))) {
    theme[key] = opaque(style.getPropertyValue(token).trim()) || fallback[key];
  }
  return theme;
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
 * `color` without the alpha of a hex colour that has one: a theme's colours are opaque.
 * @param {string} color
 */
function opaque(color) {
  return color.replace(HEX_WITH_ALPHA, (_, short, long) => short ?? long);
}
