import { testCore } from '@kupcad/wasm/testing';
import { describe, expect, it } from 'vitest';
import { appendLines, linesOfLog, linesOfRun, MAX_LINES } from './console.js';

/** @import { ConsoleLine } from './console.js' */

/**
 * The header of the frame the core gives `source`.
 * @param {string} source
 */
const headerOf = async (source) => (await (await testCore()).preview(source)).header;

/** @param {ConsoleLine[]} lines */
const shown = (lines) =>
  lines.map(({ kind, text, line }) => `${kind}${line ? `@${line}` : ''} ${text}`);

describe('a run in the console', () => {
  it('is a line saying how it went, then what it printed, its warnings and its error', async () => {
    const header = await headerOf('puts "width", 20\ncube(1)\nwarn("thin wall")\nraise "boom"\n');
    const lines = shown(linesOfRun(header, 'part.kup'));
    expect(lines[0]).toMatch(/^run part\.kup: Failed · \d+ ms · 1 warning$/);
    // warn prints its line as puts does, and keeps it as the run's warning
    expect(lines.slice(1, 4)).toEqual(['output width', 'output 20', 'output [Warning] thin wall']);
    expect(lines[4]).toBe('warning@3 Warning: thin wall');
    expect(lines[5]).toBe('error@4 Error: RuntimeError: boom');
  });

  it('says when it printed more than a run keeps, and has no lines of output when it printed none', async () => {
    const quiet = await headerOf('cube(1)\n');
    expect(shown(linesOfRun(quiet, 'part.kup'))).toEqual([
      expect.stringMatching(/^run part\.kup: Ready · \d+ ms$/),
    ]);
    const loud = await headerOf('20000.times { print "abcd" }\ncube(1)\n');
    expect(loud.outputCut).toBe(true);
    expect(shown(linesOfRun(loud, 'part.kup')).at(-1)).toBe(
      'log It printed more than a run keeps: the rest is left out.',
    );
  });
});

it("has the host's log a line each, blank ones left out", () => {
  expect(shown(linesOfLog('info(lsp): ready\n\nwarning(lsp): slow\n'))).toEqual([
    'log info(lsp): ready',
    'log warning(lsp): slow',
  ]);
});

it(`keeps the newest ${MAX_LINES} lines: the oldest go`, () => {
  const many = linesOfLog(Array.from({ length: MAX_LINES }, (_, i) => `line ${i}`).join('\n'));
  const kept = appendLines(many, linesOfLog('newest'));
  expect(kept).toHaveLength(MAX_LINES);
  expect(kept[0].text).toBe('line 1');
  expect(kept.at(-1)?.text).toBe('newest');
});
