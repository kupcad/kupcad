import { expect, it } from 'vitest';
import { marksOf } from './marks.js';

/** @import { Finding } from '@kupcad/protocol/types' */
/** @import { Problem } from '@kupcad/ui' */

/** @param {Partial<Finding>} finding */
const findingOf = (finding) =>
  /** @type {Finding} */ ({
    severity: 'warning',
    message: 'unused',
    line: 1,
    column: 1,
    endLine: 1,
    endColumn: 2,
    ...finding,
  });

it("marks check's findings and the places the run named, the run's error unless check found errors", () => {
  /** @type {Problem[]} */
  const problems = [
    { severity: 'error', message: 'RuntimeError: boom', line: 3, column: null },
    { severity: 'warning', message: 'mended', line: 2, column: 5 },
    { severity: 'warning', message: 'meshed coarse', line: null, column: null },
  ];
  expect(marksOf([findingOf({})], problems)).toEqual([
    findingOf({}),
    { severity: 'error', message: 'RuntimeError: boom', line: 3, column: 1 },
    { severity: 'warning', message: 'mended', line: 2, column: 5 },
  ]);
  // It doesn't parse: check says why, where, and the run's error would say it again
  const syntax = findingOf({ severity: 'error', message: "Expected 'r_paren'" });
  expect(marksOf([syntax], problems).map((mark) => mark.message)).toEqual([
    "Expected 'r_paren'",
    'mended',
  ]);
});
