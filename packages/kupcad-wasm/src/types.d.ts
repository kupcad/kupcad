// The shapes of @kupcad/wasm's API. What the core gives back is @kupcad/protocol's.

import type {
  ExportFormat,
  Finding,
  ParamValues,
  Preview,
  UiSchema,
  VersionInfo,
} from '@kupcad/protocol/types';

/** Where the module comes from: compiled, its bytes, a fetch Response, or a URL. */
export type WasmSource = WebAssembly.Module | BufferSource | Response | URL | string;

/** What a call may be stopped by. */
export interface CallOptions {
  signal?: AbortSignal;
}

export interface PreviewOptions extends CallOptions {
  /** The parameters' values; those not given take their defaults. */
  params?: ParamValues;
  /**
   * The files the script reads, by the paths it names them by (`import { } from "./lib.kup"`
   * reads `lib.kup`, `import_json("data/size.json")` reads `data/size.json`): a module it
   * imports, data it reads. The core keeps them for this call alone.
   */
  files?: Record<string, Uint8Array | string>;
}

export interface BuildOptions extends PreviewOptions {
  /** Default 'glb'. */
  format?: ExportFormat;
  /** Draco-compressed meshes, for glb and gltf. */
  draco?: boolean;
}

export interface CreateOptions {
  /** The module; by default the kupcad.wasm this package ships. */
  wasm?: WasmSource;
  /** Where the module's log goes, a line at a time (a failure is thrown too); by default console.debug. */
  log?: (line: string) => void;
}

/** What both `createKupcad` and `createKupcadWorker` give. */
export interface KupcadApi {
  /** The script's preview frame: a run that fails, or values refused, is a frame saying why. */
  preview(source: string, options?: PreviewOptions): Promise<Preview>;
  /** The script's model written as `format`; a KupcadError says why it couldn't be. */
  build(source: string, options?: BuildOptions): Promise<Uint8Array>;
  /** `kupcad check`'s findings, syntax errors among them. */
  check(source: string, options?: CallOptions): Promise<Finding[]>;
  /** The source as `kupcad fmt` writes it; a KupcadError for one that doesn't parse. */
  format(source: string, options?: CallOptions): Promise<string>;
  /** The parameters' schema, as `kupcad doc` gives it, without running the script. */
  params(source: string, options?: CallOptions): Promise<UiSchema>;
  /** What the module says of itself. */
  version(): Promise<VersionInfo>;
}

/** The exports of kupcad.wasm (core/src/wasm.zig). Pointers and lengths are byte offsets. */
export interface KupcadExports {
  memory: WebAssembly.Memory;
  _initialize(): void;
  wasm_alloc(len: number): number;
  wasm_free(ptr: number, len: number): void;
  get_last_error(): number;
  preview_wasm(
    source: number,
    sourceLen: number,
    params: number,
    paramsLen: number,
    files: number,
    filesLen: number,
    outLen: number,
  ): number;
  build_model_wasm(
    source: number,
    sourceLen: number,
    params: number,
    paramsLen: number,
    files: number,
    filesLen: number,
    format: number,
    formatLen: number,
    draco: number,
    outLen: number,
  ): number;
  check_code_wasm(source: number, sourceLen: number, outLen: number): number;
  format_code_wasm(source: number, sourceLen: number, outLen: number): number;
  extract_params_wasm(source: number, sourceLen: number, outLen: number): number;
  version_wasm(outLen: number): number;
}

/** Where a worker's module comes from: what can be posted to it (not a Response). */
export type WorkerWasmSource = Exclude<WasmSource, Response>;

export interface WorkerOptions extends Omit<CreateOptions, 'wasm'> {
  /** The module; by default the kupcad.wasm this package ships. A relative URL is the page's. */
  wasm?: WorkerWasmSource;
  /** Starts a worker running src/worker.js; by default a module Web Worker. */
  worker?: () => WorkerLike;
}

/** What a client calls the worker's core with: the methods of KupcadApi. */
export type Method = 'preview' | 'build' | 'check' | 'format' | 'params' | 'version';

/** A failure, as it crosses to the client: `fatal` when the worker's core can't go on. */
export interface SentError {
  name: string;
  message: string;
  fatal: boolean;
}

export type ToWorker =
  | {
      type: 'init';
      /** A URL as its href. */
      wasm: Exclude<WorkerWasmSource, URL> | undefined;
    }
  | { type: 'call'; id: number; method: Method; args: unknown[] };

export type FromWorker =
  | { type: 'reply'; id: number; ok: true; value: unknown }
  | { type: 'reply'; id: number; ok: false; error: SentError }
  | { type: 'log'; line: string };

/** The client's end of a worker: a Web Worker, or a stand-in in tests. */
export interface WorkerLike {
  postMessage(message: ToWorker): void;
  addEventListener(type: 'message', listener: (event: MessageEvent<FromWorker>) => void): void;
  addEventListener(type: 'error', listener: (event: ErrorEvent) => void): void;
  addEventListener(type: 'messageerror', listener: (event: MessageEvent) => void): void;
  terminate(): void;
}

/** The worker's end: its global scope, or a MessagePort in tests. */
export interface PortLike {
  postMessage(message: FromWorker, transfer?: Transferable[]): void;
  addEventListener(type: 'message', listener: (event: MessageEvent<ToWorker>) => void): void;
}
