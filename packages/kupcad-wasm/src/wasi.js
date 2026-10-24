// WASI (preview 1) for kupcad.wasm: what its C and Zig runtimes ask of a host, answered
// without one, the same in a browser and in Node. The module keeps the files scripts read in
// its own memory (`put_file_wasm`), so it gets no file system: no directory is preopened and
// every file call answers ENOSYS. Its clocks and randomness are the host's, and what it writes
// to stdout and stderr, its log, goes to a callback a line at a time.

const ERRNO = { SUCCESS: 0, BADF: 8, INVAL: 28, NOSYS: 52 };
const CLOCK = { REALTIME: 0, MONOTONIC: 1, PROCESS_CPUTIME: 2, THREAD_CPUTIME: 3 };
const FILETYPE_CHARACTER_DEVICE = 2;
const STDOUT = 1;
const STDERR = 2;
/** The clocks' resolution, in nanoseconds: a microsecond. */
const CLOCK_RESOLUTION_NS = 1000n;
const NS_PER_MS = 1_000_000;
/** The most `crypto.getRandomValues` fills at once. */
const RANDOM_CHUNK_BYTES = 65536;
/** `__wasi_fdstat_t`: a u8 file type, u16 flags, two u64 rights. */
const FDSTAT_BYTES = 24;
/** `__wasi_ciovec_t`: a u32 pointer and a u32 length. */
const IOVEC_BYTES = 8;

/** The module called `proc_exit`: it stopped, and its instance can't be used again. */
export class WasiExit extends Error {
  /** @param {number} code */
  constructor(code) {
    super(`kupcad.wasm exited with code ${code}`);
    this.name = 'WasiExit';
    this.code = code;
  }
}

/**
 * The WASI imports of a module, and the memory they work in, which the instance gives once it
 * exists (`bind`).
 * @param {(line: string) => void} log where the module's log goes, a line at a time
 */
export function createWasi(log) {
  /** @type {WebAssembly.Memory | null} */
  let memory = null;
  /** @type {Map<number, { decoder: TextDecoder, line: string }>} */
  const streams = new Map([
    [STDOUT, { decoder: new TextDecoder(), line: '' }],
    [STDERR, { decoder: new TextDecoder(), line: '' }],
  ]);
  const view = () => new DataView(/** @type {WebAssembly.Memory} */ (memory).buffer);
  const bytes = () => new Uint8Array(/** @type {WebAssembly.Memory} */ (memory).buffer);

  /** @type {Record<string, (...args: any[]) => number>} */
  const calls = {
    /** @param {number} id @param {number} out */
    clock_res_get(id, out) {
      if (!Object.values(CLOCK).includes(id)) return ERRNO.INVAL;
      view().setBigUint64(out, CLOCK_RESOLUTION_NS, true);
      return ERRNO.SUCCESS;
    },
    /** @param {number} id @param {bigint} _precision @param {number} out */
    clock_time_get(id, _precision, out) {
      let ns;
      if (id === CLOCK.REALTIME) ns = BigInt(Date.now()) * BigInt(NS_PER_MS);
      else if (Object.values(CLOCK).includes(id))
        ns = BigInt(Math.round(performance.now() * NS_PER_MS));
      else return ERRNO.INVAL;
      view().setBigUint64(out, ns, true);
      return ERRNO.SUCCESS;
    },
    /** @param {number} buf @param {number} len */
    random_get(buf, len) {
      for (let at = 0; at < len; at += RANDOM_CHUNK_BYTES) {
        crypto.getRandomValues(
          bytes().subarray(buf + at, buf + Math.min(len, at + RANDOM_CHUNK_BYTES)),
        );
      }
      return ERRNO.SUCCESS;
    },
    /** @param {number} fd @param {number} iovs @param {number} count @param {number} nwritten */
    fd_write(fd, iovs, count, nwritten) {
      const stream = streams.get(fd);
      if (!stream) return ERRNO.BADF;
      let written = 0;
      for (let i = 0; i < count; i++) {
        const ptr = view().getUint32(iovs + i * IOVEC_BYTES, true);
        const len = view().getUint32(iovs + i * IOVEC_BYTES + 4, true);
        stream.line += stream.decoder.decode(bytes().subarray(ptr, ptr + len), { stream: true });
        written += len;
      }
      const lines = stream.line.split('\n');
      stream.line = /** @type {string} */ (lines.pop());
      for (const line of lines) log(line);
      view().setUint32(nwritten, written, true);
      return ERRNO.SUCCESS;
    },
    /** @param {number} fd @param {number} out */
    fd_fdstat_get(fd, out) {
      if (fd > STDERR) return ERRNO.BADF;
      bytes().fill(0, out, out + FDSTAT_BYTES);
      view().setUint8(out, FILETYPE_CHARACTER_DEVICE);
      return ERRNO.SUCCESS;
    },
    // No directory is preopened: wasi-libc asks from fd 3 on, until this
    fd_prestat_get: () => ERRNO.BADF,
    /** @param {number} code */
    proc_exit(code) {
      throw new WasiExit(code);
    },
  };

  return {
    /**
     * The `wasi_snapshot_preview1` functions `module` imports: each one this answers, the rest
     * ENOSYS.
     * @param {WebAssembly.Module} module
     * @returns {Record<string, (...args: any[]) => number>}
     */
    imports(module) {
      /** @type {Record<string, (...args: any[]) => number>} */
      const out = {};
      for (const { module: from, name } of WebAssembly.Module.imports(module)) {
        if (from === 'wasi_snapshot_preview1') out[name] = calls[name] ?? (() => ERRNO.NOSYS);
      }
      return out;
    },
    /** @param {WebAssembly.Memory} instanceMemory the module's memory, once it is instantiated */
    bind(instanceMemory) {
      memory = instanceMemory;
    },
  };
}
