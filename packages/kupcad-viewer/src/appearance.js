// How a model's shapes look: their render mode and the selection, set on their materials. Ghosts
// keep their own look.

import { Color } from 'three';

/** @import { LineBasicMaterial, MeshStandardMaterial } from 'three' */
/** @import { RenderMode, SceneModel } from './types.js' */

/** How see-through a solid is in x-ray. */
export const XRAY_OPACITY = 0.25;
/** The selected part's colour moves this far from its own toward the selection's. */
export const SELECTION_TINT = 0.45;

/**
 * Draws the model's shapes as `mode` says: as they are, see-through, or not at all but for their
 * edges (the mesh stays, for picking, and its edges with it).
 * @param {SceneModel | null} model
 * @param {RenderMode} mode
 */
export function applyRenderMode(model, mode) {
  for (const shape of model?.shapes ?? []) {
    if (shape.ghost) continue;
    const material = /** @type {MeshStandardMaterial} */ (shape.mesh.material);
    const xray = mode === 'xray';
    material.visible = mode !== 'wireframe';
    material.transparent = xray || shape.opacity < 1;
    material.opacity = xray ? Math.min(shape.opacity, XRAY_OPACITY) : shape.opacity;
    material.depthWrite = !xray;
    material.needsUpdate = true;
  }
}

/**
 * Tints the copies of `part` toward `selection`, and draws their edges with `selectionEdges`;
 * the other shapes as they are.
 * @param {SceneModel | null} model
 * @param {string | null} part
 * @param {string} selection a CSS colour
 * @param {LineBasicMaterial} selectionEdges
 */
export function applySelection(model, part, selection, selectionEdges) {
  if (!model) return;
  const tint = new Color(selection);
  for (const shape of model.shapes) {
    const material = /** @type {MeshStandardMaterial} */ (shape.mesh.material);
    const chosen = part !== null && shape.part === part;
    material.color.copy(shape.color);
    if (chosen) material.color.lerp(tint, SELECTION_TINT);
    if (shape.edges) shape.edges.material = chosen ? selectionEdges : model.edgeMaterial;
  }
}
