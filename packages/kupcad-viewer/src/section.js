// A section through the model: a plane that every shape's materials clip at, and the faces it
// cuts capped where the plane runs inside a solid, by three.js's stencil technique
// (webgl_clipping_stencil): each solid's back faces count up in the stencil buffer and its front
// faces down, both clipped, so where the count isn't 0 the plane is inside a solid, and a plane
// drawn there in the cap's colour closes the cut.

import {
  AlwaysStencilFunc,
  BackSide,
  DecrementWrapStencilOp,
  DoubleSide,
  FrontSide,
  Group,
  IncrementWrapStencilOp,
  Mesh,
  MeshBasicMaterial,
  MeshStandardMaterial,
  NotEqualStencilFunc,
  Plane,
  PlaneGeometry,
  ReplaceStencilOp,
  Vector3,
} from 'three';
import { ownMaterials } from './model.js';

/** @import { Material, Sphere } from 'three' */
/** @import { Section, SceneModel, Theme } from './types.js' */

/** The order things are drawn in while a section is on: stencil counts, the cap, the model. */
export const RENDER_ORDER = { stencil: 1, cap: 1.1, model: 2 };
/** The axis each section is across, as the direction it cuts away. */
const AXES = { x: new Vector3(1, 0, 0), y: new Vector3(0, 1, 0), z: new Vector3(0, 0, 1) };
/** The cap plane reaches this far past the model's bounding sphere's radius. */
const CAP_REACH = 4;
const PLANE_NORMAL = new Vector3(0, 0, 1);

export class SectionView {
  /** The plane every material clips at, while a section is on. */
  plane = new Plane();
  /** Whether the model is cut: a section is on, and the model is a solid's (a drawing isn't). */
  clipping = false;
  /** The cap's plane, drawn where the stencil count isn't 0. */
  cap;
  /** The stencil counters added under each solid mesh: taken away with the section. */
  #counters = /** @type {Group[]} */ ([]);

  /** @param {Theme} theme */
  constructor(theme) {
    const material = new MeshStandardMaterial({
      color: theme.cap,
      // Seen from the side cut away, against the plane's normal, which points to what is kept
      side: DoubleSide,
      stencilWrite: true,
      stencilRef: 0,
      stencilFunc: NotEqualStencilFunc,
      stencilFail: ReplaceStencilOp,
      stencilZFail: ReplaceStencilOp,
      stencilZPass: ReplaceStencilOp,
    });
    this.cap = new Mesh(new PlaneGeometry(1, 1), material);
    this.cap.renderOrder = RENDER_ORDER.cap;
    this.cap.visible = false;
    // The next frame counts afresh
    this.cap.onAfterRender = (renderer) => renderer.clearStencil();
  }

  /** @param {string} color */
  setCapColor(color) {
    /** @type {MeshStandardMaterial} */ (this.cap.material).color.set(color);
  }

  /**
   * Cuts `model` at `section`, or takes the cut away (null).
   * @param {Section | null} section
   * @param {SceneModel | null} model
   * @param {Sphere} bounds the model's, which the cap must cover
   * @param {{ capped: boolean, also: Material[] }} options whether the cut is closed (not in a
   *   wireframe), and materials outside the model that clip with it (the selected shapes'
   *   edges)
   */
  apply(section, model, bounds, { capped, also }) {
    for (const counters of this.#counters) {
      counters.removeFromParent();
      for (const counter of counters.children) {
        /** @type {Material} */ (/** @type {Mesh} */ (counter).material).dispose();
      }
    }
    this.#counters = [];
    const cut = section && model?.kind === '3d' ? { section, model } : null;
    this.clipping = cut !== null;
    if (cut) {
      // What lies past the offset, along the axis (against it when flipped), is cut away
      this.plane.normal.copy(AXES[cut.section.axis]).multiplyScalar(cut.section.flip ? 1 : -1);
      this.plane.constant = cut.section.flip ? -cut.section.offset : cut.section.offset;
    }
    this.cap.visible = cut !== null && capped;
    for (const material of [...(model ? ownMaterials(model) : []), ...also]) {
      material.clippingPlanes = cut ? [this.plane] : null;
      material.needsUpdate = true;
    }
    if (!cut || !capped) return;

    for (const shape of cut.model.shapes) {
      if (shape.ghost) continue;
      const counters = stencilCounters(shape.mesh, this.plane);
      shape.mesh.add(counters);
      this.#counters.push(counters);
    }
    // Centred where the model's centre meets the plane, the cap covers the cut wherever it is
    const size = bounds.radius * CAP_REACH;
    this.cap.scale.set(size, size, 1);
    this.plane.projectPoint(bounds.center, this.cap.position);
    this.cap.quaternion.setFromUnitVectors(PLANE_NORMAL, this.plane.normal);
  }

  dispose() {
    this.cap.geometry.dispose();
    /** @type {Material} */ (this.cap.material).dispose();
  }
}

/**
 * Two invisible copies of `mesh`, clipped at `plane`: its back faces counting up in the
 * stencil buffer, its front faces down.
 * @param {Mesh} mesh
 * @param {Plane} plane
 * @returns {Group}
 */
function stencilCounters(mesh, plane) {
  const counters = new Group();
  for (const [side, op] of /** @type {const} */ ([
    [BackSide, IncrementWrapStencilOp],
    [FrontSide, DecrementWrapStencilOp],
  ])) {
    const material = new MeshBasicMaterial({
      side,
      clippingPlanes: [plane],
      depthWrite: false,
      depthTest: false,
      colorWrite: false,
      stencilWrite: true,
      stencilFunc: AlwaysStencilFunc,
      stencilFail: op,
      stencilZFail: op,
      stencilZPass: op,
    });
    const counter = new Mesh(mesh.geometry, material);
    counter.renderOrder = RENDER_ORDER.stencil;
    counters.add(counter);
  }
  return counters;
}
