import { flushSync } from 'svelte';
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

  it('are read again where they are read in a reaction as they are set: that key alone', () => {
    const settings = memorySettings({ 'a.size': 300 });
    /** @type {unknown[]} */
    const read = [];
    const stop = $effect.root(() => {
      $effect(() => {
        read.push(settings.get('a.size'));
      });
    });
    flushSync();
    settings.set('a.size', 320);
    flushSync();
    // Another key, new or not, and the same value again, aren't this one's change
    settings.set('b.open', false);
    settings.set('a.size', 320);
    flushSync();
    expect(read).toEqual([300, 320]);
    stop();
  });

  it('in localStorage are reactive too, a key kept only later as well', () => {
    const settings = localSettings('kc', storageOf());
    const size = $derived(sizeSetting(settings, 'playground.editor', 460));
    /** @type {number[]} */
    const read = [];
    const stop = $effect.root(() => {
      $effect(() => {
        read.push(size);
      });
    });
    flushSync();
    settings.set('playground.editor', 500);
    flushSync();
    expect(read).toEqual([460, 500]);
    stop();
  });

  it("read a size as a positive finite number, else the pane's own", () => {
    const settings = memorySettings({ a: 320, b: 'wide', c: -5, d: Number.NaN });
    expect(['a', 'b', 'c', 'd', 'e'].map((key) => sizeSetting(settings, key, 100))).toEqual([
      320, 100, 100, 100, 100,
    ]);
  });
});
