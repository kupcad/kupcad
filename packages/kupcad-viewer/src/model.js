// A model the core made (@kupcad/protocol's Model) as a scene. A GLB's Solids are put back in
// the script's coordinates: the core writes them in metres and Y up under one root node, whose
// transform this undoes, so the scene is in millimetres and Z up. Each mesh is known by the part
// its node is a copy of (the frame's `parts[].nodes`), and gets its feature edges; a ghost is seen
// through, and a highlighted solid drawn in the highlight's colour, seen through what hides it
// too. A drawing's SVG becomes its filled shapes and outlines on the XY plane.

import {
  DoubleSide,
  EdgesGeometry,
  Float32BufferAttribute,
  BufferGeometry,
  GreaterDepth,
  Group,
  LineBasicMaterial,
  LineSegments,
  Matrix4,
  Mesh,
  MeshBasicMaterial,
  ShapeGeometry,
} from 'three';
import { SVGLoader } from 'three/addons/loaders/SVGLoader.js';
import { disposeGeometries } from './dispose.js';

/** @import { Material, Object3D } from 'three' */
/** @import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js' */
/** @import { Model, Part } from '@kupcad/protocol/types' */
/** @import { SceneModel, Shape, Theme } from './types.js' */

/** Where a solid's faces meet at more than this many degrees, an edge is drawn: its features. */
export const EDGE_ANGLE_DEG = 20;
/** A ghost is seen through. */
export const GHOST_OPACITY = 0.2;
/** How much of a highlighted solid shows where something hides it. */
export const SEEN_THROUGH_OPACITY = 0.4;
/**
 * A shape's faces are drawn this far behind its edges (in depth, as a factor of their slope
 * and in its smallest steps), so the edges, at the same depth, aren't lost in the faces.
 */
const FACES_BEHIND_EDGES = { polygonOffset: true, polygonOffsetFactor: 1, polygonOffsetUnits: 1 };
/** The extension a GLB built with `--draco` uses. */
const DRACO_EXTENSION = 'KHR_draco_mesh_compression';
/** A GLB's header (magic, version, length), then its JSON chunk's length and type. */
const GLB_JSON_START = 20;

/**
 * The scene of `model`; null for a model of nothing.
 * @param {Model} model
 * @param {GLTFLoader} loader
 * @param {Theme} theme
 * @returns {Promise<SceneModel | null>}
 */
export async function sceneOf(model, loader, theme) {
  if (model.kind === '3d') return solids(model.glb, model.parts, loader, theme);
  if (model.kind === '2d') return drawing(model.svg, theme);
  return null;
}

/**
 * Whether a GLB's meshes are Draco-compressed (its JSON lists the extension as used).
 * @param {Uint8Array} glb
 */
export function isDracoCompressed(glb) {
  const view = new DataView(glb.buffer, glb.byteOffset, glb.byteLength);
  const jsonLength = view.getUint32(12, true);
  const json = new TextDecoder().decode(glb.subarray(GLB_JSON_START, GLB_JSON_START + jsonLength));
  return (
    /** @type {{ extensionsUsed?: string[] }} */ (JSON.parse(json)).extensionsUsed?.includes(
      DRACO_EXTENSION,
    ) ?? false
  );
}

/**
 * @param {Uint8Array} glb
 * @param {Part[]} parts
 * @param {GLTFLoader} loader
 * @param {Theme} theme
 * @returns {Promise<SceneModel>}
 */
async function solids(glb, parts, loader, theme) {
  // The loader takes a whole ArrayBuffer: the frame's GLB is a view on the frame
  const gltf = await loader.parseAsync(/** @type {ArrayBuffer} */ (glb.slice().buffer), '');
  const scene = gltf.scene;
  if (scene.children.length === 1) {
    const root = scene.children[0];
    root.updateMatrix();
    scene.applyMatrix4(new Matrix4().copy(root.matrix).invert());
  }
  const partOf = new Map(parts.flatMap((part) => part.nodes.map((node) => [node, part.name])));
  // The loader sanitizes the objects' names ("Lid v2.0" is "Lid_v20"): the GLB's are the parts'
  const nodes = /** @type {{ name?: string }[]} */ (gltf.parser.json.nodes ?? []);
  /** @param {Object3D} object */
  const nodeName = (object) => {
    const index = gltf.parser.associations.get(object)?.nodes;
    return index === undefined ? undefined : nodes[index]?.name;
  };
  const edgeMaterial = new LineBasicMaterial({ color: theme.edges });
  /** @type {Shape[]} */
  const shapes = [];
  scene.traverse((object) => {
    if (object instanceof Mesh) {
      shapes.push(solidShape(object, partOf, nodeName, edgeMaterial, theme));
    }
  });
  const root = new Group();
  root.add(scene);
  return { kind: '3d', root, shapes, edgeMaterial };
}

/**
 * A solid's mesh as a shape: its own material (so tinting one part tints no other), its part,
 * and its edges; a ghost seen through, in the theme's colour; a highlighted one (the core tags
 * its material) in the highlight's, seen through what hides it.
 * @param {Mesh} mesh
 * @param {Map<string, string>} partOf
 * @param {(object: Object3D) => string | undefined} nodeName
 * @param {LineBasicMaterial} edgeMaterial
 * @param {Theme} theme
 * @returns {Shape}
 */
function solidShape(mesh, partOf, nodeName, edgeMaterial, theme) {
  const material = /** @type {import('three').MeshStandardMaterial} */ (
    /** @type {Material} */ (mesh.material).clone()
  );
  mesh.material = material;
  const role = material.userData.kupcad_role;
  const ghost = role === 'ghost';
  if (ghost) {
    material.color.set(theme.ghost);
    material.transparent = true;
    material.opacity = GHOST_OPACITY;
    material.depthWrite = false;
    return {
      mesh,
      edges: null,
      part: null,
      ghost,
      seenThrough: null,
      color: material.color.clone(),
      opacity: GHOST_OPACITY,
    };
  }
  const highlighted = role === 'highlight';
  if (highlighted) material.color.set(theme.highlight);
  Object.assign(material, FACES_BEHIND_EDGES);
  const edges = new LineSegments(new EdgesGeometry(mesh.geometry, EDGE_ANGLE_DEG), edgeMaterial);
  mesh.add(edges);
  return {
    mesh,
    edges,
    part: partAbove(mesh, partOf, nodeName),
    ghost,
    seenThrough: highlighted ? seenThroughOf(mesh, theme.highlight) : null,
    color: material.color.clone(),
    opacity: material.opacity,
  };
}

/**
 * A copy of a highlighted solid's mesh, under it, drawn where something hides the solid (its
 * depth behind what is drawn there; never over the solid's own faces, which lie behind it by
 * their offset), see-through in `color`: the highlight seen through whatever is in front.
 * @param {Mesh} mesh
 * @param {string} color
 * @returns {Mesh}
 */
function seenThroughOf(mesh, color) {
  const copy = new Mesh(
    mesh.geometry,
    new MeshBasicMaterial({
      color,
      transparent: true,
      opacity: SEEN_THROUGH_OPACITY,
      depthFunc: GreaterDepth,
      depthWrite: false,
    }),
  );
  mesh.add(copy);
  return copy;
}

/**
 * The part of the nearest node above `object` (itself first) that is a copy of one.
 * @param {Object3D} object
 * @param {Map<string, string>} partOf
 * @param {(object: Object3D) => string | undefined} nodeName the GLB's name of an object's node
 * @returns {string | null}
 */
function partAbove(object, partOf, nodeName) {
  for (let at = /** @type {Object3D | null} */ (object); at; at = at.parent) {
    const name = nodeName(at);
    const part = name === undefined ? undefined : partOf.get(name);
    if (part !== undefined) return part;
  }
  return null;
}

/**
 * A drawing (export_svg's) on the XY plane: each filled path a shape named by its id, with its
 * outline; an open path its outline alone. The core negated every y, SVG's running down the
 * page; the group turns it back.
 * @param {string} svg
 * @param {Theme} theme
 * @returns {SceneModel}
 */
function drawing(svg, theme) {
  const root = new Group();
  root.scale.y = -1;
  // Outlines on the background
  const edgeMaterial = new LineBasicMaterial({ color: theme.wire });
  /** @type {Shape[]} */
  const shapes = [];
  for (const path of new SVGLoader().parse(svg).paths) {
    /** @type {{ fill?: string, fillOpacity?: number }} */
    const style = path.userData?.style ?? {};
    const filled = style.fill !== undefined && style.fill !== 'none';
    const edges = new LineSegments(outlineOf(path, filled), edgeMaterial);
    if (!filled) {
      root.add(edges);
      continue;
    }
    const opacity = style.fillOpacity ?? 1;
    const material = new MeshBasicMaterial({
      color: path.color,
      side: DoubleSide,
      transparent: opacity < 1,
      opacity,
      ...FACES_BEHIND_EDGES,
    });
    const mesh = new Mesh(new ShapeGeometry(path.toShapes()), material);
    mesh.add(edges);
    root.add(mesh);
    const id = /** @type {Element | undefined} */ (path.userData?.node)?.getAttribute('id');
    shapes.push({
      mesh,
      edges,
      part: id || null,
      ghost: false,
      seenThrough: null,
      color: material.color.clone(),
      opacity,
    });
  }
  return { kind: '2d', root, shapes, edgeMaterial };
}

/**
 * A path's outline as line segments, each of its subpaths closed when the path is filled.
 * @param {import('three').ShapePath} path
 * @param {boolean} closed
 * @returns {BufferGeometry}
 */
function outlineOf(path, closed) {
  /** @type {number[]} */
  const positions = [];
  for (const subPath of path.subPaths) {
    const points = subPath.getPoints();
    const count = closed ? points.length : points.length - 1;
    for (let i = 0; i < count; i++) {
      const a = points[i];
      const b = points[(i + 1) % points.length];
      positions.push(a.x, a.y, 0, b.x, b.y, 0);
    }
  }
  return new BufferGeometry().setAttribute('position', new Float32BufferAttribute(positions, 3));
}

/**
 * The materials the model's scene owns: each shape's, a highlight's copy's, and its edges'. A
 * selected shape's edges are drawn with the viewer's material, which isn't the model's to free.
 * @param {SceneModel} model
 * @returns {Set<Material>}
 */
export function ownMaterials(model) {
  return new Set([
    model.edgeMaterial,
    ...model.shapes.flatMap((shape) =>
      [shape.mesh, shape.seenThrough].flatMap((mesh) =>
        mesh ? [/** @type {Material} */ (mesh.material)] : [],
      ),
    ),
  ]);
}

/**
 * Frees the GPU's copies of a scene's geometries and materials.
 * @param {SceneModel} model
 */
export function disposeScene(model) {
  disposeGeometries(model.root);
  for (const material of ownMaterials(model)) material.dispose();
}
