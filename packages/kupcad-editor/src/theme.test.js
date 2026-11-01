import { json } from '@codemirror/lang-json';
import { highlightTree } from '@lezer/highlight';
import { describe, expect, it } from 'vitest';
import { kupcadLanguage } from './language.js';
import { highlightStyle, jsonHighlightStyle } from './theme.js';

/** @import { HighlightStyle } from '@codemirror/language' */

/**
 * The code colour token (`--kc-code-<kind>`) each class of `style` sets, by class.
 * @param {HighlightStyle} style
 */
function kindsByClass(style) {
  /** @type {Map<string, string>} */
  const kinds = new Map();
  for (const rule of /** @type {{ getRules(): string }} */ (style.module).getRules().split('\n')) {
    const found = /^\.(\S+) \{.*var\(--kc-code-([a-z]+),/.exec(rule);
    if (found) kinds.set(found[1], found[2]);
  }
  return kinds;
}

/**
 * The code colour each token of `source` is drawn in, by its text.
 * @param {ReturnType<typeof kupcadLanguage.parser.parse>} tree
 * @param {string} source
 * @param {HighlightStyle} style
 * @returns {Record<string, string>}
 */
function coloursOf(tree, source, style) {
  const kinds = kindsByClass(style);
  /** @type {Record<string, string>} */
  const colours = {};
  highlightTree(tree, style, (from, to, classes) => {
    const kind = classes
      .split(' ')
      .map((c) => kinds.get(c))
      .find(Boolean);
    if (kind) colours[source.slice(from, to)] = kind;
  });
  return colours;
}

describe("the code's colours", () => {
  it('are each a --kc-code-* token, and KupCAD code draws in every one', () => {
    const source = [
      '# A bracket',
      'class Holder',
      '  def width = 12.5',
      'end',
      'shown = true',
      'cube(4).translate(x: 2).named("plate").material(color: :red)',
    ].join('\n');
    const colours = coloursOf(kupcadLanguage.parser.parse(source), source, highlightStyle);
    expect(colours).toMatchObject({
      '# A bracket': 'comment',
      class: 'keyword',
      def: 'keyword',
      Holder: 'definition',
      width: 'definition',
      12.5: 'constant',
      // The language's keyword, as the VS Code grammar has it: both from the lexer's keywords
      true: 'keyword',
      ':red': 'constant',
      cube: 'function',
      translate: 'function',
      '"plate"': 'string',
    });
    expect(new Set(Object.values(colours))).toEqual(
      new Set(['comment', 'keyword', 'definition', 'constant', 'function', 'string']),
    );
  });

  it("are a JSON file's too: its keys as definitions, its literals as code's", () => {
    const source = '{"width": 40, "round": true, "label": null, "name": "plate"}';
    const tree = json().language.parser.parse(source);
    const colours = {
      ...coloursOf(tree, source, highlightStyle),
      ...coloursOf(tree, source, jsonHighlightStyle),
    };
    expect(colours).toMatchObject({
      '"width"': 'definition',
      40: 'constant',
      true: 'constant',
      null: 'constant',
      '"plate"': 'string',
    });
  });
});
