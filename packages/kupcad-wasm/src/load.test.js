import { readFileSync } from 'node:fs';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { loadModule } from './load.js';
import { readFile } from './read-file.browser.js';

const SHIPPED = new URL('../dist/kupcad.wasm', import.meta.url);
const bytes = () => readFileSync(SHIPPED);

/**
 * The module served as a fetch would give it.
 * @param {string} type its content type
 */
const served = (type) => new Response(bytes(), { headers: { 'content-type': type } });

afterEach(() => vi.unstubAllGlobals());

describe('loadModule', () => {
  it('compiles a Response as it downloads when it is wasm, and once it is all there when not', async () => {
    const streamed = vi.spyOn(WebAssembly, 'compileStreaming');
    try {
      expect(await loadModule(served('application/wasm'))).toBeInstanceOf(WebAssembly.Module);
      expect(streamed).toHaveBeenCalledOnce();
      expect(await loadModule(served('application/octet-stream'))).toBeInstanceOf(
        WebAssembly.Module,
      );
      expect(streamed).toHaveBeenCalledOnce();
    } finally {
      streamed.mockRestore();
    }
  });

  it('fetches an http URL, and refuses what the server refused, saying so', async () => {
    const fetched = vi.fn(async (/** @type {URL} */ url) =>
      url.pathname === '/kupcad.wasm'
        ? served('application/wasm')
        : new Response('', { status: 404, statusText: 'Not Found' }),
    );
    vi.stubGlobal('fetch', fetched);
    expect(await loadModule('https://example.com/kupcad.wasm')).toBeInstanceOf(WebAssembly.Module);
    await expect(loadModule(new URL('https://example.com/missing.wasm'))).rejects.toThrow(
      'kupcad.wasm: 404 Not Found',
    );
    expect(fetched).toHaveBeenCalledTimes(2);
  });

  it("can't read a file: URL in a browser, and says what to give instead", async () => {
    await expect(readFile(SHIPPED)).rejects.toThrow(/give the module by URL or as bytes/);
  });
});
