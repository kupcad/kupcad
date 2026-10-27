import { describe, expect, it } from 'vitest';
import {
  DEFAULT_FONT_SIZE,
  fontSizeOf,
  RECENT_MAX,
  recentOf,
  withRecent,
  zoomOf,
  zoomStep,
} from './prefs.js';

describe('the zoom', () => {
  it('steps in and out as a browser does, stopping at either end', () => {
    expect([zoomStep(1, 1), zoomStep(1, -1), zoomStep(1.1, -1)]).toEqual([1.1, 0.9, 1]);
    expect([zoomStep(2, 1), zoomStep(0.5, -1)]).toEqual([2, 0.5]);
  });

  it("reads what isn't one of its steps as 1", () => {
    expect([zoomOf(1.25), zoomOf(1.3), zoomOf('2'), zoomOf(undefined)]).toEqual([1.25, 1, 1, 1]);
    expect(zoomStep(/** @type {number} */ (/** @type {unknown} */ ('big')), 1)).toBe(1.1);
  });
});

it("reads the editor's font size as one offered, else the default", () => {
  expect([fontSizeOf(16), fontSizeOf(17), fontSizeOf('16'), fontSizeOf(null)]).toEqual([
    16,
    DEFAULT_FONT_SIZE,
    DEFAULT_FONT_SIZE,
    DEFAULT_FONT_SIZE,
  ]);
});

describe('the folders opened last', () => {
  it('are read as their paths, once each, the newest first', () => {
    expect(recentOf(['/a', 7, '', '/b', '/a'])).toEqual(['/a', '/b']);
    expect([recentOf('/a'), recentOf(undefined)]).toEqual([[], []]);
  });

  it('take a folder opened first, once, the oldest dropped past the most', () => {
    expect(withRecent(['/a', '/b'], '/b')).toEqual(['/b', '/a']);
    const many = Array.from({ length: RECENT_MAX }, (_, i) => `/f${i}`);
    expect(withRecent(many, '/new')).toEqual(['/new', ...many.slice(0, RECENT_MAX - 1)]);
  });
});
