// When the playground runs the script: once it stays as it is for a moment (DELAY_MS) after an
// edit, and at once when a parameter's value changes or the playground starts. A run under way
// when the next starts is stopped (the core's worker drops or ends its call), so what comes is
// the last script's. A run is the script's findings (`check`, quick: the editor marks them
// first), then its preview (the model, its parameters, why it failed), the files its imports
// read given with it.

/** @import { Finding, ParamValues, Preview } from '@kupcad/protocol/types' */
/** @import { KupcadApi, PreviewOptions } from '@kupcad/wasm/types' */

/** How long the script stays as it is after an edit before it runs. */
export const DELAY_MS = 300;

/**
 * What a run gives, each with the script it is of.
 * @typedef {object} RunHandlers
 * @property {(findings: Finding[], source: string) => void} onfindings
 * @property {(preview: Preview, source: string) => void} onpreview
 * @property {(error: unknown) => void} onerror a call failed (one stopped for the next didn't)
 */

export class Runner {
  /** @type {Pick<KupcadApi, 'check' | 'preview'>} */
  #kupcad;
  /** @type {RunHandlers} */
  #handlers;
  #delayMs;
  /** @type {ReturnType<typeof setTimeout> | undefined} */
  #waiting;
  /** The run under way, which the next stops. @type {AbortController | null} */
  #running = null;

  /**
   * @param {Pick<KupcadApi, 'check' | 'preview'>} kupcad
   * @param {RunHandlers} handlers
   * @param {{ delayMs?: number }} [options]
   */
  constructor(kupcad, handlers, { delayMs = DELAY_MS } = {}) {
    this.#kupcad = kupcad;
    this.#handlers = handlers;
    this.#delayMs = delayMs;
  }

  /**
   * Runs `source` with `values` once it stays so for the delay (a later call waits again), or at
   * once; with `files`, what its imports read.
   * @param {string} source
   * @param {ParamValues} values
   * @param {{ now?: boolean, files?: PreviewOptions['files'] }} [options]
   */
  run(source, values, { now = false, files } = {}) {
    clearTimeout(this.#waiting);
    if (now) void this.#start(source, values, files);
    else this.#waiting = setTimeout(() => void this.#start(source, values, files), this.#delayMs);
  }

  /** Runs nothing more, and stops the run under way. */
  dispose() {
    clearTimeout(this.#waiting);
    this.#running?.abort();
    this.#running = null;
  }

  /**
   * @param {string} source
   * @param {ParamValues} values
   * @param {PreviewOptions['files']} files
   */
  async #start(source, values, files) {
    this.#running?.abort();
    const running = new AbortController();
    this.#running = running;
    const { signal } = running;
    try {
      const findings = await this.#kupcad.check(source, { signal });
      if (signal.aborted) return;
      this.#handlers.onfindings(findings, source);
      const preview = await this.#kupcad.preview(source, { params: values, files, signal });
      if (signal.aborted) return;
      this.#handlers.onpreview(preview, source);
    } catch (error) {
      if (!signal.aborted) this.#handlers.onerror(error);
    } finally {
      if (this.#running === running) this.#running = null;
    }
  }
}
