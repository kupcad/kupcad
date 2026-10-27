// The view cube: a small cube in a corner, turned as the viewer's camera is, whose faces, edges and
// corners (26 parts, each a way to look from) take the camera there when clicked; the one under
// the pointer lights up. Its faces are labelled as the views are named (TOP, FRONT, RIGHT, ...),
// each reading upright from its own view. It draws on a canvas of its own, over the viewer's.

import {
  AmbientLight,
  BoxGeometry,
  CanvasTexture,
  Color,
  DirectionalLight,
  EdgesGeometry,
  Group,
  LineBasicMaterial,
  LineSegments,
  Matrix4,
  Mesh,
  MeshBasicMaterial,
  MeshLambertMaterial,
  OrthographicCamera,
  PlaneGeometry,
  Raycaster,
  Scene,
  SRGBColorSpace,
  Vector2,
  Vector3,
  WebGLRenderer,
} from 'three';
import { disposeObject } from './dispose.js';
import { LIGHT } from './theme.js';

/** @import { Quaternion } from 'three' */
/** @import { RendererLike, Theme } from './types.js' */
/** @import { Viewer } from './viewer.js' */

/** How thick an edge's or a corner's part is, of the cube's side (1). */
const BAND = 0.22;
/** The cube's camera stands this far off, and shows this much around it. */
const CAMERA_DISTANCE = 3;
const HALF_VIEW = 0.95;
/** A label sits this far out of its face, so it is drawn over it, across this much of it. */
const LABEL_LIFT = 0.002;
const LABEL_SIZE = 0.9;
const LABEL_PX = 128;
/** A pointer that moves less than this between down and up clicked. */
const CLICK_SLOP_PX = 4;
/**
 * Each face's label, the way it faces and its text's up (Z up, as the scene is): the screen's up
 * in its view (from the top, leaning toward the front, +Y; from the bottom, -Y).
 */
const LABELS = /** @type {const} */ ([
  { text: 'TOP', normal: [0, 0, 1], up: [0, 1, 0] },
  { text: 'BOTTOM', normal: [0, 0, -1], up: [0, -1, 0] },
  { text: 'FRONT', normal: [0, -1, 0], up: [0, 0, 1] },
  { text: 'BACK', normal: [0, 1, 0], up: [0, 0, 1] },
  { text: 'RIGHT', normal: [1, 0, 0], up: [0, 0, 1] },
  { text: 'LEFT', normal: [-1, 0, 0], up: [0, 0, 1] },
]);

/**
 * @typedef {object} ViewCubeOptions
 * @property {Theme} [theme]
 * @property {(canvas: HTMLCanvasElement) => RendererLike} [renderer] by default a WebGLRenderer
 */

/**
 * @param {HTMLCanvasElement} canvas
 * @returns {RendererLike}
 */
const webGLRenderer = (canvas) => new WebGLRenderer({ canvas, antialias: true, alpha: true });

export class ViewCube {
  /** @type {HTMLCanvasElement} */
  #canvas;
  /** @type {Viewer} */
  #viewer;
  /** @type {RendererLike} */
  #renderer;
  #scene = new Scene();
  #camera = new OrthographicCamera(-HALF_VIEW, HALF_VIEW, HALF_VIEW, -HALF_VIEW, 0.1, 10);
  #cube = new Group();
  /** Its parts, each with the way it looks from. @type {Mesh[]} */
  #parts = [];
  #outline = new LineBasicMaterial();
  #raycaster = new Raycaster();
  /** @type {Mesh | null} */
  #hovered = null;
  /** @type {Theme} */
  #theme;
  /** @type {{ x: number, y: number } | null} */
  #down = null;
  #listeners = new AbortController();

  /**
   * @param {HTMLCanvasElement} canvas
   * @param {Viewer} viewer the camera it follows and moves
   * @param {ViewCubeOptions} [options]
   */
  constructor(canvas, viewer, options = {}) {
    this.#canvas = canvas;
    this.#viewer = viewer;
    this.#theme = options.theme ?? LIGHT;
    this.#renderer = (options.renderer ?? webGLRenderer)(canvas);
    this.#renderer.setPixelRatio(globalThis.devicePixelRatio ?? 1);
    this.#camera.up.set(0, 0, 1);
    const headlight = new DirectionalLight(0xffffff, 1.2);
    this.#camera.add(headlight);
    this.#scene.add(this.#cube, this.#camera, new AmbientLight(0xffffff, 1.6));
    this.#build();
    const { signal } = this.#listeners;
    viewer.addEventListener('camera', () => this.#render(), { signal });
    canvas.addEventListener('pointermove', (event) => this.#hover(event), { signal });
    canvas.addEventListener('pointerleave', () => this.#light(null), { signal });
    canvas.addEventListener('pointerdown', (event) => this.#pointerDown(event), { signal });
    canvas.addEventListener('pointerup', (event) => this.#pointerUp(event), { signal });
    this.setTheme(this.#theme);
  }

  /**
   * The part under a point of the canvas (CSS pixels from its top left): the way it looks from,
   * or null.
   * @param {number} x
   * @param {number} y
   * @returns {[number, number, number] | null}
   */
  directionAt(x, y) {
    const part = this.#partAt(x, y);
    return part ? /** @type {[number, number, number]} */ (part.userData.direction) : null;
  }

  /** @param {Theme} theme */
  setTheme(theme) {
    this.#theme = theme;
    const face = new Color(theme.plate);
    const ink = new Color(face.getHSL({ h: 0, s: 0, l: 0 }).l > 0.5 ? '#1f2328' : '#e6e7e9');
    this.#outline.color.copy(ink);
    this.#paintLabels(ink);
    this.#light(this.#hovered);
  }

  /** Fits the drawing to the canvas's size, in CSS pixels. */
  resize(width = this.#canvas.clientWidth, height = this.#canvas.clientHeight) {
    this.#renderer.setSize(Math.max(1, width), Math.max(1, height), false);
    this.#render();
  }

  dispose() {
    this.#listeners.abort();
    this.#removeLabels();
    disposeObject(this.#cube);
    this.#renderer.dispose();
    // Its WebGL context let go now, as the viewer's is
    this.#renderer.forceContextLoss();
  }

  /** Makes the 26 parts, the outline and the labels. */
  #build() {
    for (const x of [-1, 0, 1]) {
      for (const y of [-1, 0, 1]) {
        for (const z of [-1, 0, 1]) {
          if (x === 0 && y === 0 && z === 0) continue;
          const part = new Mesh(
            new BoxGeometry(partExtent(x), partExtent(y), partExtent(z)),
            new MeshLambertMaterial(),
          );
          part.position.set(partOffset(x), partOffset(y), partOffset(z));
          part.userData.direction = [x, y, z];
          this.#parts.push(part);
          this.#cube.add(part);
        }
      }
    }
    this.#cube.add(new LineSegments(new EdgesGeometry(new BoxGeometry(1, 1, 1)), this.#outline));
  }

  /**
   * Labels each face in `ink`, upright as its view sees it: none where the page has no 2D
   * context to draw the text with (jsdom).
   * @param {Color} ink
   */
  #paintLabels(ink) {
    this.#removeLabels();
    for (const { text, normal, up } of LABELS) {
      const texture = labelTexture(text, ink);
      if (!texture) return;
      const plane = new Mesh(
        new PlaneGeometry(LABEL_SIZE, LABEL_SIZE),
        new MeshBasicMaterial({ map: texture, transparent: true }),
      );
      const n = new Vector3(...normal);
      const u = new Vector3(...up);
      plane.quaternion.setFromRotationMatrix(new Matrix4().makeBasis(u.clone().cross(n), u, n));
      plane.position.copy(n).multiplyScalar(0.5 + LABEL_LIFT);
      plane.userData.label = true;
      // The part under it is what a pointer finds
      plane.raycast = () => {};
      this.#cube.add(plane);
    }
  }

  /** Takes the labels away, with their textures. */
  #removeLabels() {
    for (const label of this.#cube.children.filter((child) => child.userData.label)) {
      label.removeFromParent();
      /** @type {MeshBasicMaterial} */ (/** @type {Mesh} */ (label).material).map?.dispose();
      disposeObject(label);
    }
  }

  /**
   * Lights up `part` (none: null) in the selection's colour, the rest as faces are.
   * @param {Mesh | null} part
   */
  #light(part) {
    this.#hovered = part;
    const face = new Color(this.#theme.plate);
    const lit = new Color(this.#theme.selection);
    for (const each of this.#parts) {
      /** @type {MeshLambertMaterial} */ (each.material).color.copy(each === part ? lit : face);
    }
    this.#canvas.style.cursor = part ? 'pointer' : '';
    this.#render();
  }

  /** @param {PointerEvent} event */
  #hover(event) {
    const part = this.#partAt(event.offsetX, event.offsetY);
    if (part !== this.#hovered) this.#light(part);
  }

  /** @param {PointerEvent} event */
  #pointerDown(event) {
    this.#down =
      event.isPrimary && event.button === 0 ? { x: event.offsetX, y: event.offsetY } : null;
  }

  /** @param {PointerEvent} event */
  #pointerUp(event) {
    const down = this.#down;
    this.#down = null;
    if (!down || Math.hypot(event.offsetX - down.x, event.offsetY - down.y) > CLICK_SLOP_PX) return;
    const direction = this.directionAt(event.offsetX, event.offsetY);
    if (direction) this.#viewer.lookFrom(direction);
  }

  /**
   * @param {number} x
   * @param {number} y
   * @returns {Mesh | null}
   */
  #partAt(x, y) {
    const width = this.#canvas.clientWidth;
    const height = this.#canvas.clientHeight;
    if (width === 0 || height === 0) return null;
    this.#follow(this.#viewer.orientation);
    this.#camera.updateMatrixWorld();
    this.#raycaster.setFromCamera(
      new Vector2((x / width) * 2 - 1, 1 - (y / height) * 2),
      this.#camera,
    );
    const [hit] = this.#raycaster.intersectObjects(this.#parts, false);
    return hit ? /** @type {Mesh} */ (hit.object) : null;
  }

  /**
   * Turns the cube's camera as the viewer's is: it looks at the cube from where the viewer's
   * camera looks at the model.
   * @param {Quaternion} orientation
   */
  #follow(orientation) {
    this.#camera.quaternion.copy(orientation);
    this.#camera.position.set(0, 0, CAMERA_DISTANCE).applyQuaternion(orientation);
  }

  #render() {
    this.#follow(this.#viewer.orientation);
    this.#renderer.render(this.#scene, this.#camera);
  }
}

/**
 * How long a part is along an axis its way (`d`, -1, 0 or 1) leans along: a band at the cube's
 * side, else the middle between the bands.
 * @param {number} d
 */
const partExtent = (d) => (d === 0 ? 1 - 2 * BAND : BAND);

/**
 * Where a part's middle is along an axis its way (`d`) leans along.
 * @param {number} d
 */
const partOffset = (d) => d * (0.5 - BAND / 2);

/**
 * A face's label: `text` in `ink` on a clear square, or null where the page has no 2D context.
 * @param {string} text
 * @param {Color} ink
 * @returns {CanvasTexture | null}
 */
function labelTexture(text, ink) {
  const canvas = document.createElement('canvas');
  canvas.width = LABEL_PX;
  canvas.height = LABEL_PX;
  const context = canvas.getContext('2d');
  if (!context) return null;
  context.fillStyle = `#${ink.getHexString()}`;
  context.font = `700 ${Math.round(LABEL_PX / 4.2)}px system-ui, sans-serif`;
  context.textAlign = 'center';
  context.textBaseline = 'middle';
  context.fillText(text, LABEL_PX / 2, LABEL_PX / 2, LABEL_PX * 0.92);
  const texture = new CanvasTexture(canvas);
  texture.colorSpace = SRGBColorSpace;
  return texture;
}
