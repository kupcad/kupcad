import { afterEach, describe, expect, it, vi } from 'vitest';
import { ProtocolError } from '@kupcad/protocol';
import { createKupcad, createKupcadWorker, KupcadCrashError, KupcadError } from './index.js';
import { serve } from './serve.js';

/** @import { CreateOptions, KupcadApi, PortLike, WorkerLike } from './types.js' */

/**
 * Stand-ins for Web Workers running src/worker.js: the core served by `create` on one end of a
 * MessageChannel in this thread. Each one started is kept in `started`.
 * @param {(options: CreateOptions) => Promise<KupcadApi>} create
 */
function inProcess(create) {
  /** @type {{ terminated: boolean }[]} */
  const started = [];
  /** @returns {WorkerLike} */
  const spawn = () => {
    const { port1, port2 } = new MessageChannel();
    serve(/** @type {PortLike} */ (/** @type {unknown} */ (port2)), create);
    port1.start();
    port2.start();
    const state = { terminated: false };
    started.push(state);
    return {
      postMessage: (message) => port1.postMessage(message),
      addEventListener: (/** @type {string} */ type, /** @type {any} */ listener) => {
        if (type === 'message') port1.addEventListener('message', listener);
      },
      terminate: () => {
        state.terminated = true;
        port1.close();
        port2.close();
      },
    };
  };
  return { spawn, started };
}

/**
 * The real core, its calls counted by method.
 * @param {Record<string, number>} counts
 * @returns {(options: CreateOptions) => Promise<KupcadApi>}
 */
const counted = (counts) => async (options) => {
  const kupcad = await createKupcad(options);
  return new Proxy(kupcad, {
    get(target, name, receiver) {
      const member = Reflect.get(target, name, receiver);
      if (typeof member !== 'function') return member;
      return (/** @type {unknown[]} */ ...args) => {
        counts[String(name)] = (counts[String(name)] ?? 0) + 1;
        return member.apply(target, args);
      };
    },
  });
};

const silent = () => {};

/**
 * A stand-in for a worker that never answers: what the client posts it, and its listeners, to
 * fire as a Web Worker would.
 */
function silentWorker() {
  /** @type {unknown[]} */
  const posted = [];
  /** @type {Record<string, (event: any) => void>} */
  const listeners = {};
  /** @type {WorkerLike} */
  const worker = {
    postMessage: (message) => posted.push(message),
    addEventListener: (/** @type {string} */ type, /** @type {any} */ listener) => {
      listeners[type] = listener;
    },
    terminate: () => {},
  };
  return { worker, posted, listeners };
}

afterEach(() => vi.unstubAllGlobals());

describe('createKupcadWorker', () => {
  it("gives the core's results from the worker, its refusals as KupcadErrors", async () => {
    const { spawn } = inProcess(createKupcad);
    const kupcad = createKupcadWorker({ worker: spawn, log: silent });
    const { header, model } = await kupcad.preview('w = param(:w, default: 2)\ncube(w)', {
      params: { w: 3 },
    });
    expect(header.params.values).toEqual({ w: 3 });
    if (model.kind !== '3d') throw new Error(`a ${model.kind} model`);
    expect(new TextDecoder().decode(model.glb.subarray(0, 4))).toBe('glTF');
    expect((await kupcad.build('cube(2)', { format: 'stl' })).byteLength).toBeGreaterThan(84);
    expect(await kupcad.format('x=1')).toBe('x = 1\n');
    expect((await kupcad.check('x = 1\ncube('))[0].line).toBe(2);
    expect((await kupcad.params('w = param(:w, default: 2)')).parameters[0].name).toBe('w');
    expect((await kupcad.version()).arch).toBe('wasm32');
    await expect(kupcad.build('raise "boom"')).rejects.toThrow(
      new KupcadError('RuntimeError: boom'),
    );
    kupcad.terminate();
  });

  it("passes the core's log on", async () => {
    const { spawn } = inProcess(createKupcad);
    /** @type {string[]} */
    const logged = [];
    const kupcad = createKupcadWorker({ worker: spawn, log: (line) => logged.push(line) });
    await kupcad.build('raise "boom"').catch(() => {});
    expect(logged).toContain('error(vm): RuntimeError: boom');
    kupcad.terminate();
  });

  it('runs one call at a time: one aborted while it waits never reaches the worker', async () => {
    /** @type {Record<string, number>} */
    const counts = {};
    const { spawn, started } = inProcess(counted(counts));
    const kupcad = createKupcadWorker({ worker: spawn, log: silent });
    const controller = new AbortController();
    const running = kupcad.check('x = 1');
    const waiting = kupcad.format('x=1', { signal: controller.signal });
    controller.abort();
    await expect(waiting).rejects.toThrow(/abort/i);
    expect(await running).toEqual([]);
    expect(await kupcad.format('y=2')).toBe('y = 2\n');
    expect(counts.format).toBe(1);
    expect(started).toHaveLength(1);
    kupcad.terminate();
  });

  it('stops the worker of a call aborted while it runs; the next call starts one given the files put', async () => {
    const { spawn, started } = inProcess(createKupcad);
    const kupcad = createKupcadWorker({ worker: spawn, log: silent });
    await kupcad.files.put('size.json', '{"side": 3}');
    const controller = new AbortController();
    const running = kupcad.check('x = 1', { signal: controller.signal });
    controller.abort();
    await expect(running).rejects.toThrow(/abort/i);
    expect(started[0].terminated).toBe(true);
    const stl = await kupcad.build('cube(import_json("size.json")[:side])', { format: 'stl' });
    expect(stl.byteLength).toBeGreaterThan(84);
    expect(started).toHaveLength(2);
    kupcad.terminate();
  });

  it('clears the files put, and gives a new worker none of them', async () => {
    const { spawn, started } = inProcess(createKupcad);
    const kupcad = createKupcadWorker({ worker: spawn, log: silent });
    const reads = 'cube(import_json("size.json")[:side])';
    await kupcad.files.put('size.json', '{"side": 3}');
    await kupcad.files.clear();
    await expect(kupcad.build(reads)).rejects.toBeInstanceOf(KupcadError);
    const controller = new AbortController();
    const running = kupcad.check('x = 1', { signal: controller.signal });
    controller.abort();
    await expect(running).rejects.toThrow(/abort/i);
    await expect(kupcad.build(reads)).rejects.toBeInstanceOf(KupcadError);
    expect(started).toHaveLength(2);
    kupcad.terminate();
  });

  it("gives an error of the worker's that isn't the core's as the Error it was, by name", async () => {
    /** A core whose calls fail as no core would: a TypeError, and a thrown string. */
    const odd = /** @type {KupcadApi} */ (
      /** @type {unknown} */ ({
        check: async () => {
          throw new TypeError('not a function');
        },
        format: async () => {
          throw 'a string';
        },
      })
    );
    const { spawn } = inProcess(async () => odd);
    const kupcad = createKupcadWorker({ worker: spawn, log: silent });
    await expect(kupcad.check('x')).rejects.toMatchObject({
      name: 'TypeError',
      message: 'not a function',
    });
    await expect(kupcad.format('x')).rejects.toThrow('a string');
    kupcad.terminate();
  });

  it('replaces a worker whose core stopped, and one whose core could not start', async () => {
    /** A core whose builds trap: the only call made of it. */
    const stopped = /** @type {KupcadApi} */ (
      /** @type {unknown} */ ({
        build: async () => {
          throw new KupcadCrashError('kupcad.wasm stopped: unreachable');
        },
      })
    );
    let calls = 0;
    /** @type {(options: CreateOptions) => Promise<KupcadApi>} */
    const flaky = async (options) => {
      calls += 1;
      if (calls === 1) throw new ProtocolError('kupcad.wasm 9.0.0 speaks protocol version 2');
      if (calls === 2) return stopped;
      return createKupcad(options);
    };
    const { spawn, started } = inProcess(flaky);
    const kupcad = createKupcadWorker({ worker: spawn, log: silent });
    await expect(kupcad.version()).rejects.toBeInstanceOf(ProtocolError);
    await expect(kupcad.build('cube(1)')).rejects.toBeInstanceOf(KupcadCrashError);
    expect((await kupcad.version()).arch).toBe('wasm32');
    expect(started.map((worker) => worker.terminated)).toEqual([true, true, false]);
    kupcad.terminate();
  });

  it("refuses the running call as a crash when the worker fails, or sends what can't be read", async () => {
    const failing = silentWorker();
    const kupcad = createKupcadWorker({ worker: () => failing.worker, log: silent });
    const failed = kupcad.version();
    failing.listeners.error({ message: '', preventDefault() {} });
    await expect(failed).rejects.toThrow(
      new KupcadCrashError(
        'the kupcad worker failed: it failed without a message (its script may not have loaded)',
      ),
    );

    const garbled = silentWorker();
    const other = createKupcadWorker({ worker: () => garbled.worker, log: silent });
    const unread = other.version();
    garbled.listeners.messageerror({});
    await expect(unread).rejects.toBeInstanceOf(KupcadCrashError);
  });

  it("gives the worker a relative module URL as the page's, not its own script's", () => {
    vi.stubGlobal('location', new URL('https://example.com/app/index.html'));
    const { worker, posted } = silentWorker();
    const kupcad = createKupcadWorker({ wasm: './kupcad.wasm', worker: () => worker, log: silent });
    void kupcad.version().catch(() => {});
    expect(posted[0]).toMatchObject({ type: 'init', wasm: 'https://example.com/app/kupcad.wasm' });
    kupcad.terminate();
  });

  it('refuses the calls waiting once terminated, and any made after', async () => {
    const { spawn } = inProcess(createKupcad);
    const kupcad = createKupcadWorker({ worker: spawn, log: silent });
    const running = kupcad.check('x = 1');
    const waiting = kupcad.format('x=1');
    kupcad.terminate();
    await expect(running).rejects.toThrow('the kupcad worker was terminated');
    await expect(waiting).rejects.toThrow('the kupcad worker was terminated');
    await expect(kupcad.version()).rejects.toThrow('the kupcad worker was terminated');
  });
});
