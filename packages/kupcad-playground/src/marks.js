// What the playground's editor marks: `check`'s findings, and the places the run named (why it
// failed, what it warned of). A script that doesn't parse or compile fails the run for what
// `check` says already, so its run's error isn't marked again where check found errors.

/** @import { Mark } from '@kupcad/editor' */
/** @import { Finding } from '@kupcad/protocol/types' */
/** @import { Problem } from '@kupcad/ui' */

/**
 * @param {readonly Finding[]} findings `check`'s
 * @param {readonly Problem[]} problems the run's (`problemsOf(header)`): those with a line
 * @returns {Mark[]}
 */
export function marksOf(findings, problems) {
  const checked = findings.some((finding) => finding.severity === 'error');
  /** @type {Mark[]} */
  const placed = [];
  for (const problem of problems) {
    if (problem.line === null || (checked && problem.severity === 'error')) continue;
    const { severity, message, line } = problem;
    placed.push({ severity, message, line, column: problem.column ?? 1 });
  }
  return [...findings, ...placed];
}
