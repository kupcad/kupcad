import { describe, expect, it } from 'vitest';
import { ZOOM_STEP } from './camera.js';
import { wheelGesture } from './wheel.js';

/** @import { WheelGesture } from './wheel.js' */

const PAGE_PX = 600;

/**
 * What a turn of the wheel by `deltaY` (and `more`) does.
 * @param {number} deltaY
 * @param {Partial<WheelEvent>} [more]
 * @returns {WheelGesture | null}
 */
const turn = (deltaY, more = {}) =>
  wheelGesture(
    {
      deltaX: 0,
      deltaY,
      deltaMode: WheelEvent.DOM_DELTA_PIXEL,
      buttons: 0,
      shiftKey: false,
      metaKey: false,
      altKey: false,
      ctrlKey: false,
      ...more,
    },
    PAGE_PX,
  );

/** @param {WheelGesture | null} gesture */
const factorOf = (gesture) => (gesture?.kind === 'zoom' ? gesture.factor : Number.NaN);

describe('a turn of the wheel', () => {
  it('zooms in turned up (away), out turned down, by as much as it turned', () => {
    expect(factorOf(turn(-100))).toBeCloseTo(1 / 0.95, 9);
    expect(factorOf(turn(100))).toBeCloseTo(0.95, 9);
    expect(factorOf(turn(-200))).toBeCloseTo(1 / 0.95 ** 2, 9);
  });

  it('counts lines and pages as the pixels they scroll', () => {
    expect(factorOf(turn(-1, { deltaMode: WheelEvent.DOM_DELTA_LINE }))).toBeCloseTo(
      factorOf(turn(-16)),
      12,
    );
    expect(factorOf(turn(0.1, { deltaMode: WheelEvent.DOM_DELTA_PAGE }))).toBeCloseTo(
      factorOf(turn(0.1 * PAGE_PX)),
      12,
    );
  });

  it('zooms with a pinch (Ctrl, as a browser sends it) ten times as fast, a step at most', () => {
    expect(factorOf(turn(-5, { ctrlKey: true }))).toBeCloseTo(factorOf(turn(-50)), 12);
    expect(factorOf(turn(-10_000))).toBeCloseTo(ZOOM_STEP, 12);
    expect(factorOf(turn(10_000, { ctrlKey: true }))).toBeCloseTo(1 / ZOOM_STEP, 12);
  });

  it('pans with Shift, turns the view with Cmd, moves the section with Option', () => {
    expect(turn(30, { deltaX: -10, shiftKey: true })).toEqual({ kind: 'pan', x: -10, y: 30 });
    expect(turn(30, { deltaX: -10, metaKey: true })).toEqual({ kind: 'orbit', x: -10, y: 30 });
    expect(turn(30, { altKey: true })).toEqual({ kind: 'section', y: 30 });
    expect(turn(-2, { altKey: true, deltaMode: WheelEvent.DOM_DELTA_LINE })).toEqual({
      kind: 'section',
      y: -32,
    });
    // Shift first, then Cmd, then Option
    expect(turn(30, { shiftKey: true, metaKey: true, altKey: true })?.kind).toBe('pan');
    expect(turn(30, { metaKey: true, altKey: true })?.kind).toBe('orbit');
  });

  it('does nothing with the middle button held, nor where it turned no way that counts', () => {
    expect(turn(-100, { buttons: 4 })).toBeNull();
    expect(turn(-100, { buttons: 1 })?.kind).toBe('zoom');
    expect(turn(-100, { buttons: 2 })?.kind).toBe('zoom');
    expect(turn(0, { deltaX: 40 })).toBeNull();
    expect(turn(0, { deltaX: 40, altKey: true })).toBeNull();
    expect(turn(0, { shiftKey: true })).toBeNull();
    expect(turn(0, { metaKey: true })).toBeNull();
  });
});
