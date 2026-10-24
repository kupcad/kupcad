// A browser can't read a `file:` URL (#read-file); a page gives the module by an http(s) URL,
// its bytes or a compiled WebAssembly.Module.

/**
 * @param {URL} url
 * @returns {Promise<Uint8Array<ArrayBuffer>>}
 */
export async function readFile(url) {
  throw new Error(
    `kupcad.wasm: a browser can't read ${url.href}; give the module by URL or as bytes`,
  );
}
