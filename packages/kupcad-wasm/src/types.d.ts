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

/** The files a script reads (`import_json`, `import_stl`, an imported module), in the module. */
export interface KupcadFiles {
  put(path: string, data: Uint8Array | string): Promise<void>;
  clear(): Promise<void>;
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
  readonly files: KupcadFiles;
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
    outLen: number,
  ): number;
  build_model_wasm(
    source: number,
    sourceLen: number,
    params: number,
    paramsLen: number,
    format: number,
    formatLen: number,
    draco: number,
    outLen: number,
  ): number;
  check_code_wasm(source: number, sourceLen: number, outLen: number): number;
  format_code_wasm(source: number, sourceLen: number, outLen: number): number;
  extract_params_wasm(source: number, sourceLen: number, outLen: number): number;
  version_wasm(outLen: number): number;
  put_file_wasm(path: number, pathLen: number, data: number, dataLen: number): number;
  clear_vfs_wasm(): void;
}

/** Where a worker's module comes from: what can be posted to it. */
export type WorkerWasmSource = WebAssembly.Module | BufferSource | URL | string;

export interface WorkerOptions {
  /** The module; by default the kupcad.wasm this package ships. */
  wasm?: WorkerWasmSource;
  /** Where the module's log goes, a line at a time (a failure is thrown too); by default console.debug. */
  log?: (line: string) => void;
  /** Starts a worker running src/worker.js; by default a module Web Worker. */
  worker?: () => WorkerLike;
}

/** What a client calls the worker's core with: the methods of KupcadApi and its files'. */
export type Method =
  | 'preview'
  | 'build'
  | 'check'
  | 'format'
  | 'params'
  | 'version'
  | 'putFile'
  | 'clearFiles';

/** A failure, as it crosses to the client: `fatal` when the worker's core can't go on. */
export interface SentError {
  name: string;
  message: string;
  fatal: boolean;
}

export type ToWorker =
  | {
      type: 'init';
      wasm: WebAssembly.Module | BufferSource | string | undefined;
      files: [string, Uint8Array | string][];
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
  terminate(): void;
}

/** The worker's end: its global scope, or a MessagePort in tests. */
export interface PortLike {
  postMessage(message: FromWorker, transfer?: Transferable[]): void;
  addEventListener(type: 'message', listener: (event: MessageEvent<ToWorker>) => void): void;
}
