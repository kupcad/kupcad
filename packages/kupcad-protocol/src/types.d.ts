// The shapes the core sends its front ends, field for field as core/src/preview/frame.zig,
// tools/lint/finding.zig, tools/doc/extractor.zig and version.zig write them. A field the core
// may leave out is null, never missing.

/** A preview frame's JSON header (`preview_wasm`, the language server's viewport socket). */
export interface FrameHeader {
  protocolVersion: number;
  /**
   * What the host calls the document: the URI the editor opened it by, which `kupcad.setParams`
   * takes; null from `preview_wasm`.
   */
  document: string | null;
  kind: Kind;
  /** A 3D model's parts; empty otherwise. */
  parts: Part[];
  warnings: Warning[];
  /**
   * What the run printed (`puts`, `print`, `inspect`), as it printed it, for a console; absent
   * from a core before it.
   */
  output?: string;
  /** The run printed more than a run keeps (64 KiB): `output` is the start of it. */
  outputCut?: boolean;
  params: { schema: UiSchema; values: ParamValues };
  /** Why the run failed (`kind` is then 'none'), or null. */
  error: Failure | null;
  /** Milliseconds spent running the script and making the body. */
  timing: { runMs: number; renderMs: number };
}

/** What a frame's body holds: GLB, SVG, or nothing. */
export type Kind = '3d' | '2d' | 'none';

/** A part of a 3D model: the Solids that are copies of one another. */
export interface Part {
  name: string;
  count: number;
  /** The GLB's nodes of its copies, by name: "bolt", "bolt_2". */
  nodes: string[];
  /** "#rrggbb", or null for a part without a colour of its own. */
  color: string | null;
  opacity: number;
  /**
   * Its volume (mm³) and size (its bounding box's extent along x, y and z, mm), as it is made,
   * before its copies are placed: null, or absent from an older core, where it wasn't measured.
   */
  volume?: number | null;
  size?: [number, number, number] | null;
}

/**
 * A warning of the run, where the script was: 1-based line and column (UTF-8 bytes), null where
 * it wasn't running (a warning while the model was meshed).
 */
export interface Warning {
  message: string;
  line: number | null;
  column: number | null;
}

/** Why a run failed, where, and the parameter whose value it refused, and where in it. */
export interface Failure extends Warning {
  param: string | null;
  /** The place in the refused value (`[1, "depth"]` for `:cutouts[1][:depth]`); empty for all of it. */
  path: PathStep[];
}

/** What a frame shows: its body, typed by its kind. */
export type Model =
  /** export_gltf's GLB, each copy of a part a node named as `Part.nodes` says. */
  | { kind: '3d'; glb: Uint8Array; parts: Part[] }
  /** export_svg's drawing, each shape a path with its name as its id. */
  | { kind: '2d'; svg: string }
  | { kind: 'none' };

/** A frame read (`readFrame`): its header, and its model. */
export interface Preview {
  header: FrameHeader;
  model: Model;
}

/** `kupcad doc`'s schema, as `extract_params_wasm` and every frame give it. */
export interface UiSchema {
  meta: Meta;
  parameters: ParamSpec[];
}

/** A script's `@title`, `@description` and `@author` comments. */
export interface Meta {
  title: string | null;
  description: string | null;
  author: string | null;
}

/** A scalar: what a list, a tuple or a Map holds, as JSON gives it (a Symbol as its text). */
export type ParamScalar = number | string | boolean;

/**
 * A parameter's value: a scalar, or an array or an object of values, nested at most
 * `MAX_PARAM_DEPTH` deep (a list of tuples, or of objects whose fields are scalars).
 */
export type ParamValue = ParamScalar | ParamValue[] | { [field: string]: ParamValue };

/**
 * What a value, or a part of it, may be (core/src/core/param_rules.zig's `Rule`). Each rule says
 * only what its kind takes: `min`/`max` a number's, `in` a scalar's, `items` (a list's element)
 * or `tuple` (each place's) an array's, `fields` a Map's.
 */
export interface Rule {
  /** A Symbol parameter is a 'string' with its choices in `in`. */
  type: 'number' | 'string' | 'boolean' | 'array' | 'map';
  min: number | null;
  max: number | null;
  /** The values it may be, when the script lists them as literals. */
  in: ParamScalar[] | null;
  /** A list's rule for each element: of any length, within `min_items` and `max_items`. */
  items: Rule | null;
  /** A tuple's rule for each place: as many elements as it has. */
  tuple: Rule[] | null;
  /** A Map's fields, in order. */
  fields: FieldRule[] | null;
  min_items: number | null;
  max_items: number | null;
  /** What its control is labelled; a host shows the parameter's name, or the field's. */
  title: string | null;
  unit: string | null;
  step: number | null;
}

/** A Map's field: its name, and its value's rule. */
export interface FieldRule extends Rule {
  name: string;
}

/** One `param(:name, ...)` of a script: its rules, its default, where its control goes. */
export interface ParamSpec extends Rule {
  name: string;
  /** Null when there is none (it is nil until given a value), or the default is computed. */
  default_value: ParamValue | null;
  group: string | null;
  /** A line a host shows with its control (`description:`). */
  description: string | null;
}

/** A step into a value: an element's index, or a field's name. */
export type PathStep = number | string;

/** What a model is written as (`kupcad build -f`, `build_model_wasm`): core/src/exporters/format.zig. */
export type ExportFormat = 'stl' | 'glb' | 'gltf' | 'step' | '3mf' | 'obj' | 'svg' | 'dxf';

/** Parameter values by name, as a host gives them and a frame says a run took them. */
export type ParamValues = Record<string, ParamValue>;

/**
 * A place in a source: 1-based lines and columns (UTF-8 bytes), and the byte offset and length
 * an editor counting from the start wants.
 */
export interface Range {
  line: number;
  column: number;
  endLine: number;
  endColumn: number;
  offset: number;
  length: number;
}

/** A finding of `check`, as `check_code_wasm` gives it. */
export interface Finding extends Range {
  severity: 'error' | 'warning' | 'info';
  /** Null for a syntax or compile error. */
  rule: string | null;
  code: string;
  message: string;
  fix: Fix | null;
}

export interface Fix {
  title: string;
  /** It keeps the model the same, so `check --fix` applies it. */
  safe: boolean;
  edits: (Range & { text: string })[];
}

/** A finding of `kupcad check --format json`: the file's path, then the finding. */
export interface CheckFinding extends Finding {
  path: string;
}

/** `kupcad version --json`, and `version_wasm`. */
export interface VersionInfo {
  version: string;
  protocolVersion: number;
  os: string;
  arch: string;
}

/** The language server's `kupcad/viewportReady` notification. */
export interface ViewportReady {
  port: number;
  protocolVersion: number;
}

/** The one argument of the language server's `kupcad.setParams` command. */
export interface SetParamsArgument {
  uri: string;
  values: ParamValues;
}

/** The one argument of the language server's `kupcad.preview` command. */
export interface PreviewArgument {
  uri: string;
}

/** The document a viewer shows: its URI, and the name to title it by. */
export interface ShownDocument {
  uri: string;
  name: string;
}

/** A document's presets: its parameters' values, by the preset's name, in the file's order. */
export type Presets = Record<string, ParamValues>;

/** A viewer's host, as the viewer talks to it: a VS Code extension, the desktop app. */
export interface ViewerHost {
  post(message: ViewerMessage): void;
  /** Calls `listener` with each message the host sends; the function it gives stops it. */
  listen(listener: (message: HostMessage) => void): () => void;
}

/** What a host tells its viewer (`isHostMessage`). */
export type HostMessage =
  /** The document the viewer shows from now on; null for none. */
  | { type: 'document'; document: ShownDocument | null }
  /** The values the host gives a document's parameters, its panel's: on showing it, and after a change of the host's. */
  | { type: 'overrides'; uri: string; values: ParamValues }
  /** The names of a document's presets, in their order. */
  | { type: 'presets'; uri: string; names: string[] }
  /** A line of the host's own log (the language server's), for the viewer's console. */
  | { type: 'log'; text: string };

/** What a viewer asks of its host (`isViewerMessage`). */
export type ViewerMessage =
  /** Its connection to the language server's socket is open: the host asks for the shown document's frame. */
  | { type: 'ready' }
  /** The panel's values for a document changed: the host gives them to the language server, and keeps them. */
  | { type: 'setParams'; uri: string; values: ParamValues }
  /** The document runs with its preset's values. */
  | { type: 'applyPreset'; uri: string; name: string }
  /** The panel's values are kept as one of the document's presets: the host asks its name. */
  | { type: 'savePreset'; uri: string; values: ParamValues }
  /** The document is exported in `format`, with its values: the host asks where. */
  | { type: 'export'; uri: string; format: ExportFormat }
  /** A screenshot, a PNG's bytes in base64, for the host to save. */
  | { type: 'screenshot'; png: string }
  /** Something the viewer couldn't do, for the host's log. */
  | { type: 'problem'; message: string }
  /** The document is shown in its editor at a place its run named: a Warning's line and column. */
  | { type: 'reveal'; uri: string; line: number; column: number }
  /** A setting of the viewer's changed (a pane's size, whether it shows): the host keeps it, for the page it makes next. */
  | { type: 'setting'; key: string; value: SettingValue };

/** What a viewer keeps as a setting (`isSettingValue`): a pane's size, or whether it shows. */
export type SettingValue = number | boolean;
