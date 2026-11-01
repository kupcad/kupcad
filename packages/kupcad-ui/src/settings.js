// What a person set in a host's panels (the panes' sizes, whether they show), kept where the
// host keeps such things. The playground keeps it in the page's localStorage (localSettings),
// the VS Code extension and the desktop app their own way, each on keptSettings (memorySettings
// that tell the host each change); a host that keeps nothing gives memorySettings alone.
//
// Settings are reactive: a pane reads its value in a $derived, and follows it as it is set,
// wherever from. A size dragged is the pane's own until the drag is done, and set then, once.
// A key not kept yet is followed as the map is (a SvelteMap's reader of a key it doesn't hold
// reads again as any key is added): a size never kept, mid-drag as another key is kept for the
// first time, goes back to its own. Svelte doesn't let a reaction follow state it made itself,
// so a cell of a key's own, made as the key is first read, would never be followed.

import { SvelteMap } from 'svelte/reactivity';

/**
 * A host's settings, by key: what `get` reads in a reaction (a $derived, an effect, the markup)
 * it reads again when `set` changes it. A host's own are built on `memorySettings`.
 * @typedef {object} Settings
 * @property {(key: string) => unknown} get the value kept for `key`; undefined for none
 * @property {(key: string, value: unknown) => void} set keeps `value` for `key`
 */

/**
 * Settings kept in memory alone, from `values`: gone with the page.
 * @param {Record<string, unknown>} [values]
 * @returns {Settings}
 */
export function memorySettings(values = {}) {
  const kept = new SvelteMap(Object.entries(values));
  return { get: (key) => kept.get(key), set: (key, value) => void kept.set(key, value) };
}

/**
 * Settings a host keeps: `memorySettings` from `values`, the host told each change through
 * `keep` (the VS Code extension's page sends it to the extension, the desktop app writes it to
 * its settings file). Each host wrapped memorySettings this way itself.
 * @param {Record<string, unknown>} values what the host kept
 * @param {(key: string, value: unknown) => void} keep
 * @returns {Settings}
 */
export function keptSettings(values, keep) {
  const settings = memorySettings(values);
  return {
    get: settings.get,
    set(key, value) {
      settings.set(key, value);
      keep(key, value);
    },
  };
}

/**
 * Settings kept in `storage` (the page's localStorage) as one JSON object under `name`. A page
 * that may not keep anything there (a private window's quota, a policy), or finds no JSON
 * object under the name, keeps them in memory for the page's life.
 * @param {string} [name]
 * @param {Pick<Storage, 'getItem' | 'setItem'> | undefined} [storage]
 * @returns {Settings}
 */
export function localSettings(name = 'kupcad.settings', storage = globalThis.localStorage) {
  const read = () => {
    try {
      return settingsObject(storage?.getItem(name));
    } catch {
      return {};
    }
  };
  return keptSettings(read(), (key, value) => {
    try {
      storage?.setItem(name, JSON.stringify({ ...read(), [key]: value }));
    } catch {
      // Kept in memory: the page may not store anything
    }
  });
}

/**
 * The settings `text` holds as JSON: its object; an empty one for no text, text that isn't
 * JSON, or JSON that isn't an object (the extension's page and the playground each read it so).
 * @param {string | null | undefined} text
 * @returns {Record<string, unknown>}
 */
export function settingsObject(text) {
  try {
    const parsed = JSON.parse(text || '{}');
    return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

/**
 * The keys a preview panel keeps its layout under, each with `prefix` (the preview's are
 * `preview.params`, the playground's `playground.params`): the parameters pane's width, whether
 * it and the panel show, the console's height and whether it is open. Two panels listed them.
 * @param {string} prefix
 */
export const paneKeys = (prefix) => ({
  params: `${prefix}.params`,
  paramsOpen: `${prefix}.paramsOpen`,
  panelOpen: `${prefix}.panelOpen`,
  console: `${prefix}.console`,
  open: `${prefix}.consoleOpen`,
});

/**
 * A pane's size kept under `key`: a finite number of pixels, else `fallback` (none kept, or
 * what was kept is no size).
 * @param {Settings} settings
 * @param {string} key
 * @param {number} fallback
 */
export function sizeSetting(settings, key, fallback) {
  const kept = settings.get(key);
  return typeof kept === 'number' && Number.isFinite(kept) && kept > 0 ? kept : fallback;
}
