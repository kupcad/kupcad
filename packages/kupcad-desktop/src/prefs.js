// What the app keeps of the person's choices, by their keys in its settings, and how a kept
// one is read, as the settings may hold anything (an older app's, a hand-edited file's): the
// window's zoom, the editor's font size, the folders opened last.

/**
 * The app's keys in its settings (the view's are @kupcad/ui's `VIEW_KEYS`): the files' width and
 * the editor's, the theme, whether the console shows, the zoom, the editor's font size, whether
 * a script is saved as it is changed, whether the last folder opens at the start, the last
 * folder and the ones before it.
 */
export const KEYS = Object.freeze({
  files: 'app.files',
  editor: 'app.editor',
  theme: 'app.theme',
  console: 'app.console',
  zoom: 'app.zoom',
  fontSize: 'app.fontSize',
  autosave: 'app.autosave',
  reopen: 'app.reopen',
  folder: 'app.folder',
  recent: 'app.recent',
});

/** The window's zooms, as a browser steps them. */
export const ZOOMS = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2];
/** The editor's font sizes offered, in CSS pixels; the default is the page's own. */
export const FONT_SIZES = [11, 12, 13, 14, 15, 16, 18, 20];
export const DEFAULT_FONT_SIZE = 13;
/** How many folders the File menu's Open Recent offers. */
export const RECENT_MAX = 8;

/**
 * The zoom a kept setting names; none, or what isn't one, is 1.
 * @param {unknown} kept
 */
export function zoomOf(kept) {
  return ZOOMS.includes(/** @type {number} */ (kept)) ? /** @type {number} */ (kept) : 1;
}

/**
 * The zoom a step in (`by` 1) or out (-1) from `zoom` reaches; the last at either end stays.
 * @param {number} zoom
 * @param {1 | -1} by
 */
export function zoomStep(zoom, by) {
  const at = ZOOMS.indexOf(zoomOf(zoom));
  return ZOOMS[Math.min(ZOOMS.length - 1, Math.max(0, at + by))];
}

/**
 * The font size a kept setting names; none, or what isn't one offered, is the default.
 * @param {unknown} kept
 */
export function fontSizeOf(kept) {
  return FONT_SIZES.includes(/** @type {number} */ (kept))
    ? /** @type {number} */ (kept)
    : DEFAULT_FONT_SIZE;
}

/**
 * The folders opened last a kept setting names, the newest first: its strings, once each.
 * @param {unknown} kept
 * @returns {string[]}
 */
export function recentOf(kept) {
  if (!Array.isArray(kept)) return [];
  return [...new Set(kept.filter((path) => typeof path === 'string' && path !== ''))].slice(
    0,
    RECENT_MAX,
  );
}

/**
 * `recent` with `path` opened now: first, once, the oldest past the most dropped.
 * @param {string[]} recent
 * @param {string} path
 */
export function withRecent(recent, path) {
  return [path, ...recent.filter((kept) => kept !== path)].slice(0, RECENT_MAX);
}
