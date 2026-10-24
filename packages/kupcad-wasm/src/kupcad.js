// The core in this thread: the module instantiated once, its exports given a typed face. Every
// string and buffer goes in through `wasm_alloc` and is freed after the call; every result is
// copied out and freed (`wasm_free`), and an export's null result is the core's refusal, its
// message read from `get_last_error`.

import { isCompatible, PROTOCOL_VERSION, ProtocolError, readFrame } from '@kupcad/protocol';
import { KupcadCrashError, KupcadError } from './errors.js';
import { loadModule } from './load.js';
import { createWasi, WasiExit } from './wasi.js';

/** @import { Finding, Preview, UiSchema, VersionInfo } from '@kupcad/protocol/types' */
/** @import { BuildOptions, CallOptions, CreateOptions, KupcadApi, KupcadExports, KupcadFiles, PreviewOptions } from './types.js' */

/** The module this package ships, built by core/build.zig and copied in by `pnpm build`. */
const DEFAULT_WASM = new URL('../dist/kupcad.wasm', import.meta.url);
/** A `usize` of wasm32: the slot an export writes its result's length to. */
const USIZE_BYTES = 4;
/** The longest message get_last_error holds (core/src/wasm.zig's MAX_ERROR_MSG_LEN). */
const MAX_ERROR_BYTES = 1024;
const DEFAULT_FORMAT = 'glb';

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/**
 * A wasm32 pointer an export returned: a u32 that JavaScript gets as an i32, so an address
 * past 2 GiB comes negative, as does an empty block's (0xFFFFFFFF, which `wasm_alloc(0)` gives).
 * @param {number} ptr
 */
const address = (ptr) => ptr >>> 0;

/**
 * The core, instantiated in this thread. A long build blocks it: a page runs the core in a
 * worker (`createKupcadWorker`).
 * @param {CreateOptions} [options]
 * @returns {Promise<Kupcad>}
 * @throws {ProtocolError} when the module speaks a protocol version this package doesn't read
 */
export async function createKupcad(options = {}) {
  const module = await loadModule(options.wasm ?? DEFAULT_WASM);
  const wasi = createWasi(options.log ?? ((line) => console.debug(line)));
  const instance = await WebAssembly.instantiate(module, {
    wasi_snapshot_preview1: wasi.imports(module),
  });
  const exports = /** @type {KupcadExports} */ (/** @type {unknown} */ (instance.exports));
  wasi.bind(exports.memory);
  // oxlint-disable-next-line no-underscore-dangle -- the WASI reactor's initializer, by that name
  exports._initialize();
  return Kupcad.fromExports(exports);
}

/** @implements {KupcadApi} */
export class Kupcad {
  /**
   * The core over a module a host instantiated itself (its own WASI, its own memory), once it
   * is initialized.
   * @param {KupcadExports} exports
   * @returns {Promise<Kupcad>}
   * @throws {ProtocolError} when the module speaks a protocol version this package doesn't read
   */
  static async fromExports(exports) {
    const kupcad = new Kupcad(exports);
    const { version, protocolVersion } = await kupcad.version();
    if (!isCompatible(protocolVersion)) {
      throw new ProtocolError(
        `kupcad.wasm ${version} speaks protocol version ${protocolVersion}; this package reads version ${PROTOCOL_VERSION}`,
      );
    }
    return kupcad;
  }

  /** @type {KupcadExports} */
  #exports;
  /** Where every export writes its result's length. */
  #outLen;
  /** Why the module can't be used again, once it stopped. @type {KupcadCrashError | null} */
  #crashed = null;
  /** @type {KupcadFiles} */
  files;

  /** @param {KupcadExports} exports an instantiated, initialized kupcad.wasm's */
  constructor(exports) {
    this.#exports = exports;
    this.#outLen = address(exports.wasm_alloc(USIZE_BYTES));
    if (this.#outLen === 0) throw new KupcadError('kupcad.wasm has no memory to start in');
    this.files = {
      put: async (path, data) =>
        this.#run(() => {
          const stored = this.#withInputs([path, data], ([p, d]) =>
            this.#exports.put_file_wasm(p.ptr, p.len, d.ptr, d.len),
          );
          if (!stored) throw new KupcadError(`kupcad.wasm couldn't keep ${path}: out of memory`);
        }),
      clear: async () => this.#run(() => this.#exports.clear_vfs_wasm()),
    };
  }

  /** The module's linear memory, in bytes: it grows as builds need, and stays grown. */
  get memoryBytes() {
    return this.#exports.memory.buffer.byteLength;
  }

  /**
   * @param {string} source
   * @param {PreviewOptions} [options]
   * @returns {Promise<Preview>}
   */
  async preview(source, options = {}) {
    options.signal?.throwIfAborted();
    const params = options.params ? JSON.stringify(options.params) : '';
    return this.#run(() =>
      readFrame(
        this.#withInputs([source, params], ([s, p]) =>
          this.#take(this.#exports.preview_wasm(s.ptr, s.len, p.ptr, p.len, this.#outLen)),
        ),
      ),
    );
  }

  /**
   * @param {string} source
   * @param {BuildOptions} [options]
   * @returns {Promise<Uint8Array>}
   */
  async build(source, options = {}) {
    options.signal?.throwIfAborted();
    const params = options.params ? JSON.stringify(options.params) : '';
    const format = options.format ?? DEFAULT_FORMAT;
    const draco = options.draco ? 1 : 0;
    return this.#run(() =>
      this.#withInputs([source, params, format], ([s, p, f]) =>
        this.#take(
          this.#exports.build_model_wasm(
            s.ptr,
            s.len,
            p.ptr,
            p.len,
            f.ptr,
            f.len,
            draco,
            this.#outLen,
          ),
        ),
      ),
    );
  }

  /**
   * @param {string} source
   * @param {CallOptions} [options]
   * @returns {Promise<Finding[]>}
   */
  async check(source, options = {}) {
    options.signal?.throwIfAborted();
    return this.#run(() => JSON.parse(this.#text(this.#exports.check_code_wasm, source)));
  }

  /**
   * @param {string} source
   * @param {CallOptions} [options]
   * @returns {Promise<string>}
   */
  async format(source, options = {}) {
    options.signal?.throwIfAborted();
    return this.#run(() => this.#text(this.#exports.format_code_wasm, source));
  }

  /**
   * @param {string} source
   * @param {CallOptions} [options]
   * @returns {Promise<UiSchema>}
   */
  async params(source, options = {}) {
    options.signal?.throwIfAborted();
    return this.#run(() => JSON.parse(this.#text(this.#exports.extract_params_wasm, source)));
  }

  /** @returns {Promise<VersionInfo>} */
  async version() {
    return this.#run(() =>
      JSON.parse(decoder.decode(this.#take(this.#exports.version_wasm(this.#outLen)))),
    );
  }

  /**
   * Runs `work` unless the module stopped; a trap or an exit in it stops the module for good.
   * @template T
   * @param {() => T} work
   * @returns {T}
   */
  #run(work) {
    if (this.#crashed) throw this.#crashed;
    try {
      return work();
    } catch (err) {
      if (!(err instanceof WebAssembly.RuntimeError || err instanceof WasiExit)) throw err;
      this.#crashed = new KupcadCrashError(`kupcad.wasm stopped: ${err.message}`, { cause: err });
      throw this.#crashed;
    }
  }

  /**
   * The text an export of one source gives (check, format, params).
   * @param {(source: number, sourceLen: number, outLen: number) => number} exported
   * @param {string} source
   * @returns {string}
   */
  #text(exported, source) {
    return decoder.decode(
      this.#withInputs([source], ([s]) => this.#take(exported(s.ptr, s.len, this.#outLen))),
    );
  }

  /**
   * Copies `inputs` into the module's memory for `call`, and frees them after.
   * @template T
   * @param {(string | Uint8Array)[]} inputs
   * @param {(placed: { ptr: number, len: number }[]) => T} call
   * @returns {T}
   */
  #withInputs(inputs, call) {
    /** @type {{ ptr: number, len: number }[]} */
    const placed = [];
    try {
      for (const input of inputs) {
        const bytes = typeof input === 'string' ? encoder.encode(input) : input;
        const ptr = address(this.#exports.wasm_alloc(bytes.byteLength));
        if (ptr === 0)
          throw new KupcadError(`kupcad.wasm has no room for ${bytes.byteLength} bytes`);
        placed.push({ ptr, len: bytes.byteLength });
        if (bytes.byteLength > 0) {
          new Uint8Array(this.#exports.memory.buffer, ptr, bytes.byteLength).set(bytes);
        }
      }
      return call(placed);
    } finally {
      for (const { ptr, len } of placed) this.#exports.wasm_free(ptr, len);
    }
  }

  /**
   * An export's result, copied out of the module's memory and freed there; its null is the
   * core's refusal.
   * @param {number} result
   * @returns {Uint8Array}
   */
  #take(result) {
    const ptr = address(result);
    if (ptr === 0) throw new KupcadError(this.#lastError());
    const len = new DataView(this.#exports.memory.buffer).getUint32(this.#outLen, true);
    const bytes =
      len > 0 ? new Uint8Array(this.#exports.memory.buffer, ptr, len).slice() : new Uint8Array();
    this.#exports.wasm_free(ptr, len);
    return bytes;
  }

  #lastError() {
    const at = address(this.#exports.get_last_error());
    const bytes = new Uint8Array(this.#exports.memory.buffer, at, MAX_ERROR_BYTES);
    const end = bytes.indexOf(0);
    return decoder.decode(bytes.subarray(0, end === -1 ? MAX_ERROR_BYTES : end));
  }
}
