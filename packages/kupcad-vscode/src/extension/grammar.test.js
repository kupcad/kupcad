// The TextMate grammar the extension gives VS Code (syntaxes/kupcad.tmLanguage.json, which the
// core's `zig build grammar` writes), its word rules run on lines of a script. JavaScript's
// RegExp reads these patterns as VS Code's Oniguruma does: `\w`, a lookbehind, `\?`.

import { readFileSync } from 'node:fs';
import { expect, it } from 'vitest';

const grammar = JSON.parse(
  readFileSync(new URL('../../syntaxes/kupcad.tmLanguage.json', import.meta.url), 'utf8'),
);
/** The repository's rules of words: the keywords, the functions and methods by kind. */
const WORD_RULES = [
  'keywords',
  'builtins',
  'core_methods',
  'primitives_3d',
  'primitives_2d',
  'transforms',
  'csg_operators',
  'inspections',
];

/**
 * What the repository's rule `rule` highlights in `line`.
 * @param {string} rule
 * @param {string} line
 */
const highlighted = (rule, line) =>
  [...line.matchAll(new RegExp(grammar.repository[rule].match, 'g'))].map((match) => match[0]);

/**
 * What `words` gives for each word rule, by the rule's name.
 * @param {(rule: string) => string[]} words
 */
const byRule = (words) => Object.fromEntries(WORD_RULES.map((rule) => [rule, words(rule)]));

it('highlights a keyword or a function whole, never in a name', () => {
  // `for` and `m` (a unit) in platform, `do` in standoff, `offset` after `_`: each was, once
  const line = 'platform_offset = standoff_dist + do_end + offset_x + ends';
  expect(byRule((rule) => highlighted(rule, line))).toEqual(byRule(() => []));
  expect(highlighted('keywords', '[1, 2].map do |i| i end')).toEqual(['do', 'end']);
  // A method named as a keyword is a method
  expect(highlighted('keywords', 'shape.end')).toEqual([]);
  expect(highlighted('transforms', 'body.offset(2)')).toEqual(['offset']);
});

it('highlights a method whose name ends in ? with it', () => {
  expect(highlighted('core_methods', 'xs.empty? && xs.all? { |x| x }')).toEqual(['empty?', 'all?']);
});
