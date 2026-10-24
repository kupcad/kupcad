// The viewer's theme from the --kc-viewer-* tokens of the page around it: a host themes the
// viewer as it themes the panels. A token left unset takes the viewer's own colour, LIGHT or
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
    theme[key] = style.getPropertyValue(token).trim() || fallback[key];
  }
  return theme;
}
