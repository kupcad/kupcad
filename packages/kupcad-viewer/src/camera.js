// Where the camera looks from, and how far it stands to frame a model: plain math over the
// script's coordinates (millimetres, Z up).

import { Sphere, Vector3 } from 'three';

/** @import { Box3 } from 'three' */
/** @import { View } from './types.js' */

/**
 * A top or bottom view looks almost straight down the Z axis: exactly along it, Z up has no
 * meaning on the screen, so the view leans this much toward -Y and the screen's up is +Y.
 */
const STRAIGHT_LEAN = 1e-4;
/** A turn stops this short of looking straight down or up (radians): there, Z up means nothing. */
const POLE_MARGIN = 1e-3;

/** What one step zooms in by (`I`, and the most one turn of the wheel does), and out (`O`). */
export const ZOOM_STEP = 1.25;

/**
 * From the model's centre toward the camera, for each view (unit length).
 * @type {Record<View, Vector3>}
 */
export const VIEWS = {
  iso: new Vector3(1, -1, 1).normalize(),
  top: new Vector3(0, -STRAIGHT_LEAN, 1).normalize(),
  bottom: new Vector3(0, -STRAIGHT_LEAN, -1).normalize(),
  front: new Vector3(0, -1, 0),
  back: new Vector3(0, 1, 0),
  right: new Vector3(1, 0, 0),
  left: new Vector3(-1, 0, 0),
};

/**
 * The sphere a camera must see to show all of `box`: one around a point when the box is
 * empty (no model yet).
 * @param {Box3} box
 * @returns {Sphere}
 */
export function boundsOf(box) {
  if (box.isEmpty()) return new Sphere(new Vector3(), 50);
  return box.getBoundingSphere(new Sphere());
}

/**
 * How far from the sphere's centre a perspective camera of `fovDeg` (vertical) and `aspect`
 * stands to see all of it, with `margin` to spare.
 * @param {Sphere} sphere
 * @param {number} fovDeg
 * @param {number} aspect width / height
 * @param {number} [margin] a factor over the sphere's radius
 * @returns {number}
 */
export function perspectiveDistance(sphere, fovDeg, aspect, margin = 1.15) {
  const vertical = (fovDeg * Math.PI) / 180 / 2;
  const horizontal = Math.atan(Math.tan(vertical) * aspect);
  const half = Math.min(vertical, horizontal);
  return (sphere.radius * margin) / Math.sin(half);
}

/**
 * The half-height an orthographic camera shows to see all of the sphere at `aspect`, with
 * `margin` to spare.
 * @param {Sphere} sphere
 * @param {number} aspect
 * @param {number} [margin]
 * @returns {number}
 */
export function orthographicHalfHeight(sphere, aspect, margin = 1.15) {
  const radius = sphere.radius * margin;
  return aspect >= 1 ? radius : radius / aspect;
}

/**
 * Where a camera standing `offset` from what it looks at stands once turned `across` radians
 * about the Z axis (anticlockwise, seen from the top) and `up` radians toward the top: as far
 * off, short of looking straight down or up.
 * @param {Vector3} offset
 * @param {number} across
 * @param {number} up
 * @returns {Vector3}
 */
export function orbited(offset, across, up) {
  const radius = offset.length();
  const fromTop = Math.acos(Math.min(1, Math.max(-1, offset.z / radius)));
  const tilted = Math.min(Math.PI - POLE_MARGIN, Math.max(POLE_MARGIN, fromTop - up));
  const around = Math.atan2(offset.y, offset.x) + across;
  return new Vector3(
    Math.sin(tilted) * Math.cos(around),
    Math.sin(tilted) * Math.sin(around),
    Math.cos(tilted),
  ).multiplyScalar(radius);
}
