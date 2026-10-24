// The shapes of @kupcad/viewer's API. The model it shows is @kupcad/protocol's.

import type { Camera, Color, Group, LineBasicMaterial, LineSegments, Mesh, Object3D } from 'three';

/** The viewer's colours, any CSS colour each. */
export interface Theme {
  background: string;
  grid: string;
  /** The build plate's surface. */
  plate: string;
  /** A solid's feature edges, and a drawing's outlines. */
  edges: string;
  /** The selected part's tint and edges. */
  selection: string;
  /** Where a section cuts a solid. */
  cap: string;
  ghost: string;
}

export type View = 'iso' | 'top' | 'bottom' | 'front' | 'back' | 'right' | 'left';
export type Projection = 'perspective' | 'orthographic';
/** Solids as surfaces with their edges; see-through; their edges alone. */
export type RenderMode = 'solid' | 'xray' | 'wireframe';
/** What the model stands on: a grid sized to it, a build plate, or nothing. */
export type Environment = 'grid' | 'plate' | 'none';
export type Axis = 'x' | 'y' | 'z';

/** A plane across `axis` at `offset` (mm): what is past it is cut away, the far side when `flip`. */
export interface Section {
  axis: Axis;
  offset: number;
  flip?: boolean;
}

/** A build plate's size, in mm. */
export interface Plate {
  width: number;
  depth: number;
}

/** What the viewer draws with: a WebGLRenderer, or a stand-in in tests. */
export interface RendererLike {
  localClippingEnabled: boolean;
  setPixelRatio(ratio: number): void;
  setSize(width: number, height: number, updateStyle?: boolean): void;
  render(scene: Object3D, camera: Camera): void;
  dispose(): void;
}

export interface ViewerOptions {
  theme?: Theme;
  environment?: Environment;
  /** The build plate's size; by default 256 × 256 mm. */
  plate?: Plate;
  /** Where three.js's Draco decoder files are, for a model built with `--draco`. */
  dracoDecoderPath?: string;
  /** Makes the renderer for the canvas; by default a WebGLRenderer. */
  renderer?: (canvas: HTMLCanvasElement) => RendererLike;
}

/** A shape the viewer shows: a solid's copy of a part, a ghost, or a drawing's filled shape. */
export interface Shape {
  mesh: Mesh;
  /** Its feature edges or outline; none for a ghost. */
  edges: LineSegments | null;
  /** The part it is a copy of (a drawing's shape: its name); null for a ghost or a nameless one. */
  part: string | null;
  ghost: boolean;
  /** Its own colour and opacity, which the render mode and the selection change from. */
  color: Color;
  opacity: number;
}

/** A model made into a scene, in the script's coordinates. */
export interface SceneModel {
  kind: '3d' | '2d';
  root: Group;
  shapes: Shape[];
  /** The edges' material, shared by every shape but the selected ones. */
  edgeMaterial: LineBasicMaterial;
}
