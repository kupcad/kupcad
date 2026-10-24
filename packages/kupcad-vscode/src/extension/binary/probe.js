// What a kupcad executable says of itself (`kupcad version --json`): its version and the protocol
// its language server speaks.

import { execFile } from 'node:child_process';

/** @import { VersionInfo } from '@kupcad/protocol/types' */

/** A binary that hasn't answered in this long isn't one to run. */
const PROBE_TIMEOUT_MS = 10_000;

/**
 * @param {string} path
 * @returns {Promise<VersionInfo | null>} null for one that isn't kupcad, or couldn't answer
 */
export function probe(path) {
  return new Promise((resolve) => {
    execFile(path, ['version', '--json'], { timeout: PROBE_TIMEOUT_MS }, (error, stdout) => {
      if (error) return resolve(null);
      try {
        const info = JSON.parse(stdout);
        const valid = typeof info?.version === 'string' && typeof info.protocolVersion === 'number';
        resolve(valid ? info : null);
      } catch {
        resolve(null);
      }
    });
  });
}
