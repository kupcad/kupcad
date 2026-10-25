// How the run a viewer shows went, for its status line: from the preview frame's header, the same
// for every host.

/** @import { FrameHeader } from '@kupcad/protocol/types' */

/**
 * The run of the script shown: running, done, or failed; how long it took (ms), and how many
 * warnings it gave.
 * @typedef {object} RunStatus
 * @property {'running' | 'ready' | 'failed'} state
 * @property {number} [runMs]
 * @property {number} [warnings]
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
