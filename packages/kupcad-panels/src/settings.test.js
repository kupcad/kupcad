import { describe, expect, it } from 'vitest';
import { localSettings, memorySettings, sizeSetting } from './settings.js';

/** A stand-in for localStorage, which can be made to refuse what it is given. */
function storageOf(items = /** @type {Record<string, string>} */ ({})) {
  const kept = new Map(Object.entries(items));
  return {
    full: false,
    getItem: (/** @type {string} */ key) => kept.get(key) ?? null,
    /** @param {string} key @param {string} value */
    setItem(key, value) {
      if (this.full) throw new Error('QuotaExceededError');
      kept.set(key, value);
    },
  };
}

describe('settings', () => {
  it('in memory keep what they are given for the page', () => {
    const settings = memorySettings({ 'preview.params': 300 });
    expect(settings.get('preview.params')).toBe(300);
    settings.set('preview.console', 200);
    expect(settings.get('preview.console')).toBe(200);
  });

  it('in localStorage are one JSON object, read back by the next page', () => {
    const storage = storageOf();
    localSettings('kc', storage).set('playground.editor', 500);
    localSettings('kc', storage).set('playground.params', 260);
    const next = localSettings('kc', storage);
    expect([next.get('playground.editor'), next.get('playground.params')]).toEqual([500, 260]);
    expect(JSON.parse(storage.getItem('kc') ?? '')).toEqual({
      'playground.editor': 500,
      'playground.params': 260,
    });
  });

  it('a page that may not store keeps them in memory, and what is no JSON object is none', () => {
    const storage = storageOf({ kc: '[1, 2]' });
    const settings = localSettings('kc', storage);
    expect(settings.get('0')).toBeUndefined();
    storage.full = true;
    settings.set('playground.editor', 500);
    expect(settings.get('playground.editor')).toBe(500);
    expect(localSettings('kc', storageOf({ kc: '{not json' })).get('x')).toBeUndefined();
    // No storage at all (a sandboxed page)
    const none = localSettings('kc', undefined);
    none.set('x', 1);
    expect(none.get('x')).toBe(1);
  });

  it("read a size as a positive finite number, else the pane's own", () => {
    const settings = memorySettings({ a: 320, b: 'wide', c: -5, d: Number.NaN });
    expect(['a', 'b', 'c', 'd', 'e'].map((key) => sizeSetting(settings, key, 100))).toEqual([
      320, 100, 100, 100, 100,
    ]);
  });
});
