// The module this package ships, and createKupcad, which runs it in this thread by default. The
// module's URL is named here alone, in what only the page's side of the package loads (this and
// the client, which hands it to its worker): a site's bundler copies kupcad.wasm for each bundle
// that names it, so the worker, given its module, names none, and a site ships the file once.

import { instantiateKupcad } from './kupcad.js';

/** @import { CreateOptions } from './types.js' */
/** @import { Kupcad } from './kupcad.js' */

/** The module this package ships, built by core/build.zig and copied in by `pnpm build`. */
export const DEFAULT_WASM = new URL('../dist/kupcad.wasm', import.meta.url);

/**
 * The core, instantiated in this thread: on `options.wasm`, else on the module this package
 * ships. A long build blocks it: a page runs the core in a worker (`createKupcadWorker`).
 * @param {CreateOptions} [options]
 * @returns {Promise<Kupcad>}
 * @throws {ProtocolError} when the module speaks a protocol version this package doesn't read
 */
export function createKupcad(options = {}) {
  return instantiateKupcad({ ...options, wasm: options.wasm ?? DEFAULT_WASM });
}
