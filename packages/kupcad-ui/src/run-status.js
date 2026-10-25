// How the run a viewer shows went, for its status line, and what it said went wrong: from the
// preview frame's header, the same for every host.

/** @import { FrameHeader } from '@kupcad/protocol/types' */

/**
 * The run of the script shown: running, done, or failed; how long it took (ms), and how many
 * warnings it gave.
 * @typedef {object} RunStatus
 * @property {'running' | 'ready' | 'failed'} state
 * @property {number} [runMs]
 * @property {number} [warnings]
 */

/**
 * Something the run said went wrong: why it failed, or a warning, and where in the script it
 * was (a 1-based line and column, in UTF-8 bytes), null where it wasn't running.
 * @typedef {object} Problem
 * @property {'error' | 'warning'} severity
 * @property {string} message
 * @property {number | null} line
 * @property {number | null} column
 */

/** @type {Record<RunStatus['state'], string>} */
const STATES = { running: 'Running…', ready: 'Ready', failed: 'Failed' };

/**
 * The run whose frame is `header`: running while none came (null).
 * @param {FrameHeader | null} header
 * @returns {RunStatus}
 */
export function runStatusOf(header) {
  if (!header) return { state: 'running' };
  return {
    state: header.error ? 'failed' : 'ready',
    runMs: header.timing.runMs,
    warnings: header.warnings.length,
  };
}

/**
 * What the status line says of `run`: its state, then its time and its warnings.
 * @param {RunStatus} run
 */
export function describeRun(run) {
  const said = [STATES[run.state]];
  if (run.runMs !== undefined) said.push(`${Math.round(run.runMs)} ms`);
  if (run.warnings) said.push(`${run.warnings} warning${run.warnings === 1 ? '' : 's'}`);
  return said.join(' · ');
}

/**
 * What the run whose frame is `header` said went wrong: why it failed first, then its warnings;
 * nothing while none came (null).
 * @param {FrameHeader | null} header
 * @returns {Problem[]}
 */
export function problemsOf(header) {
  if (!header) return [];
  /** @type {Problem[]} */
  const problems = header.warnings.map(({ message, line, column }) => ({
    severity: 'warning',
    message,
    line,
    column,
  }));
  const { error } = header;
  if (error) {
    problems.unshift({
      severity: 'error',
      message: error.message,
      line: error.line,
      column: error.column,
    });
  }
  return problems;
}
