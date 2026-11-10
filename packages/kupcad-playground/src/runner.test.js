import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { BUSY_MS, DELAY_MS, Runner } from './runner.js';

/** @import { Finding, ParamValues, Preview } from '@kupcad/protocol/types' */
/** @import { PreviewOptions } from '@kupcad/wasm/types' */

/**
 * A stand-in for the core: each call waits until the test settles it, and says it was stopped
 * when its signal is.
 */
function standIn() {
  /** @type {{ method: string, source: string, values?: ParamValues, files?: PreviewOptions['files'], signal: AbortSignal, settle: (value: unknown) => void, fail: (error: unknown) => void }[]} */
  const calls = [];
  /**
   * @param {string} method
   * @returns {(source: string, options: { signal: AbortSignal, params?: ParamValues, files?: PreviewOptions['files'] }) => Promise<any>}
   */
  const call =
    (method) =>
    (source, { signal, params, files }) =>
      new Promise((settle, fail) => {
        calls.push({ method, source, values: params, files, signal, settle, fail });
        signal.addEventListener('abort', () => fail(signal.reason));
      });
  return { calls, kupcad: { check: call('check'), preview: call('preview') } };
}

/** A preview frame, as far as the runner passes it on. @param {string} source */
const previewOf = (source) => /** @type {Preview} */ (/** @type {unknown} */ ({ source }));

/** The runner's handlers, recording what they were given. */
function handlersOf() {
  /** @type {unknown[][]} */
  const got = [];
  return {
    got,
    handlers: {
      onfindings: (/** @type {Finding[]} */ findings, /** @type {string} */ source) =>
        got.push(['findings', source, findings.length]),
      onpreview: (/** @type {Preview} */ preview, /** @type {string} */ source) =>
        got.push(['preview', source]),
      onerror: (/** @type {unknown} */ error) => got.push(['error', String(error)]),
      onbusy: (/** @type {boolean} */ busy) => got.push(['busy', busy]),
    },
  };
}

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

describe('Runner', () => {
  it('runs the script once it stays as it is for a moment: its findings, then its preview', async () => {
    const { calls, kupcad } = standIn();
    const { got, handlers } = handlersOf();
    const runner = new Runner(kupcad, handlers);
    runner.run('cube(1)', {});
    vi.advanceTimersByTime(DELAY_MS - 1);
    runner.run('cube(2)', { w: 3 });
    vi.advanceTimersByTime(DELAY_MS - 1);
    expect(calls).toHaveLength(0);
    vi.advanceTimersByTime(1);
    expect(calls.map((c) => [c.method, c.source])).toEqual([['check', 'cube(2)']]);
    calls[0].settle([{}]);
    await vi.waitFor(() => expect(calls).toHaveLength(2));
    expect(calls[1]).toMatchObject({ method: 'preview', source: 'cube(2)', values: { w: 3 } });
    calls[1].settle(previewOf('cube(2)'));
    await vi.waitFor(() => expect(got).toHaveLength(2));
    expect(got).toEqual([
      ['findings', 'cube(2)', 1],
      ['preview', 'cube(2)'],
    ]);
  });

  it('runs at once when asked, and stops the run under way: what comes is the last script', async () => {
    const { calls, kupcad } = standIn();
    const { got, handlers } = handlersOf();
    const runner = new Runner(kupcad, handlers);
    runner.run('cube(1)', {}, { now: true });
    expect(calls).toHaveLength(1);
    runner.run('cube(2)', {}, { now: true });
    expect(calls[0].signal.aborted).toBe(true);
    calls[1].settle([]);
    await vi.waitFor(() => expect(calls).toHaveLength(3));
    calls[2].settle(previewOf('cube(2)'));
    await vi.waitFor(() => expect(got).toHaveLength(2));
    // The stopped run said nothing, not even that it failed
    expect(got).toEqual([
      ['findings', 'cube(2)', 0],
      ['preview', 'cube(2)'],
    ]);
  });

  it("gives the preview the files the script's imports read", async () => {
    const { calls, kupcad } = standIn();
    const runner = new Runner(kupcad, handlersOf().handlers);
    const files = { 'lib.kup': 'export size = 2\n' };
    runner.run('import { size } from "./lib.kup"\ncube(size)', {}, { files });
    vi.advanceTimersByTime(DELAY_MS);
    calls[0].settle([]);
    await vi.waitFor(() => expect(calls).toHaveLength(2));
    expect([calls[0].files, calls[1].files]).toEqual([undefined, files]);
  });

  it('stops the run waiting and the run under way, and runs the next', async () => {
    const { calls, kupcad } = standIn();
    const { got, handlers } = handlersOf();
    const runner = new Runner(kupcad, handlers);
    runner.run('cube(1)', {}, { now: true });
    runner.run('cube(2)', {});
    runner.stop();
    vi.advanceTimersByTime(DELAY_MS);
    expect(calls).toHaveLength(1);
    expect(calls[0].signal.aborted).toBe(true);
    runner.run('cube(3)', {}, { now: true });
    expect(calls.map(({ source }) => source)).toEqual(['cube(1)', 'cube(3)']);
    expect(got).toEqual([]);
  });

  it('says why a call failed', async () => {
    const { calls, kupcad } = standIn();
    const { got, handlers } = handlersOf();
    const runner = new Runner(kupcad, handlers);
    runner.run('cube(1)', {}, { now: true });
    calls[0].fail(new Error('the worker stopped'));
    await vi.waitFor(() => expect(got).toEqual([['error', 'Error: the worker stopped']]));
  });

  it('says nothing of a run that ends before BUSY_MS', async () => {
    const { calls, kupcad } = standIn();
    const { got, handlers } = handlersOf();
    const runner = new Runner(kupcad, handlers);
    runner.run('cube(1)', {}, { now: true });
    vi.advanceTimersByTime(BUSY_MS - 1);
    // Settled with no time passing (vi.waitFor would pass it)
    calls[0].settle([]);
    await vi.advanceTimersByTimeAsync(0);
    calls[1].settle(previewOf('cube(1)'));
    await vi.advanceTimersByTimeAsync(0);
    vi.advanceTimersByTime(BUSY_MS);
    expect(got).toEqual([
      ['findings', 'cube(1)', 0],
      ['preview', 'cube(1)'],
    ]);
  });

  it('says a run is under way once it goes on for BUSY_MS, and that it is over after what it gave', async () => {
    const { calls, kupcad } = standIn();
    const { got, handlers } = handlersOf();
    const runner = new Runner(kupcad, handlers, { busyMs: 50 });
    runner.run('cube(1)', {}, { now: true });
    vi.advanceTimersByTime(49);
    expect(got).toEqual([]);
    vi.advanceTimersByTime(1);
    expect(got).toEqual([['busy', true]]);
    calls[0].settle([]);
    await vi.waitFor(() => expect(calls).toHaveLength(2));
    calls[1].settle(previewOf('cube(1)'));
    await vi.waitFor(() => expect(got).toHaveLength(4));
    expect(got.slice(1)).toEqual([
      ['findings', 'cube(1)', 0],
      ['preview', 'cube(1)'],
      ['busy', false],
    ]);
  });

  it('counts a run stopped for the next as one under way with it', async () => {
    const { calls, kupcad } = standIn();
    const { got, handlers } = handlersOf();
    const runner = new Runner(kupcad, handlers);
    runner.run('cube(1)', {}, { now: true });
    vi.advanceTimersByTime(BUSY_MS - 1);
    runner.run('cube(2)', {}, { now: true });
    vi.advanceTimersByTime(1);
    expect(got).toEqual([['busy', true]]);
    // The stopped run's end isn't the runs'
    await vi.waitFor(() => expect(calls[0].signal.aborted).toBe(true));
    await Promise.resolve();
    expect(got).toEqual([['busy', true]]);
    calls[1].settle([]);
    await vi.waitFor(() => expect(calls).toHaveLength(3));
    calls[2].settle(previewOf('cube(2)'));
    await vi.waitFor(() => expect(got.at(-1)).toEqual(['busy', false]));
    expect(got.filter(([what]) => what === 'busy')).toHaveLength(2);
  });

  it('says the runs are over when a call fails, or they are stopped', async () => {
    const { calls, kupcad } = standIn();
    const { got, handlers } = handlersOf();
    const runner = new Runner(kupcad, handlers);
    runner.run('cube(1)', {}, { now: true });
    vi.advanceTimersByTime(BUSY_MS);
    calls[0].fail(new Error('the worker stopped'));
    await vi.waitFor(() => expect(got).toHaveLength(3));
    expect(got).toEqual([
      ['busy', true],
      ['error', 'Error: the worker stopped'],
      ['busy', false],
    ]);
    runner.run('cube(2)', {}, { now: true });
    vi.advanceTimersByTime(BUSY_MS);
    runner.stop();
    expect(got.slice(3)).toEqual([
      ['busy', true],
      ['busy', false],
    ]);
  });
});
