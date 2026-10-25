import { describe, expect, it } from 'vitest';
import { describeRun, problemsOf, runStatusOf } from './run-status.js';

/** @import { FrameHeader } from '@kupcad/protocol/types' */

/**
 * A frame's header, as far as a run's status reads it.
 * @param {Partial<FrameHeader>} header
 */
const headerOf = (header) =>
  /** @type {FrameHeader} */ ({
    warnings: [],
    error: null,
    timing: { runMs: 42, renderMs: 3 },
    ...header,
  });

describe('a run status', () => {
  it('is running while no frame came, then ready or failed with its time and warnings', () => {
    expect(runStatusOf(null)).toEqual({ state: 'running' });
    expect(runStatusOf(headerOf({}))).toEqual({ state: 'ready', runMs: 42, warnings: 0 });
    const failed = headerOf({
      error: { message: 'boom', line: 2, column: 1, param: null },
      warnings: [{ message: 'mended', line: 1, column: 1 }],
    });
    expect(runStatusOf(failed)).toEqual({ state: 'failed', runMs: 42, warnings: 1 });
  });

  it('is said as its state, its time rounded, and its warnings counted', () => {
    expect(describeRun({ state: 'running' })).toBe('Running…');
    expect(describeRun({ state: 'ready', runMs: 41.6, warnings: 0 })).toBe('Ready · 42 ms');
    expect(describeRun({ state: 'failed', runMs: 3, warnings: 2 })).toBe(
      'Failed · 3 ms · 2 warnings',
    );
  });
});

describe("a run's problems", () => {
  it('are why it failed, then its warnings, each where it was', () => {
    expect(problemsOf(null)).toEqual([]);
    expect(problemsOf(headerOf({}))).toEqual([]);
    const failed = headerOf({
      error: { message: 'boom', line: 2, column: 5, param: 'width' },
      warnings: [
        { message: 'mended', line: 1, column: 1 },
        { message: 'meshed coarse', line: null, column: null },
      ],
    });
    expect(problemsOf(failed)).toEqual([
      { severity: 'error', message: 'boom', line: 2, column: 5 },
      { severity: 'warning', message: 'mended', line: 1, column: 1 },
      { severity: 'warning', message: 'meshed coarse', line: null, column: null },
    ]);
  });
});
