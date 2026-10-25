import { CompletionContext } from '@codemirror/autocomplete';
import { getIndentation, indentUnit } from '@codemirror/language';
import { EditorState } from '@codemirror/state';
import { highlightTree, tagHighlighter, tags } from '@lezer/highlight';
import { describe, expect, it } from 'vitest';
import { completeKupcad, kupcad, kupcadLanguage } from './language.js';

/** @import { CompletionResult } from '@codemirror/autocomplete' */

/** Each kind of token, by a name the tests read. */
const KINDS = tagHighlighter([
  { tag: tags.keyword, class: 'keyword' },
  { tag: tags.standard(tags.function(tags.variableName)), class: 'function' },
  { tag: tags.standard(tags.function(tags.propertyName)), class: 'method' },
  { tag: tags.propertyName, class: 'property' },
  { tag: tags.className, class: 'class' },
  { tag: tags.definition(tags.variableName), class: 'definition' },
  { tag: tags.variableName, class: 'variable' },
  { tag: [tags.string, tags.special(tags.string)], class: 'string' },
  { tag: tags.comment, class: 'comment' },
  { tag: tags.atom, class: 'atom' },
  { tag: tags.number, class: 'number' },
]);

/**
 * The kind of each token of `source` the language highlights, by its text.
 * @param {string} source
 * @returns {Record<string, string>}
 */
function kindsOf(source) {
  /** @type {Record<string, string>} */
  const kinds = {};
  highlightTree(kupcadLanguage.parser.parse(source), KINDS, (from, to, kind) => {
    kinds[source.slice(from, to)] = kind;
  });
  return kinds;
}

/**
 * A state of `doc` read as KupCAD, indented two spaces a level.
 * @param {string} doc
 */
const stateOf = (doc) => EditorState.create({ doc, extensions: [kupcad(), indentUnit.of('  ')] });

/**
 * What completing `doc`, the cursor at its end, offers.
 * @param {string} doc
 * @param {boolean} [explicit] asked for (Ctrl+Space), not typed
 */
async function complete(doc, explicit = false) {
  const result = /** @type {CompletionResult | null} */ (
    await completeKupcad(new CompletionContext(stateOf(doc), doc.length, explicit))
  );
  return result && { from: result.from, labels: result.options.map((o) => o.label) };
}

describe('KupCAD as the editor reads it', () => {
  it("tells the core's words apart: keywords, functions and methods, not Ruby's", () => {
    const kinds = kindsOf(
      [
        'import { side } from "./lib.kup"',
        'w = param(:width, default: 20)',
        'part = cube(w).translate(x: 1).named("part").wobble',
        'raise "too thin" if w < 1',
        'export part',
      ].join('\n'),
    );
    expect(kinds).toMatchObject({
      import: 'keyword',
      from: 'keyword',
      export: 'keyword',
      if: 'keyword',
      param: 'function',
      cube: 'function',
      // A keyword to Ruby, a function to KupCAD
      raise: 'function',
      translate: 'method',
      named: 'method',
      // No method the core has
      wobble: 'property',
      w: 'variable',
      ':width': 'atom',
      'default:': 'atom',
      '"./lib.kup"': 'string',
      20: 'number',
    });
  });

  it('reads `in` as a keyword after `for` alone, and names, classes and literals as Ruby has them', () => {
    expect(kindsOf('for i in [1, 2]\n  puts i\nend\n')).toMatchObject({
      for: 'keyword',
      in: 'keyword',
      puts: 'function',
      end: 'keyword',
    });
    expect(kindsOf('def plate(r)\n  CAD.config(engine: :brep)\nend\n')).toMatchObject({
      plate: 'definition',
      CAD: 'class',
      config: 'method',
    });
    const literals = kindsOf("# a note\nlabel = 'single'\nnames = %w[a b]\n");
    expect(literals['# a note']).toBe('comment');
    expect(literals["'single'"]).toBe('string');
    expect(literals['%w[a b]']).toBe('string');
  });

  it('indents a block, and puts its end back', () => {
    const state = stateOf('[1, 2].each do |i|\nputs i\nend\n');
    expect(getIndentation(state, state.doc.line(2).from)).toBe(2);
    expect(getIndentation(state, state.doc.line(3).from)).toBe(0);
    expect(kupcadLanguage.data.of).toBeTypeOf('function');
  });

  it('completes a word with the keywords and functions, a name after a dot with the methods', async () => {
    const word = await complete('x = cu');
    expect(word?.from).toBe(4);
    expect(word?.labels).toContain('cube');
    expect(word?.labels).toContain('class');
    const method = await complete('cube(1).tra');
    expect(method?.from).toBe(8);
    expect(method?.labels).toContain('translate');
    expect(method?.labels).not.toContain('cube');
    // Nothing typed: nothing offered, unless asked for
    expect(await complete('x = ')).toBeNull();
    expect((await complete('x = ', true))?.labels).toContain('cube');
  });
});
