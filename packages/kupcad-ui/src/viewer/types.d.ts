// The shapes of @kupcad/ui/viewer's API. The model it shows is @kupcad/protocol's.

import type { Camera, Color, Group, LineBasicMaterial, LineSegments, Mesh, Object3D } from 'three';

/** The viewer's colours, any CSS colour each. */
export interface Theme {
  background: string;
  grid: string;
  /** The build plate's surface. */
  plate: string;
  /** A solid's feature edges, drawn over its faces. */
  edges: string;
  /** Lines drawn on the background: a wireframe's edges and a drawing's outlines. */
  wire: string;
  /** The selected part's tint and edges. */
  selection: string;
  /** Where a section cuts a solid. */
  cap: string;
  ghost: string;
  /** A solid the script highlights (`.highlight`): seen through whatever hides it too. */
  highlight: string;
}

export type View = 'iso' | 'top' | 'bottom' | 'front' | 'back' | 'right' | 'left';
export type Projection = 'perspective' | 'orthographic';
/** Solids as surfaces with their edges; see-through; their edges alone. */
export type RenderMode = 'solid' | 'xray' | 'wireframe';
/** What the model stands on: a grid sized to it, a build plate, or nothing. */
export type Environment = 'grid' | 'plate' | 'none';
export type Axis = 'x' | 'y' | 'z';

/** A plane across `axis` at `offset` (mm): what is past it is cut away, the far side when `flip`. */
/**
 * Where the camera stands, as plain numbers (`cameraState()`, `restoreCamera()`): what it looks
 * at, the way from there to the camera, how far, and how high the view is at what it looks at,
 * which either projection sees the same; and its named view, if it is in one.
 */
export interface CameraState {
  target: [number, number, number];
  direction: [number, number, number];
  distance: number;
  halfHeight: number;
  view: View | null;
}

export interface Section {
  axis: Axis;
  offset: number;
  flip?: boolean;
}

/** A box in the script's coordinates, in mm. */
export interface Bounds {
  min: [number, number, number];
  max: [number, number, number];
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
  /** Lets the canvas's WebGL context go at once. */
  forceContextLoss(): void;
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
  /**
   * How long the camera takes to move to a view, in ms; 0 moves it at once, as a page that asks
   * for reduced motion does. By default 250.
   */
  motionMs?: number;
}

/** A shape the viewer shows: a solid's copy of a part, a ghost, or a drawing's filled shape. */
export interface Shape {
  mesh: Mesh;
  /** Its feature edges or outline; none for a ghost. */
  edges: LineSegments | null;
  /** The part it is a copy of (a drawing's shape: its name); null for a ghost or a nameless one. */
  part: string | null;
  ghost: boolean;
  /**
   * A highlighted solid's copy, drawn see-through where something hides the solid; null for
   * any other shape.
   */
  seenThrough: Mesh | null;
  /** Its own colour and opacity, which the render mode and the selection change from. */
  color: Color;
  opacity: number;
}

/**
 * A face of a solid, as its feature edges bound it: flat or curved, its area (mm²), and a flat
 * one's way (a unit vector) and the axis it faces along, if one ('+Z (top)').
 */
export interface Face {
  flat: boolean;
  area: number;
  normal: [number, number, number] | null;
  facing: string | null;
}

/** What is under a point of the viewer: the part (null for a nameless one) and, on a solid, the face. */
export interface Hover {
  part: string | null;
  face: Face | null;
}

/** A 'hover' event's detail: what the pointer is over, and where (CSS pixels); null for nothing. */
export type HoverDetail = (Hover & { x: number; y: number }) | null;

/** A model made into a scene, in the script's coordinates. */
export interface SceneModel {
  kind: '3d' | '2d';
  root: Group;
  shapes: Shape[];
  /** The edges' material, shared by every shape but the selected ones. */
  edgeMaterial: LineBasicMaterial;
}
