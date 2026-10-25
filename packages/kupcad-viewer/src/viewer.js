// The viewer: a three.js scene of a model the core made, in the script's own coordinates
// (millimetres, Z up), for any host; Viewer.svelte wraps it for Svelte. Its state is properties
// (render mode, camera, section, selection, environment) that the host's toolbar sets, and it
// renders when one changes or the camera moves, not every frame. A click on a part selects it
// and says so (a 'select' event, `detail.part` its name, or null), as does a model without the
// selected part. The camera moves to a view over a moment (motion.js); turned by hand, it is in
// no named view, which a 'view' event says. Its keys are Orca Slicer's. What is under the pointer
// (the part, the face: faces.js) a 'hover' event says, a frame at most.

import {
  AmbientLight,
  Box3,
  Color,
  DirectionalLight,
  Group,
  LineBasicMaterial,
  MOUSE,
  OrthographicCamera,
  PerspectiveCamera,
  Quaternion,
  Raycaster,
  Scene,
  Sphere,
  Vector2,
  WebGLRenderer,
} from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { applyRenderMode, applySelection } from './appearance.js';
import { boundsOf, orthographicHalfHeight, perspectiveDistance, VIEWS } from './camera.js';
import { disposeObject } from './dispose.js';
import { axesOf, environmentOf } from './environment.js';
import { faceAt } from './faces.js';
import { disposeScene, isDracoCompressed, sceneOf } from './model.js';
import { CameraMove, MOTION_MS, sameDirection, unit } from './motion.js';
import { RENDER_ORDER, SectionView } from './section.js';
import { LIGHT } from './theme.js';

/** @import { Vector3 } from 'three' */
/** @import { DRACOLoader } from 'three/addons/loaders/DRACOLoader.js' */
/** @import { Pose } from './motion.js' */

/** @import { Model } from '@kupcad/protocol/types' */
/** @import { Bounds, Environment, Hover, Plate, Projection, RendererLike, RenderMode, SceneModel, Section, Shape, Theme, View, ViewerOptions } from './types.js' */

/** The perspective camera's vertical field of view, in degrees. */
const FOV_DEG = 35;
const DEFAULT_PLATE = { width: 256, depth: 256 };
/** A pointer that moves less than this between down and up clicked, rather than dragged. */
const CLICK_SLOP_PX = 4;
/** The perspective camera's near plane, as a factor of the model's radius. */
const NEAR_FACTOR = 0.01;
/** The orthographic camera stands this many radii from the model's centre. */
const ORTHO_STANDOFF = 4;
/** The lights: an even fill, and one from the camera. */
const AMBIENT_INTENSITY = 0.9;
const HEADLIGHT_INTENSITY = 2.2;
/** The views by key, Orca Slicer's (Ctrl or Cmd with a digit, or the digit alone): 0 its default. */
const VIEW_KEYS = /** @type {Record<string, View>} */ ({
  0: 'iso',
  1: 'top',
  2: 'bottom',
  3: 'front',
  4: 'back',
  5: 'left',
  6: 'right',
});
/** What `I` zooms in by, and `O` out. */
const ZOOM_STEP = 1.25;

/** The render modes and views a toolbar offers, in order. */
export const RENDER_MODES = /** @type {const} */ (['solid', 'xray', 'wireframe']);
export const VIEW_NAMES = /** @type {View[]} */ (Object.keys(VIEWS));

/** A model the viewer can't show, saying why. */
export class ViewerError extends Error {
  /** @param {string} message */
  constructor(message) {
    super(message);
    this.name = 'ViewerError';
  }
}

/**
 * @param {HTMLCanvasElement} canvas
 * @returns {RendererLike}
 */
const webGLRenderer = (canvas) => new WebGLRenderer({ canvas, antialias: true, stencil: true });

export class Viewer extends EventTarget {
  /** @type {HTMLCanvasElement} */
  #canvas;
  /** @type {ViewerOptions} */
  #options;
  /** @type {RendererLike} */
  #renderer;
  #scene = new Scene();
  /** The model's scene goes in here; what it stands on, beside it. */
  #content = new Group();
  #environment = new Group();
  #perspective = new PerspectiveCamera(FOV_DEG, 1, 1, 1000);
  #orthographic = new OrthographicCamera(-1, 1, 1, -1, 0.1, 1000);
  /** @type {PerspectiveCamera | OrthographicCamera} */
  #camera = this.#perspective;
  /** The orthographic camera's half-height at zoom 1. */
  #halfHeight = 1;
  /** @type {OrbitControls} */
  #controls;
  #headlight = new DirectionalLight(0xffffff, HEADLIGHT_INTENSITY);
  /** @type {SectionView} */
  #sectionView;
  #raycaster = new Raycaster();
  /** The selected part's edges, in the selection's colour. */
  #selectionEdges = new LineBasicMaterial();
  /** @type {SceneModel | null} */
  #model = null;
  /** The kind of the last model shown, which a model of nothing (one that failed) leaves. @type {SceneModel['kind'] | null} */
  #shownKind = null;
  /** The camera a solid was last seen with, which a drawing (from the top, orthographic) leaves. @type {{ projection: Projection, view: View | null, direction: Vector3 }} */
  #solidCamera = { projection: 'perspective', view: 'iso', direction: VIEWS.iso.clone() };
  /** Around the model and what it stands on: what the camera's depth takes in. */
  #sceneSphere = new Sphere();
  /** @type {Theme} */
  #theme;
  /** @type {Environment} */
  #environmentKind;
  /** @type {Plate} */
  #plate;
  /** @type {RenderMode} */
  #renderMode = 'solid';
  /** The shapes' edges are drawn (a wireframe's always are). */
  #edges = true;
  /** The axes through the origin are drawn. */
  #axes = true;
  /** @type {Projection} */
  #projection = 'perspective';
  /** The named view the camera looks from, or null for none (turned by hand). @type {View | null} */
  #view = 'iso';
  /** The camera's move under way, if one. @type {CameraMove | null} */
  #move = null;
  /** How the camera was turned when last drawn: a change is a 'camera' event. */
  #orientation = new Quaternion();
  /** @type {Section | null} */
  #section = null;
  /** @type {string | null} */
  #selected = null;
  /** @type {Promise<GLTFLoader> | null} */
  #loader = null;
  /** The GLB loader's Draco decoder, once made: it keeps its workers until disposed. @type {DRACOLoader | null} */
  #draco = null;
  /** Counts the models asked for: one that loads after a later one is dropped. */
  #loads = 0;
  #frame = 0;
  #width = 1;
  #height = 1;
  /** Where the pointer went down, to tell a click from a drag. @type {{ x: number, y: number } | null} */
  #down = null;
  /** Where the pointer is, to say what is under it on the next frame. @type {{ x: number, y: number } | null} */
  #pointer = null;
  #hoverFrame = 0;
  /** Something under the pointer was said: leaving it is said too. */
  #hovering = false;
  #disposed = false;
  /** @type {AbortController} */
  #listeners = new AbortController();

  /**
   * @param {HTMLCanvasElement} canvas
   * @param {ViewerOptions} [options]
   */
  constructor(canvas, options = {}) {
    super();
    this.#canvas = canvas;
    this.#options = options;
    this.#theme = options.theme ?? LIGHT;
    this.#environmentKind = options.environment ?? 'grid';
    this.#plate = options.plate ?? DEFAULT_PLATE;
    this.#renderer = (options.renderer ?? webGLRenderer)(canvas);
    this.#renderer.localClippingEnabled = true;
    this.#renderer.setPixelRatio(globalThis.devicePixelRatio ?? 1);
    for (const camera of [this.#perspective, this.#orthographic]) camera.up.set(0, 0, 1);
    this.#controls = new OrbitControls(this.#camera, canvas);
    // Orca Slicer's: the middle button pans, as the right one does
    this.#controls.mouseButtons.MIDDLE = MOUSE.PAN;
    // Taken by hand: a move under way stops where it is
    this.#controls.addEventListener('start', () => (this.#move = null));
    this.#controls.addEventListener('change', () => {
      this.#fitDepth();
      this.#noteTurned();
      this.#invalidate();
    });
    this.#sectionView = new SectionView(this.#theme);
    this.#scene.add(
      this.#content,
      this.#environment,
      this.#sectionView.cap,
      new AmbientLight(0xffffff, AMBIENT_INTENSITY),
      this.#headlight,
      this.#headlight.target,
    );
    const { signal } = this.#listeners;
    canvas.addEventListener('pointerdown', (event) => this.#pointerDown(event), { signal });
    canvas.addEventListener('pointerup', (event) => this.#pointerUp(event), { signal });
    canvas.addEventListener('keydown', (event) => this.#keyDown(event), { signal });
    canvas.addEventListener('pointermove', (event) => this.#pointerMove(event), { signal });
    canvas.addEventListener('pointerleave', () => this.#pointerMove(null), { signal });
    // Its keys work once it has the focus, which a click gives it
    if (canvas.tabIndex < 0) canvas.tabIndex = 0;
    this.setTheme(this.#theme);
    this.resize();
    this.#frameFrom(VIEWS.iso, false);
  }

  get renderMode() {
    return this.#renderMode;
  }
  get edges() {
    return this.#edges;
  }
  get axes() {
    return this.#axes;
  }
  get projection() {
    return this.#projection;
  }
  /** The named view the camera looks from, or null when it was turned by hand. */
  get view() {
    return this.#view;
  }

  /** How the camera is turned (Z up): what a view cube follows, as 'camera' events say. */
  get orientation() {
    return this.#camera.quaternion.clone();
  }
  get section() {
    return this.#section;
  }
  get selected() {
    return this.#selected;
  }
  get environment() {
    return this.#environmentKind;
  }

  /** The kind of the model shown: '3d' (its solids), '2d' (a drawing), or null for none. */
  get kind() {
    return this.#model?.kind ?? null;
  }

  /**
   * The model's bounds, in the script's coordinates (mm), or null with no model shown: what a
   * section's offset ranges over.
   * @returns {Bounds | null}
   */
  get bounds() {
    const box = this.#modelBox();
    if (box.isEmpty()) return null;
    return {
      min: /** @type {Bounds['min']} */ (box.min.toArray()),
      max: /** @type {Bounds['max']} */ (box.max.toArray()),
    };
  }

  /**
   * Shows `model` in place of the last one (null, or a model of kind 'none', shows nothing).
   * The camera stays where it is, unless the model is the first, or of another kind than the
   * last one shown: then it frames it, a drawing from the top, orthographic, and a solid after
   * a drawing as the last solid was seen. A selection whose part is gone is dropped, with a
   * 'select' event.
   * @param {Model | null} model
   * @returns {Promise<boolean>} whether it is shown: not when a later model was asked for
   *   before it was ready, or the viewer was disposed
   * @throws {ViewerError} for a Draco-compressed model without `dracoDecoderPath`
   */
  async setModel(model) {
    const load = ++this.#loads;
    const built = model ? await this.#build(model) : null;
    if (load !== this.#loads || this.#disposed) {
      if (built) disposeScene(built);
      return false;
    }
    const before = this.#model;
    if (before) {
      before.root.removeFromParent();
      disposeScene(before);
    }
    this.#model = built;
    if (built) {
      for (const shape of built.shapes) shape.mesh.renderOrder = RENDER_ORDER.model;
      this.#content.add(built.root);
    }
    const dropped =
      this.#selected !== null && !built?.shapes.some((shape) => shape.part === this.#selected);
    if (dropped) this.#selected = null;
    this.#applyRenderMode();
    this.#applySelection();
    this.#rebuildEnvironment();
    if (built && built.kind !== this.#shownKind) {
      if (built.kind === '2d') {
        if (this.#shownKind === '3d') {
          this.#solidCamera = {
            projection: this.#projection,
            view: this.#view,
            direction: this.#direction(),
          };
        }
        this.#useProjection('orthographic');
        this.#setView('top');
        this.#frameFrom(VIEWS.top, false);
      } else if (this.#shownKind === '2d') {
        this.#useProjection(this.#solidCamera.projection);
        this.#setView(this.#solidCamera.view);
        this.#frameFrom(this.#solidCamera.direction, false);
      } else {
        this.#frameFrom(this.#direction(), false);
      }
    }
    if (built) this.#shownKind = built.kind;
    this.#applySection();
    this.#invalidate();
    if (dropped) this.#said(null);
    return true;
  }

  /** @param {RenderMode} mode */
  setRenderMode(mode) {
    this.#renderMode = mode;
    this.#applyRenderMode();
    this.#applySection();
    this.#invalidate();
  }

  /**
   * Draws the axes through the origin (X red, Y green, Z blue), where the coordinates are zero,
   * or not.
   * @param {boolean} visible
   */
  setAxes(visible) {
    this.#axes = visible;
    this.#rebuildEnvironment();
    this.#invalidate();
  }

  /**
   * Draws the shapes' edges, or not (a wireframe's are drawn whatever this says).
   * @param {boolean} visible
   */
  setEdges(visible) {
    this.#edges = visible;
    this.#applyRenderMode();
    this.#invalidate();
  }

  /**
   * Looks with `projection`, and from `view`, the camera moving there and framing the model.
   * @param {{ projection?: Projection, view?: View }} camera
   */
  setCamera({ projection, view }) {
    if (projection) this.#useProjection(projection);
    if (view) {
      this.#setView(view);
      this.#frameFrom(VIEWS[view], true);
    }
    this.#invalidate();
  }

  /**
   * Looks from `direction` (from the model toward the camera, Z up: `[1, -1, 1]` is the iso
   * view, `[0, 0, 1]` the top), the camera moving there and framing the model: a view cube's
   * face, edge or corner. A named view's direction is that view.
   * @param {readonly [number, number, number]} direction
   */
  lookFrom(direction) {
    const turned = unit(direction);
    const view = VIEW_NAMES.find((name) => sameDirection(VIEWS[name], turned)) ?? null;
    this.#setView(view);
    this.#frameFrom(view ? VIEWS[view] : turned, true);
  }

  /**
   * Zooms in by `factor` (out, below 1) toward what the camera looks at.
   * @param {number} factor
   */
  zoom(factor) {
    this.#settleMove();
    if (this.#camera === this.#orthographic) {
      this.#orthographic.zoom *= factor;
    } else {
      const target = this.#controls.target;
      this.#perspective.position.sub(target).divideScalar(factor).add(target);
    }
    this.#fitDepth();
    this.#controls.update();
    this.#invalidate();
  }

  /** @param {Section | null} section */
  setSection(section) {
    this.#section = section ? { ...section } : null;
    this.#applySection();
    this.#invalidate();
  }

  /**
   * Tints the copies of `part`, or none (null).
   * @param {string | null} part
   */
  select(part) {
    this.#selected = part;
    this.#applySelection();
    this.#invalidate();
  }

  /**
   * @param {Environment} environment
   * @param {Plate} [plate] the build plate's size, from now on
   */
  setEnvironment(environment, plate) {
    this.#environmentKind = environment;
    if (plate) this.#plate = plate;
    this.#rebuildEnvironment();
    this.#invalidate();
  }

  /** @param {Theme} theme */
  setTheme(theme) {
    this.#theme = theme;
    this.#scene.background = new Color(theme.background);
    this.#selectionEdges.color.set(theme.selection);
    this.#sectionView.setCapColor(theme.cap);
    if (this.#model) {
      this.#model.edgeMaterial.color.set(theme.edges);
      for (const shape of this.#model.shapes) {
        if (shape.ghost) shape.color.set(theme.ghost);
      }
    }
    this.#applySelection();
    this.#rebuildEnvironment();
    this.#invalidate();
  }

  /** Frames the whole model from where the camera looks now (its angle kept), moving there. */
  fit() {
    this.#frameFrom(this.#direction(), true);
  }

  /**
   * Fits the drawing to the canvas's size (by default the size it is laid out at), in CSS
   * pixels.
   * @param {number} [width]
   * @param {number} [height]
   */
  resize(width = this.#canvas.clientWidth, height = this.#canvas.clientHeight) {
    this.#width = Math.max(1, width);
    this.#height = Math.max(1, height);
    this.#renderer.setSize(this.#width, this.#height, false);
    this.#updateProjection();
    this.#invalidate();
  }

  /**
   * The part under a point of the canvas (CSS pixels from its top left), or null: what a
   * section cut away isn't there.
   * @param {number} x
   * @param {number} y
   * @returns {string | null}
   */
  partAt(x, y) {
    return this.#hitAt(x, y)?.shape.part ?? null;
  }

  /**
   * What is under a point of the canvas (CSS pixels from its top left): the part (null for a
   * nameless one) and, on a solid, the face; null over nothing, a ghost, or what a section cut
   * away.
   * @param {number} x
   * @param {number} y
   * @returns {Hover | null}
   */
  hoverAt(x, y) {
    const hit = this.#hitAt(x, y);
    if (!hit) return null;
    const face =
      this.#model?.kind === '3d' && hit.triangle !== null
        ? faceAt(/** @type {import('three').Mesh} */ (hit.shape.mesh), hit.triangle)
        : null;
    return { part: hit.shape.part, face };
  }

  /**
   * The canvas as it shows now, as an image.
   * @param {string} [type]
   * @returns {Promise<Blob>}
   */
  screenshot(type = 'image/png') {
    // Read before the frame is handed on, while the drawing buffer still holds it
    this.#render();
    return new Promise((resolve, reject) => {
      this.#canvas.toBlob((blob) => {
        if (blob) resolve(blob);
        else reject(new ViewerError('the canvas gave no image'));
      }, type);
    });
  }

  dispose() {
    if (this.#disposed) return;
    this.#disposed = true;
    if (this.#frame) cancelAnimationFrame(this.#frame);
    if (this.#hoverFrame) cancelAnimationFrame(this.#hoverFrame);
    this.#listeners.abort();
    this.#controls.dispose();
    if (this.#model) disposeScene(this.#model);
    disposeObject(this.#environment);
    this.#draco?.dispose();
    this.#sectionView.dispose();
    this.#selectionEdges.dispose();
    this.#renderer.dispose();
  }

  /**
   * @param {Model} model
   * @returns {Promise<SceneModel | null>}
   */
  async #build(model) {
    if (model.kind === '3d' && isDracoCompressed(model.glb) && !this.#options.dracoDecoderPath) {
      throw new ViewerError(
        "the model is Draco-compressed: give the viewer the decoder's files (dracoDecoderPath)",
      );
    }
    return sceneOf(model, await this.#gltfLoader(), this.#theme);
  }

  /**
   * The GLB loader, made once; with the Draco decoder when the host gave its files, which it
   * loads only when a model needs it.
   * @returns {Promise<GLTFLoader>}
   */
  #gltfLoader() {
    this.#loader ??= (async () => {
      const loader = new GLTFLoader();
      const decoderPath = this.#options.dracoDecoderPath;
      if (decoderPath) {
        const { DRACOLoader } = await import('three/addons/loaders/DRACOLoader.js');
        // Disposed while its module loaded: a decoder made now would keep its workers for good
        if (!this.#disposed) {
          this.#draco = new DRACOLoader().setDecoderPath(decoderPath);
          loader.setDRACOLoader(this.#draco);
        }
      }
      return loader;
    })();
    return this.#loader;
  }

  #applyRenderMode() {
    applyRenderMode(this.#model, this.#renderMode, this.#edges);
  }

  #applySelection() {
    applySelection(this.#model, this.#selected, this.#theme.selection, this.#selectionEdges);
  }

  #applySection() {
    this.#sectionView.apply(this.#section, this.#model, boundsOf(this.#modelBox()), {
      capped: this.#renderMode !== 'wireframe',
      also: [this.#selectionEdges],
    });
  }

  #rebuildEnvironment() {
    disposeObject(this.#environment);
    this.#environment.clear();
    const box = this.#modelBox();
    this.#environment.add(environmentOf(this.#environmentKind, box, this.#plate, this.#theme));
    if (this.#axes) this.#environment.add(axesOf(this.#environmentKind, box, this.#plate));
    this.#sceneSphere = boundsOf(box.union(new Box3().setFromObject(this.#environment)));
    this.#fitDepth();
  }

  /**
   * The camera's near and far planes, so the model and what it stands on are drawn whole from
   * where it looks: an orthographic camera's near plane may lie behind it, a perspective
   * one's stays where `fit` put it. They were the model's alone, so a small model's plate was
   * cut off past the far plane, and behind an orthographic camera.
   */
  #fitDepth() {
    const target = this.#controls.target;
    const reach = target.distanceTo(this.#sceneSphere.center) + this.#sceneSphere.radius;
    const distance = this.#camera.position.distanceTo(target);
    if (this.#camera === this.#orthographic) this.#orthographic.near = distance - reach;
    this.#camera.far = distance + reach;
    this.#camera.updateProjectionMatrix();
  }

  /** @returns {Box3} */
  #modelBox() {
    return this.#model ? new Box3().setFromObject(this.#model.root) : new Box3();
  }

  /**
   * The way the camera looks from, from what it looks at: the way it moves to, while it moves.
   * @returns {Vector3}
   */
  #direction() {
    if (this.#move) return this.#move.to.direction.clone();
    return this.#camera.position.clone().sub(this.#controls.target).normalize();
  }

  /**
   * Where the camera stands now.
   * @returns {Pose}
   */
  #pose() {
    const target = this.#controls.target.clone();
    const offset = this.#camera.position.clone().sub(target);
    return {
      target,
      direction: offset.clone().normalize(),
      distance: offset.length(),
      halfHeight: this.#halfHeight / this.#orthographic.zoom,
    };
  }

  /**
   * Where the camera stands to show the whole model from `direction`.
   * @param {Vector3} direction
   * @returns {Pose}
   */
  #framing(direction) {
    const sphere = boundsOf(this.#modelBox());
    const aspect = this.#width / this.#height;
    const perspective = this.#camera === this.#perspective;
    if (perspective) this.#perspective.near = Math.max(sphere.radius * NEAR_FACTOR, 0.01);
    return {
      target: sphere.center.clone(),
      direction: direction.clone(),
      distance: perspective
        ? perspectiveDistance(sphere, FOV_DEG, aspect)
        : sphere.radius * ORTHO_STANDOFF,
      halfHeight: orthographicHalfHeight(sphere, aspect),
    };
  }

  /**
   * Frames the model from `direction`: over a move when `moving` (unless the page asks for
   * reduced motion), at once otherwise.
   * @param {Vector3} direction
   * @param {boolean} moving
   */
  #frameFrom(direction, moving) {
    const to = this.#framing(direction);
    const ms = moving ? this.#motionMs() : 0;
    this.#move = ms > 0 ? new CameraMove(this.#pose(), to, performance.now(), ms) : null;
    if (!this.#move) this.#standAt(to, true);
    this.#invalidate();
  }

  /** How long a move takes: none when the page asks for reduced motion. */
  #motionMs() {
    const reduced = globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false;
    return reduced ? 0 : (this.#options.motionMs ?? MOTION_MS);
  }

  /**
   * Stands the camera at `pose`; `settled` when it stays there: the controls take it up.
   * @param {Pose} pose
   * @param {boolean} settled
   */
  #standAt(pose, settled) {
    this.#controls.target.copy(pose.target);
    this.#camera.position.copy(pose.target).addScaledVector(pose.direction, pose.distance);
    this.#halfHeight = pose.halfHeight;
    this.#orthographic.zoom = 1;
    this.#camera.lookAt(pose.target);
    this.#fitDepth();
    this.#updateProjection();
    if (settled) this.#controls.update();
  }

  /** Ends a move under way where it was going. */
  #settleMove() {
    const move = this.#move;
    if (!move) return;
    this.#move = null;
    this.#standAt(move.to, true);
  }

  /**
   * The view is `view` from now on, which a 'view' event says when it changed.
   * @param {View | null} view
   */
  #setView(view) {
    if (view === this.#view) return;
    this.#view = view;
    this.dispatchEvent(new CustomEvent('view', { detail: { view } }));
  }

  /** Turned by hand away from its named view, the camera is in none. */
  #noteTurned() {
    if (this.#move || this.#view === null) return;
    if (!sameDirection(this.#direction(), VIEWS[this.#view])) this.#setView(null);
  }

  /**
   * Looks through the other camera, from where this one looks and seeing as much.
   * @param {Projection} projection
   */
  #useProjection(projection) {
    if (projection === this.#projection) return;
    this.#settleMove();
    const target = this.#controls.target;
    const from = this.#camera;
    const direction = from.position.clone().sub(target).normalize();
    const halfTan = Math.tan(((FOV_DEG / 2) * Math.PI) / 180);
    if (projection === 'orthographic') {
      const distance = from.position.distanceTo(target);
      this.#halfHeight = distance * halfTan;
      this.#orthographic.zoom = 1;
      this.#orthographic.position.copy(target).addScaledVector(direction, distance);
      this.#camera = this.#orthographic;
    } else {
      const distance = this.#halfHeight / this.#orthographic.zoom / halfTan;
      this.#perspective.position.copy(target).addScaledVector(direction, distance);
      this.#camera = this.#perspective;
    }
    this.#projection = projection;
    this.#camera.lookAt(target);
    this.#controls.object = this.#camera;
    this.#fitDepth();
    this.#updateProjection();
    this.#controls.update();
  }

  #updateProjection() {
    const aspect = this.#width / this.#height;
    this.#perspective.aspect = aspect;
    this.#perspective.updateProjectionMatrix();
    Object.assign(this.#orthographic, {
      top: this.#halfHeight,
      bottom: -this.#halfHeight,
      left: -this.#halfHeight * aspect,
      right: this.#halfHeight * aspect,
    });
    this.#orthographic.updateProjectionMatrix();
  }

  /** Draws on the next frame, once however many things changed before it. */
  #invalidate() {
    if (this.#frame || this.#disposed) return;
    this.#frame = requestAnimationFrame(() => {
      this.#frame = 0;
      this.#render();
    });
  }

  #render() {
    if (this.#move) {
      const { pose, done } = this.#move.at(performance.now());
      if (done) this.#move = null;
      this.#standAt(pose, done);
      if (!done) this.#invalidate();
    }
    this.#headlight.position.copy(this.#camera.position);
    this.#headlight.target.position.copy(this.#controls.target);
    this.#renderer.render(this.#scene, this.#camera);
    if (!this.#orientation.equals(this.#camera.quaternion)) {
      this.#orientation.copy(this.#camera.quaternion);
      this.dispatchEvent(new CustomEvent('camera'));
    }
  }

  /**
   * A click selects with the main button of the first pointer: the others pan and zoom.
   * @param {PointerEvent} event
   */
  #pointerDown(event) {
    this.#down =
      event.isPrimary && event.button === 0 ? { x: event.offsetX, y: event.offsetY } : null;
  }

  /**
   * The first shape the ray through a point of the canvas meets, and the triangle it meets:
   * not a ghost (seen through), nor where a section cut it away.
   * @param {number} x
   * @param {number} y
   * @returns {{ shape: Shape, triangle: number | null } | null}
   */
  #hitAt(x, y) {
    if (!this.#model) return null;
    this.#scene.updateMatrixWorld();
    this.#camera.updateMatrixWorld();
    const pointer = new Vector2((x / this.#width) * 2 - 1, 1 - (y / this.#height) * 2);
    this.#raycaster.setFromCamera(pointer, this.#camera);
    /** @type {Map<import('three').Object3D, Shape>} */
    const solid = new Map();
    for (const shape of this.#model.shapes) {
      if (!shape.ghost) solid.set(shape.mesh, shape);
    }
    for (const hit of this.#raycaster.intersectObjects([...solid.keys()], false)) {
      if (this.#sectionView.clipping && this.#sectionView.plane.distanceToPoint(hit.point) < 0) {
        continue;
      }
      const shape = /** @type {Shape} */ (solid.get(hit.object));
      return { shape, triangle: hit.faceIndex ?? null };
    }
    return null;
  }

  /**
   * The pointer moved over the canvas (or left it: null): what is under it is said on the next
   * frame, once however often it moved, and nothing while a button drags the camera.
   * @param {PointerEvent | null} event
   */
  #pointerMove(event) {
    this.#pointer = event && event.buttons === 0 ? { x: event.offsetX, y: event.offsetY } : null;
    if (this.#hoverFrame || this.#disposed) return;
    this.#hoverFrame = requestAnimationFrame(() => {
      this.#hoverFrame = 0;
      this.#sayHover();
    });
  }

  /** Says what is under the pointer ('hover', its detail `hoverAt`'s with where), or nothing. */
  #sayHover() {
    const at = this.#pointer;
    const under = at ? this.hoverAt(at.x, at.y) : null;
    if (!under && !this.#hovering) return;
    this.#hovering = under !== null;
    const detail = under && at ? { ...under, x: at.x, y: at.y } : null;
    this.dispatchEvent(new CustomEvent('hover', { detail }));
  }

  /**
   * Orca Slicer's keys: a digit (with Ctrl or Cmd, or alone) looks from a view, `F` fits the
   * model, `I` and `O` zoom in and out. Another key is left to the page.
   * @param {KeyboardEvent} event
   */
  #keyDown(event) {
    if (event.altKey || event.shiftKey) return;
    const view = Object.hasOwn(VIEW_KEYS, event.key) ? VIEW_KEYS[event.key] : null;
    const key = event.ctrlKey || event.metaKey ? null : event.key.toLowerCase();
    if (view) this.setCamera({ view });
    else if (key === 'f') this.fit();
    else if (key === 'i') this.zoom(ZOOM_STEP);
    else if (key === 'o') this.zoom(1 / ZOOM_STEP);
    else return;
    event.preventDefault();
  }

  /** @param {PointerEvent} event */
  #pointerUp(event) {
    const down = this.#down;
    this.#down = null;
    if (!down || Math.hypot(event.offsetX - down.x, event.offsetY - down.y) > CLICK_SLOP_PX) return;
    const part = this.partAt(event.offsetX, event.offsetY);
    this.select(part);
    this.#said(part);
  }

  /**
   * Says the selection is now `part`.
   * @param {string | null} part
   */
  #said(part) {
    this.dispatchEvent(new CustomEvent('select', { detail: { part } }));
  }
}
