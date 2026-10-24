// The viewer: a three.js scene of a model the core made, in the script's own coordinates
// (millimetres, Z up), for any host; Viewer.svelte wraps it for Svelte. Its state is properties
// (render mode, camera, section, selection, environment) that the host's toolbar sets, and it
// renders when one changes or the camera moves, not every frame. A click on a part selects it
// and says so (a 'select' event, `detail.part` its name, or null), as does a model without the
// selected part.

import {
  AmbientLight,
  Box3,
  Color,
  DirectionalLight,
  Group,
  LineBasicMaterial,
  OrthographicCamera,
  PerspectiveCamera,
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
import { environmentOf } from './environment.js';
import { disposeScene, isDracoCompressed, sceneOf } from './model.js';
import { RENDER_ORDER, SectionView } from './section.js';
import { LIGHT } from './theme.js';

/** @import { DRACOLoader } from 'three/addons/loaders/DRACOLoader.js' */
/** @import { Model } from '@kupcad/protocol/types' */
/** @import { Bounds, Environment, Plate, Projection, RendererLike, RenderMode, SceneModel, Section, Shape, Theme, View, ViewerOptions } from './types.js' */

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
  /** The camera a solid was last seen with, which a drawing (from the top, orthographic) leaves. @type {{ projection: Projection, view: View }} */
  #solidCamera = { projection: 'perspective', view: 'iso' };
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
  /** @type {Projection} */
  #projection = 'perspective';
  /** @type {View} */
  #view = 'iso';
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
    this.#controls.addEventListener('change', () => {
      this.#fitDepth();
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
    this.setTheme(this.#theme);
    this.resize();
    this.fit();
  }

  get renderMode() {
    return this.#renderMode;
  }
  get projection() {
    return this.#projection;
  }
  get view() {
    return this.#view;
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
   * @returns {Promise<void>}
   * @throws {ViewerError} for a Draco-compressed model without `dracoDecoderPath`
   */
  async setModel(model) {
    const load = ++this.#loads;
    const built = model ? await this.#build(model) : null;
    if (load !== this.#loads || this.#disposed) {
      if (built) disposeScene(built);
      return;
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
          this.#solidCamera = { projection: this.#projection, view: this.#view };
        }
        this.#useProjection('orthographic');
        this.#view = 'top';
      } else if (this.#shownKind === '2d') {
        this.#useProjection(this.#solidCamera.projection);
        this.#view = this.#solidCamera.view;
      }
      this.fit();
    }
    if (built) this.#shownKind = built.kind;
    this.#applySection();
    this.#invalidate();
    if (dropped) this.#said(null);
  }

  /** @param {RenderMode} mode */
  setRenderMode(mode) {
    this.#renderMode = mode;
    this.#applyRenderMode();
    this.#applySection();
    this.#invalidate();
  }

  /**
   * Looks with `projection`, and from `view`, framing the model.
   * @param {{ projection?: Projection, view?: View }} camera
   */
  setCamera({ projection, view }) {
    if (projection) this.#useProjection(projection);
    if (view) {
      this.#view = view;
      this.fit();
    }
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

  /** Frames the model from the current view. */
  fit() {
    const sphere = boundsOf(this.#modelBox());
    const direction = VIEWS[this.#view];
    const aspect = this.#width / this.#height;
    if (this.#camera === this.#perspective) {
      const distance = perspectiveDistance(sphere, FOV_DEG, aspect);
      this.#perspective.position.copy(sphere.center).addScaledVector(direction, distance);
      this.#perspective.near = Math.max(sphere.radius * NEAR_FACTOR, 0.01);
    } else {
      this.#halfHeight = orthographicHalfHeight(sphere, aspect);
      this.#orthographic.zoom = 1;
      this.#orthographic.position
        .copy(sphere.center)
        .addScaledVector(direction, sphere.radius * ORTHO_STANDOFF);
    }
    this.#controls.target.copy(sphere.center);
    this.#camera.lookAt(sphere.center);
    this.#fitDepth();
    this.#updateProjection();
    this.#controls.update();
    this.#invalidate();
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
    if (!this.#model) return null;
    this.#scene.updateMatrixWorld();
    this.#camera.updateMatrixWorld();
    const pointer = new Vector2((x / this.#width) * 2 - 1, 1 - (y / this.#height) * 2);
    this.#raycaster.setFromCamera(pointer, this.#camera);
    /** @type {Map<import('three').Object3D, Shape>} */
    const pickable = new Map();
    for (const shape of this.#model.shapes) {
      if (shape.part !== null) pickable.set(shape.mesh, shape);
    }
    for (const hit of this.#raycaster.intersectObjects([...pickable.keys()], false)) {
      if (this.#sectionView.clipping && this.#sectionView.plane.distanceToPoint(hit.point) < 0) {
        continue;
      }
      return pickable.get(hit.object)?.part ?? null;
    }
    return null;
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
    this.#disposed = true;
    if (this.#frame) cancelAnimationFrame(this.#frame);
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
        this.#draco = new DRACOLoader().setDecoderPath(decoderPath);
        loader.setDRACOLoader(this.#draco);
      }
      return loader;
    })();
    return this.#loader;
  }

  #applyRenderMode() {
    applyRenderMode(this.#model, this.#renderMode);
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
   * Looks through the other camera, from where this one looks and seeing as much.
   * @param {Projection} projection
   */
  #useProjection(projection) {
    if (projection === this.#projection) return;
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
    this.#headlight.position.copy(this.#camera.position);
    this.#headlight.target.position.copy(this.#controls.target);
    this.#renderer.render(this.#scene, this.#camera);
  }

  /** @param {PointerEvent} event */
  #pointerDown(event) {
    this.#down = { x: event.offsetX, y: event.offsetY };
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
