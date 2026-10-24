// The compiled module from what a host gives: a compiled WebAssembly.Module, its bytes, a
// fetch Response, or a URL (a `file:` one read from the disk in Node).

import { readFile } from '#read-file';

/** @import { WasmSource } from './types.js' */

/**
 * @param {WasmSource} source
 * @returns {Promise<WebAssembly.Module>}
 */
export async function loadModule(source) {
  if (source instanceof WebAssembly.Module) return source;
  if (source instanceof ArrayBuffer || ArrayBuffer.isView(source))
    return WebAssembly.compile(source);
  if (source instanceof Response) return compileResponse(source);
  const url = new URL(source, globalThis.location?.href);
  if (url.protocol === 'file:') return WebAssembly.compile(await readFile(url));
  return compileResponse(await fetch(url));
}

/**
 * Compiles while it downloads when the server says it is wasm; compileStreaming refuses
 * another content type, so then the bytes are compiled once they are all there.
 * @param {Response} response
 * @returns {Promise<WebAssembly.Module>}
 */
async function compileResponse(response) {
  if (!response.ok) {
    throw new Error(`kupcad.wasm: ${response.status} ${response.statusText} from ${response.url}`);
  }
  if (response.headers.get('content-type')?.startsWith('application/wasm')) {
    return WebAssembly.compileStreaming(response);
  }
  return WebAssembly.compile(await response.arrayBuffer());
}
