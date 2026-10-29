// The core in a Web Worker, with createKupcad's API: a long build runs there and the page goes
// on. Calls run one at a time, the next waiting its turn. A call's AbortSignal drops it while
// it waits, and stops the worker while it runs: the worker is replaced on the next call, as
// one that crashed is. The worker is given its module, this package's unless the host's: the
// page's side alone names it (create.js), so a site's bundler copies it once.

import { ProtocolError } from '@kupcad/protocol';
import { DEFAULT_WASM } from './create.js';
import { KupcadCrashError, KupcadError } from './errors.js';

/** @import { Finding, Preview, UiSchema, VersionInfo } from '@kupcad/protocol/types' */
/** @import { BuildOptions, CallOptions, FromWorker, KupcadApi, Method, PreviewOptions, SentError, ToWorker, WorkerLike, WorkerOptions, WorkerWasmSource } from './types.js' */

/**
 * @typedef {object} Call
 * @property {number} id
 * @property {Method} method
 * @property {unknown[]} args
 * @property {(value: any) => void} resolve
 * @property {(reason: unknown) => void} reject
 * @property {AbortSignal | undefined} signal
 * @property {() => void} onAbort
 */

/** @type {() => WorkerLike} */
const moduleWorker = () => new Worker(new URL('./worker.js', import.meta.url), { type: 'module' });
/** Why a worker failed when its error says nothing: its script didn't load, most often. */
const SILENT_FAILURE = 'it failed without a message (its script may not have loaded)';

/**
 * The core in a Web Worker.
 * @param {WorkerOptions} [options]
 * @returns {KupcadWorker}
 */
export function createKupcadWorker(options = {}) {
  return new KupcadWorker(options);
}

/** @implements {KupcadApi} */
export class KupcadWorker {
  /** @type {() => WorkerLike} */
  #spawn;
  /** The module, as it can be posted (a URL as its href). */
  #wasm;
  /** @type {(line: string) => void} */
  #log;
  /** @type {WorkerLike | null} */
  #worker = null;
  /** @type {Call[]} */
  #queue = [];
  /** @type {Call | null} */
  #running = null;
  #nextId = 1;
  /** @type {Error | null} */
  #terminated = null;

  /** @param {WorkerOptions} options */
  constructor(options) {
    this.#spawn = options.worker ?? moduleWorker;
    this.#wasm = postable(options.wasm ?? DEFAULT_WASM);
    this.#log = options.log ?? ((line) => console.debug(line));
  }

  /**
   * @param {string} source
   * @param {PreviewOptions} [options]
   * @returns {Promise<Preview>}
   */
  preview(source, { signal, ...options } = {}) {
    return this.#call('preview', [source, options], signal);
  }

  /**
   * @param {string} source
   * @param {BuildOptions} [options]
   * @returns {Promise<Uint8Array>}
   */
  build(source, { signal, ...options } = {}) {
    return this.#call('build', [source, options], signal);
  }

  /**
   * @param {string} source
   * @param {CallOptions} [options]
   * @returns {Promise<Finding[]>}
   */
  check(source, { signal } = {}) {
    return this.#call('check', [source], signal);
  }

  /**
   * @param {string} source
   * @param {CallOptions} [options]
   * @returns {Promise<string>}
   */
  format(source, { signal } = {}) {
    return this.#call('format', [source], signal);
  }

  /**
   * @param {string} source
   * @param {CallOptions} [options]
   * @returns {Promise<UiSchema>}
   */
  params(source, { signal } = {}) {
    return this.#call('params', [source], signal);
  }

  /** @returns {Promise<VersionInfo>} */
  version() {
    return this.#call('version', []);
  }

  /** Stops the worker for good: the calls waiting, and any made after, are refused. */
  terminate() {
    this.#terminated = new Error('the kupcad worker was terminated');
    this.#stopWorker();
    for (const call of [...(this.#running ? [this.#running] : []), ...this.#queue]) {
      this.#settle(call, () => call.reject(this.#terminated));
    }
    this.#running = null;
    this.#queue = [];
  }

  /**
   * @param {Method} method
   * @param {unknown[]} args
   * @param {AbortSignal} [signal]
   * @returns {Promise<any>}
   */
  #call(method, args, signal) {
    if (this.#terminated) return Promise.reject(this.#terminated);
    if (signal?.aborted) return Promise.reject(signal.reason);
    return new Promise((resolve, reject) => {
      /** @type {Call} */
      const call = {
        id: this.#nextId++,
        method,
        args,
        resolve,
        reject,
        signal,
        onAbort: () => this.#abort(call),
      };
      signal?.addEventListener('abort', call.onAbort, { once: true });
      this.#queue.push(call);
      this.#pump();
    });
  }

  /**
   * Sends the next call when none runs, starting a worker if none does. One that can't be
   * sent (no worker starts, or its arguments can't be posted) is refused, and the next goes:
   * it was taken for running, and every call after waited for good.
   */
  #pump() {
    while (!this.#running) {
      const next = this.#queue.shift();
      if (!next) return;
      try {
        this.#ensureWorker().postMessage({
          type: 'call',
          id: next.id,
          method: next.method,
          args: next.args,
        });
        this.#running = next;
      } catch (error) {
        this.#settle(next, () => next.reject(error));
      }
    }
  }

  /** @returns {WorkerLike} */
  #ensureWorker() {
    if (this.#worker) return this.#worker;
    const worker = this.#spawn();
    // A worker stopped may still have sent: only the running one's messages count
    worker.addEventListener('message', ({ data }) => {
      if (worker === this.#worker) this.#receive(data);
    });
    worker.addEventListener('error', (event) => {
      event.preventDefault();
      if (worker === this.#worker) {
        this.#fail(
          new KupcadCrashError(`the kupcad worker failed: ${event.message || SILENT_FAILURE}`),
        );
      }
    });
    // A reply that couldn't be read would leave its call waiting for good
    worker.addEventListener('messageerror', () => {
      if (worker === this.#worker) {
        this.#fail(new KupcadCrashError("the kupcad worker sent a message that couldn't be read"));
      }
    });
    try {
      worker.postMessage({ type: 'init', wasm: this.#wasm });
    } catch (error) {
      worker.terminate();
      throw error;
    }
    this.#worker = worker;
    return worker;
  }

  /** @param {FromWorker} message */
  #receive(message) {
    if (message.type === 'log') {
      this.#log(message.line);
      return;
    }
    const call = this.#running;
    if (!call || call.id !== message.id) return;
    this.#running = null;
    if (message.ok) {
      this.#settle(call, () => call.resolve(message.value));
    } else {
      // A core that can't go on is replaced on the next call
      if (message.error.fatal) this.#stopWorker();
      this.#settle(call, () => call.reject(revive(message.error)));
    }
    this.#pump();
  }

  /**
   * Refuses the running call with `error`, the worker gone with it.
   * @param {Error} error
   */
  #fail(error) {
    this.#stopWorker();
    const call = this.#running;
    this.#running = null;
    if (call) this.#settle(call, () => call.reject(error));
    this.#pump();
  }

  /** @param {Call} call */
  #abort(call) {
    const reason = call.signal?.reason;
    if (call === this.#running) {
      // A call can't be stopped inside the module: the worker running it is
      this.#stopWorker();
      this.#running = null;
      this.#settle(call, () => call.reject(reason));
      this.#pump();
      return;
    }
    this.#queue = this.#queue.filter((queued) => queued !== call);
    this.#settle(call, () => call.reject(reason));
  }

  /**
   * @param {Call} call
   * @param {() => void} done
   */
  #settle(call, done) {
    call.signal?.removeEventListener('abort', call.onAbort);
    done();
  }

  #stopWorker() {
    const worker = this.#worker;
    if (!worker) return;
    this.#worker = null;
    worker.terminate();
  }
}

/**
 * The module as the worker is given it: a URL as its href, a relative one resolved against the
 * page (the worker would resolve it against its own script's).
 * @param {WorkerWasmSource} wasm
 * @returns {Extract<ToWorker, { type: 'init' }>['wasm']}
 */
function postable(wasm) {
  if (wasm instanceof URL) return wasm.href;
  if (typeof wasm === 'string' && globalThis.location) return new URL(wasm, location.href).href;
  return wasm;
}

/**
 * A failure from the worker, as the error class it was there.
 * @param {SentError} error
 * @returns {Error}
 */
function revive({ name, message }) {
  if (name === 'KupcadError') return new KupcadError(message);
  if (name === 'KupcadCrashError') return new KupcadCrashError(message);
  if (name === 'ProtocolError') return new ProtocolError(message);
  const error = new Error(message);
  error.name = name;
  return error;
}
