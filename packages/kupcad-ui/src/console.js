// The console's lines, as OpenSCAD's console keeps them: each run of the script shown (a line
// saying it ran and how it went, then what it printed, its warnings and its error, a line of
// the script beside each that names one) and the host's own log, in the order they came, the
// oldest dropped past MAX_LINES.

import { describeRun, runStatusOf } from './run-status.js';

/** @import { FrameHeader } from '@kupcad/protocol/types' */

/** The most lines kept: past them the oldest go. */
export const MAX_LINES = 2000;

/**
 * A line of the console: of a run (`run`, what it printed, a warning, its error) or of the
 * host's log; with the script's line and column it names (1-based, the column in UTF-8 bytes),
 * null for none.
 * @typedef {object} ConsoleLine
 * @property {'run' | 'output' | 'warning' | 'error' | 'log'} kind
 * @property {string} text
 * @property {number | null} line
 * @property {number | null} column
 */

/**
 * @param {ConsoleLine['kind']} kind
 * @param {string} text
 * @param {number | null} [line]
 * @param {number | null} [column]
 * @returns {ConsoleLine}
 */
const lineOf = (kind, text, line = null, column = null) => ({ kind, text, line, column });

/**
 * `text`'s lines, without the end its last one has.
 * @param {string} text
 */
const linesIn = (text) => text.replace(/\r?\n$/, '').split(/\r?\n/);

/**
 * The lines of the run whose frame is `header`, of the script called `name`.
 * @param {FrameHeader} header
 * @param {string} name
 * @returns {ConsoleLine[]}
 */
export function linesOfRun(header, name) {
  const lines = [lineOf('run', `${name}: ${describeRun(runStatusOf(header))}`)];
  if (header.output) lines.push(...linesIn(header.output).map((text) => lineOf('output', text)));
  if (header.outputCut) {
    lines.push(lineOf('log', 'It printed more than a run keeps: the rest is left out.'));
  }
  for (const { message, line, column } of header.warnings) {
    lines.push(lineOf('warning', `Warning: ${message}`, line, column));
  }
  const { error } = header;
  if (error) lines.push(lineOf('error', `Error: ${error.message}`, error.line, error.column));
  return lines;
}

/**
 * The lines of the host's log in `text`.
 * @param {string} text
 * @returns {ConsoleLine[]}
 */
export const linesOfLog = (text) =>
  linesIn(text)
    .filter((line) => line.trim() !== '')
    .map((line) => lineOf('log', line));

/**
 * `lines` with `added` after them, at most MAX_LINES: the oldest go.
 * @param {readonly ConsoleLine[]} lines
 * @param {readonly ConsoleLine[]} added
 * @returns {ConsoleLine[]}
 */
export function appendLines(lines, added) {
  const all = [...lines, ...added];
  return all.length > MAX_LINES ? all.slice(all.length - MAX_LINES) : all;
}
