// The camera's moves: where it stands (a pose) and how it gets from one pose to the next, eased
// over a moment. Its direction from what it looks at turns on the way, so a move from the top to
// the bottom goes round the model, not through it; its distance, what it looks at and how much
// an orthographic camera shows ease along. Plain math over three.js's vectors.

import { Quaternion, Vector3 } from 'three';

/** How long a move takes, by default. */
export const MOTION_MS = 250;
/** Two directions this close (the cosine of their angle) are one: a named view's, say. */
const SAME_DIRECTION = 1 - 1e-6;

/**
 * Where a camera stands: what it looks at, from which way (a unit vector from the target toward
 * the camera) and how far, and the half-height an orthographic camera shows (at zoom 1).
 * @typedef {object} Pose
 * @property {Vector3} target
 * @property {Vector3} direction
 * @property {number} distance
 * @property {number} halfHeight
 */

/**
 * Whether two unit directions are one.
 * @param {Vector3} a
 * @param {Vector3} b
 */
export const sameDirection = (a, b) => a.dot(b) >= SAME_DIRECTION;

/** A move from one pose to another, eased in and out. */
export class CameraMove {
  /** @type {Pose} */
  #from;
  /** @type {Pose} */
  #to;
  /** The turn from the first direction to the last. */
  #turn;
  #start;
  #ms;

  /**
   * @param {Pose} from
   * @param {Pose} to
   * @param {number} start when it starts, in ms (`performance.now()`'s)
   * @param {number} ms how long it takes
   */
  constructor(from, to, start, ms) {
    this.#from = from;
    this.#to = to;
    this.#turn = new Quaternion().setFromUnitVectors(from.direction, to.direction);
    this.#start = start;
    this.#ms = ms;
  }

  /** Where it ends. */
  get to() {
    return this.#to;
  }

  /**
   * The pose at `now`, and whether the move is over.
   * @param {number} now
   * @returns {{ pose: Pose, done: boolean }}
   */
  at(now) {
    const t = Math.min(1, Math.max(0, (now - this.#start) / this.#ms));
    if (t === 1) return { pose: this.#to, done: true };
    const k = easeInOut(t);
    const from = this.#from;
    const to = this.#to;
    const turn = new Quaternion().slerp(this.#turn, k);
    return {
      pose: {
        target: from.target.clone().lerp(to.target, k),
        direction: from.direction.clone().applyQuaternion(turn).normalize(),
        distance: from.distance + (to.distance - from.distance) * k,
        halfHeight: from.halfHeight + (to.halfHeight - from.halfHeight) * k,
      },
      done: false,
    };
  }
}

/**
 * Cubic ease in and out: slow at both ends.
 * @param {number} t from 0 to 1
 */
export function easeInOut(t) {
  return t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2;
}

/**
 * The direction `[x, y, z]` as a unit vector.
 * @param {readonly [number, number, number]} direction
 */
export const unit = (direction) => new Vector3(...direction).normalize();
