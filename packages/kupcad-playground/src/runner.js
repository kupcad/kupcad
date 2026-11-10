// When the playground runs the script: once it stays as it is for a moment (DELAY_MS) after an
// edit, and at once when a parameter's value changes or the playground starts. A run under way
// when the next starts is stopped (the core's worker drops or ends its call), so what comes is
// the last script's. A run is the script's findings (`check`, quick: the editor marks them
// first), then its preview (the model, its parameters, why it failed), the files its imports
// read given with it. One that is still under way after a moment (BUSY_MS) is said to be, so a
// status line shows it running, and a quicker one shows nothing in between (no flicker).

/** @import { Finding, ParamValues, Preview } from '@kupcad/protocol/types' */
/** @import { KupcadApi, PreviewOptions } from '@kupcad/wasm/types' */

/** How long the script stays as it is after an edit before it runs. */
export const DELAY_MS = 300;
/** How long the runs go on, one after another, before they are said to be under way. */
export const BUSY_MS = 300;

/**
 * What a run gives, each with the script it is of.
 * @typedef {object} RunHandlers
 * @property {(findings: Finding[], source: string) => void} onfindings
 * @property {(preview: Preview, source: string) => void} onpreview
 * @property {(error: unknown) => void} onerror a call failed (one stopped for the next didn't)
 * @property {(busy: boolean) => void} [onbusy] a run has been under way for BUSY_MS (true; a
 *   run stopped for the next goes on as that one), or the runs are over once that was said
 *   (false, after what the last gave)
 */

export class Runner {
  /** @type {Pick<KupcadApi, 'check' | 'preview'>} */
  #kupcad;
  /** @type {RunHandlers} */
  #handlers;
  #delayMs;
  #busyMs;
  /** @type {ReturnType<typeof setTimeout> | undefined} */
  #waiting;
  /** Until the runs under way are said to be. @type {ReturnType<typeof setTimeout> | undefined} */
  #busyTimer;
  /** Whether `onbusy` was told they are. */
  #busy = false;
  /** The run under way, which the next stops. @type {AbortController | null} */
  #running = null;

  /**
   * @param {Pick<KupcadApi, 'check' | 'preview'>} kupcad
   * @param {RunHandlers} handlers
   * @param {{ delayMs?: number, busyMs?: number }} [options]
   */
  constructor(kupcad, handlers, { delayMs = DELAY_MS, busyMs = BUSY_MS } = {}) {
    this.#kupcad = kupcad;
    this.#handlers = handlers;
    this.#delayMs = delayMs;
    this.#busyMs = busyMs;
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

  /**
   * Stops the run waiting for the delay and the run under way: nothing comes of either. The
   * next `run` runs again; a host done with the runner stops it and lets it go.
   */
  stop() {
    clearTimeout(this.#waiting);
    this.#running?.abort();
    this.#running = null;
    this.#idle();
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
    if (!this.#busy && this.#busyTimer === undefined) {
      this.#busyTimer = setTimeout(() => {
        this.#busyTimer = undefined;
        this.#busy = true;
        this.#handlers.onbusy?.(true);
      }, this.#busyMs);
    }
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
      if (this.#running === running) {
        this.#running = null;
        this.#idle();
      }
    }
  }

  /** No run is under way: one said to be is over, one not yet said to be never is. */
  #idle() {
    clearTimeout(this.#busyTimer);
    this.#busyTimer = undefined;
    if (this.#busy) {
      this.#busy = false;
      this.#handlers.onbusy?.(false);
    }
  }
}
