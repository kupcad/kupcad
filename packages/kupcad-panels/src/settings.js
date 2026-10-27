// What a person set in a host's panels (the panes' sizes, whether they show), kept where the
// host keeps such things. The playground keeps it in the page's localStorage (localSettings),
// the VS Code extension and the desktop app their own way, each on memorySettings; a host that
// keeps nothing gives memorySettings alone.
//
// Settings are reactive: a pane reads its value in a $derived, and follows it as it is set,
// wherever from. A size dragged is the pane's own until the drag is done, and set then, once.

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
 * Settings kept in `storage` (the page's localStorage) as one JSON object under `name`. A page
 * that may not keep anything there (a private window's quota, a policy), or finds no JSON
 * object under the name, keeps them in memory for the page's life.
 * @param {string} [name]
 * @param {Pick<Storage, 'getItem' | 'setItem'> | undefined} [storage]
 * @returns {Settings}
 */
export function localSettings(name = 'kupcad.settings', storage = globalThis.localStorage) {
  const settings = memorySettings(read(storage, name));
  return {
    get: settings.get,
    set(key, value) {
      settings.set(key, value);
      try {
        const all = { ...read(storage, name), [key]: value };
        storage?.setItem(name, JSON.stringify(all));
      } catch {
        // Kept in memory: the page may not store anything
      }
    },
  };
}

/**
 * The JSON object `storage` keeps under `name`; an empty one for none, or for what isn't one.
 * @param {Pick<Storage, 'getItem'> | undefined} storage
 * @param {string} name
 * @returns {Record<string, unknown>}
 */
function read(storage, name) {
  try {
    const parsed = JSON.parse(storage?.getItem(name) ?? '{}');
    return typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

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
