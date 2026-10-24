import { describe, expect, it } from 'vitest';
import { createWasi, WasiExit } from './wasi.js';

const ERRNO = { SUCCESS: 0, BADF: 8, INVAL: 28, NOSYS: 52 };

/**
 * An unsigned LEB128, as a wasm binary writes sizes and counts.
 * @param {number} n
 * @returns {number[]}
 */
function leb(n) {
  const out = [];
  do {
    const byte = n & 0x7f;
    n >>>= 7;
    out.push(n ? byte | 0x80 : byte);
  } while (n);
  return out;
}

/**
 * A module that only imports, each a function of no arguments: `names` from WASI, `other`
 * from another module.
 * @param {string[]} names
 * @param {string[]} [other]
 * @returns {WebAssembly.Module}
 */
function importing(names, other = []) {
  const encoder = new TextEncoder();
  /** @param {string} text */
  const name = (text) => [...leb(encoder.encode(text).length), ...encoder.encode(text)];
  /** @param {number} id @param {number[]} body */
  const section = (id, body) => [id, ...leb(body.length), ...body];
  const entries = [
    ...names.map((field) => [...name('wasi_snapshot_preview1'), ...name(field), 0x00, 0x00]),
    ...other.map((field) => [...name('env'), ...name(field), 0x00, 0x00]),
  ];
  const bytes = [
    0x00,
    0x61,
    0x73,
    0x6d,
    0x01,
    0x00,
    0x00,
    0x00,
    ...section(1, [0x01, 0x60, 0x00, 0x00]),
    ...section(2, [...leb(entries.length), ...entries.flat()]),
  ];
  return new WebAssembly.Module(new Uint8Array(bytes));
}

const CALLS = [
  'clock_res_get',
  'clock_time_get',
  'random_get',
  'fd_write',
  'fd_fdstat_get',
  'fd_prestat_get',
  'proc_exit',
];

/**
 * The WASI calls over a memory of their own, and what they logged.
 * @returns {{ calls: Record<string, (...args: any[]) => number>, memory: WebAssembly.Memory, logged: string[] }}
 */
function wasiOver() {
  /** @type {string[]} */
  const logged = [];
  const wasi = createWasi((line) => logged.push(line));
  const memory = new WebAssembly.Memory({ initial: 4 });
  wasi.bind(memory);
  return { calls: wasi.imports(importing(CALLS)), memory, logged };
}

/**
 * Writes `chunks` to the memory as iovecs at 0 (the chunks' bytes from 1024), for fd_write.
 * @param {WebAssembly.Memory} memory
 * @param {Uint8Array[]} chunks
 */
function iovecs(memory, chunks) {
  const view = new DataView(memory.buffer);
  let at = 1024;
  chunks.forEach((chunk, i) => {
    view.setUint32(i * 8, at, true);
    view.setUint32(i * 8 + 4, chunk.byteLength, true);
    new Uint8Array(memory.buffer).set(chunk, at);
    at += chunk.byteLength;
  });
}

describe('createWasi', () => {
  it('answers each WASI call a module imports, ENOSYS where it has none, and nothing of another module', () => {
    const imports = createWasi(() => {}).imports(
      importing(['fd_write', 'poll_oneoff', 'path_open'], ['other']),
    );
    expect(Object.keys(imports).toSorted()).toEqual(['fd_write', 'path_open', 'poll_oneoff']);
    expect(imports.poll_oneoff()).toBe(ERRNO.NOSYS);
    expect(imports.path_open()).toBe(ERRNO.NOSYS);
  });

  it('gives what stdout and stderr write to the log a line at a time, a character split across writes whole', () => {
    const { calls, memory, logged } = wasiOver();
    const encoder = new TextEncoder();
    const e = encoder.encode('é');
    iovecs(memory, [encoder.encode('line one\nline '), encoder.encode('t')]);
    expect(calls.fd_write(2, 0, 2, 512)).toBe(ERRNO.SUCCESS);
    expect(new DataView(memory.buffer).getUint32(512, true)).toBe(15);
    iovecs(memory, [encoder.encode('wo caf'), e.subarray(0, 1)]);
    calls.fd_write(2, 0, 2, 512);
    iovecs(memory, [e.subarray(1), encoder.encode('\n')]);
    calls.fd_write(2, 0, 2, 512);
    expect(logged).toEqual(['line one', 'line two café']);
    iovecs(memory, [encoder.encode('out\n')]);
    calls.fd_write(1, 0, 1, 512);
    expect(logged.at(-1)).toBe('out');
    expect(calls.fd_write(3, 0, 1, 512)).toBe(ERRNO.BADF);
  });

  it("gives the host's clocks, in nanoseconds, and refuses a clock there isn't", () => {
    const { calls, memory } = wasiOver();
    const view = new DataView(memory.buffer);
    expect(calls.clock_time_get(0, 0n, 8)).toBe(ERRNO.SUCCESS);
    const realtimeMs = Number(view.getBigUint64(8, true) / 1_000_000n);
    expect(Math.abs(realtimeMs - Date.now())).toBeLessThan(1000);
    calls.clock_time_get(1, 0n, 8);
    const before = view.getBigUint64(8, true);
    calls.clock_time_get(1, 0n, 8);
    expect(view.getBigUint64(8, true)).toBeGreaterThanOrEqual(before);
    expect(calls.clock_res_get(1, 16)).toBe(ERRNO.SUCCESS);
    expect(view.getBigUint64(16, true)).toBe(1000n);
    expect(calls.clock_time_get(9, 0n, 8)).toBe(ERRNO.INVAL);
  });

  it('fills a buffer with random bytes, past what crypto gives at once', () => {
    const { calls, memory } = wasiOver();
    const len = 100_000;
    expect(calls.random_get(4096, len)).toBe(ERRNO.SUCCESS);
    const filled = new Uint8Array(memory.buffer, 4096, len);
    // Each 64 KiB chunk got its bytes
    expect(filled.subarray(0, 1024).some((b) => b !== 0)).toBe(true);
    expect(filled.subarray(len - 1024).some((b) => b !== 0)).toBe(true);
  });

  it('has stdin, stdout and stderr, and no preopened directory', () => {
    const { calls, memory } = wasiOver();
    expect(calls.fd_fdstat_get(2, 32)).toBe(ERRNO.SUCCESS);
    expect(new Uint8Array(memory.buffer)[32]).toBe(2);
    expect(calls.fd_fdstat_get(3, 32)).toBe(ERRNO.BADF);
    expect(calls.fd_prestat_get(3, 32)).toBe(ERRNO.BADF);
  });

  it('stops the module when it exits', () => {
    const { calls } = wasiOver();
    expect(() => calls.proc_exit(3)).toThrow(new WasiExit(3));
  });
});
