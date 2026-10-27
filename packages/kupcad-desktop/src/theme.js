// The window's theme, as the app's settings keep it: the system's (the default), light or dark.

/** @typedef {'system' | 'light' | 'dark'} Theme */

/** The themes, by their names in the settings, with their labels in the settings pane. */
export const THEMES = /** @type {const} */ ([
  ['system', 'System'],
  ['light', 'Light'],
  ['dark', 'Dark'],
]);

/**
 * The theme a kept setting names; none, or what isn't a theme, is the system's.
 * @param {unknown} kept
 * @returns {Theme}
 */
export function themeOf(kept) {
  return THEMES.some(([name]) => name === kept) ? /** @type {Theme} */ (kept) : 'system';
}
