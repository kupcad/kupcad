// What a turn of the wheel (or two fingers on a trackpad) does, by the key held, as Orca Slicer
// has it. Alone it zooms, and so does a pinch, which a browser sends as the wheel with Ctrl.
// With Shift it pans, as Shift with two fingers does in Orca on a Mac. With Option (Alt) it
// moves the section, as in Orca. With Cmd it turns the view: Orca has nothing for it there. With
// the middle button held it does nothing, as in Orca: that button is the wheel, which turns a
// little as it is pressed. Plain math over the event's numbers: the viewer does what it says.

import { ZOOM_STEP } from './camera.js';

/** A line of scrolling, in CSS pixels, for a browser that counts in lines. */
const LINE_PX = 16;
/**
 * How much a pixel of scrolling zooms, as the log of the factor: three.js's OrbitControls',
 * which zoomed with the wheel before.
 */
const SCROLL_ZOOM_RATE = -Math.log(0.95) / 100;
/** A pinch comes in small steps: each pixel of it zooms ten times as much, as in OrbitControls. */
const PINCH_ZOOM_RATE = SCROLL_ZOOM_RATE * 10;
/** The most one turn zooms by, as the log of the factor: a key's step. */
const MOST_ZOOM = Math.log(ZOOM_STEP);
/** The middle button, in a mouse event's `buttons`. */
const MIDDLE_BUTTON = 4;

/**
 * What a turn of the wheel does: zooms in by `factor` (out, below 1); pans or turns the view by
 * `x` and `y` CSS pixels, as far as a page's content would scroll; or moves the section by `y`
 * pixels, down as it grows.
 * @typedef {{ kind: 'zoom', factor: number }
 *   | { kind: 'pan' | 'orbit', x: number, y: number }
 *   | { kind: 'section', y: number }} WheelGesture
 */

/**
 * What `event` does, or nothing (null).
 * @param {Pick<WheelEvent, 'deltaX' | 'deltaY' | 'deltaMode' | 'buttons' | 'shiftKey' | 'metaKey' | 'altKey' | 'ctrlKey'>} event
 * @param {number} pagePx how far a page of scrolling is, in CSS pixels: the canvas's height
 * @returns {WheelGesture | null}
 */
export function wheelGesture(event, pagePx) {
  if (event.buttons & MIDDLE_BUTTON) return null;
  const unit =
    event.deltaMode === WheelEvent.DOM_DELTA_LINE
      ? LINE_PX
      : event.deltaMode === WheelEvent.DOM_DELTA_PAGE
        ? pagePx
        : 1;
  const x = event.deltaX * unit;
  const y = event.deltaY * unit;
  if (event.shiftKey) return x || y ? { kind: 'pan', x, y } : null;
  if (event.metaKey) return x || y ? { kind: 'orbit', x, y } : null;
  if (event.altKey) return y ? { kind: 'section', y } : null;
  if (!y) return null;
  const rate = event.ctrlKey ? PINCH_ZOOM_RATE : SCROLL_ZOOM_RATE;
  return { kind: 'zoom', factor: Math.exp(Math.min(MOST_ZOOM, Math.max(-MOST_ZOOM, -y * rate))) };
}
