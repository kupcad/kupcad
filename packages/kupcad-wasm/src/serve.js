// The worker's side: the core instantiated in the worker, answering the client's calls on
// `port` in the order they come. A result's buffer is transferred, not copied.

import { createKupcad } from './kupcad.js';
import { KupcadCrashError } from './errors.js';

/** @import { Preview } from '@kupcad/protocol/types' */
/** @import { CreateOptions, FromWorker, KupcadApi, Method, PortLike, SentError, ToWorker } from './types.js' */

/** @type {Record<Method, (kupcad: KupcadApi, args: any[]) => Promise<unknown>>} */
const CALLS = {
  preview: (kupcad, [source, options]) => kupcad.preview(source, options),
  build: (kupcad, [source, options]) => kupcad.build(source, options),
  check: (kupcad, [source]) => kupcad.check(source),
  format: (kupcad, [source]) => kupcad.format(source),
  params: (kupcad, [source]) => kupcad.params(source),
  version: (kupcad) => kupcad.version(),
  putFile: (kupcad, [path, data]) => kupcad.files.put(path, data),
  clearFiles: (kupcad) => kupcad.files.clear(),
};

/**
 * Serves the core on `port`: an `init` message makes it (`create`, the module given and the
 * files put), and each `call` is answered with a `reply`. The core's log goes as `log`
 * messages.
 * @param {PortLike} port
 * @param {(options: CreateOptions) => Promise<KupcadApi>} [create]
 */
export function serve(port, create = createKupcad) {
  /** @type {Promise<KupcadApi> | null} */
  let kupcad = null;
  /** @param {FromWorker} message @param {Transferable[]} [transfer] */
  const send = (message, transfer = []) => port.postMessage(message, transfer);

  /** @param {Extract<ToWorker, { type: 'init' }>} init */
  const start = async ({ wasm, files }) => {
    const made = await create({ wasm, log: (line) => send({ type: 'log', line }) });
    for (const [path, data] of files) await made.files.put(path, data);
    return made;
  };

  /** @param {Extract<ToWorker, { type: 'call' }>} call */
  const answer = async ({ id, method, args }) => {
    /** @type {KupcadApi} */
    let ready;
    try {
      if (!kupcad) throw new Error('the kupcad worker was called before it was given its module');
      ready = await kupcad;
    } catch (err) {
      send({ type: 'reply', id, ok: false, error: sent(err, true) });
      return;
    }
    try {
      const value = await CALLS[method](ready, args);
      send({ type: 'reply', id, ok: true, value }, transferOf(value));
    } catch (err) {
      send({ type: 'reply', id, ok: false, error: sent(err, err instanceof KupcadCrashError) });
    }
  };

  port.addEventListener('message', ({ data }) => {
    if (data.type === 'init') {
      kupcad = start(data);
      // A core that didn't start is told to each call, which awaits it
      kupcad.catch(() => {});
      return;
    }
    void answer(data);
  });
}

/**
 * @param {unknown} err
 * @param {boolean} fatal
 * @returns {SentError}
 */
function sent(err, fatal) {
  if (err instanceof Error) return { name: err.name, message: err.message, fatal };
  return { name: 'Error', message: String(err), fatal };
}

/**
 * The buffers a result holds, to transfer: a build's bytes, a preview's GLB.
 * @param {unknown} value
 * @returns {Transferable[]}
 */
function transferOf(value) {
  if (value instanceof Uint8Array) return [value.buffer];
  const model = /** @type {Partial<Preview> | null} */ (value)?.model;
  return model?.kind === '3d' ? [model.glb.buffer] : [];
}
