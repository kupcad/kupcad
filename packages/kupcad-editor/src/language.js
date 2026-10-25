// KupCAD as CodeMirror reads it. Its literals are Ruby's (strings with interpolation, the single
// quoted ones, %w and %q, heredocs, symbols, comments), so CodeMirror's Ruby mode reads them and
// indents the blocks; its words are the core's (vocabulary.json, which `zig build grammar`
// writes from the lexer and the stdlib), so a word is a keyword, a function or a method as the
// language has it, not as Ruby does. Completion offers the same words.

import { completeFromList } from '@codemirror/autocomplete';
import { LanguageSupport, StreamLanguage } from '@codemirror/language';
import { ruby } from '@codemirror/legacy-modes/mode/ruby';
import vocabulary from './vocabulary.json' with { type: 'json' };

/** @import { CompletionContext, CompletionResult } from '@codemirror/autocomplete' */
/** @import { StreamParser, StringStream } from '@codemirror/language' */

const KEYWORDS = new Set(vocabulary.keywords);
const FUNCTIONS = new Set(vocabulary.functions);
const METHODS = new Set(vocabulary.methods);
/** The highlighting tags the words get: lezer's names, a modifier after a dot. */
const TOKENS = /** @type {const} */ ({
  keyword: 'keyword',
  function: 'variableName.function.standard',
  method: 'propertyName.function.standard',
  property: 'propertyName',
  className: 'className',
  definition: 'variableName.definition',
  variable: 'variableName',
});
/** A word before the cursor, or a method's name after its dot. */
const WORD_BEFORE = /\.?[\w?!]*$/;
const METHOD_NAME = /^[\w?!]*$/;

/** @typedef {Record<string, unknown>} RubyState */
/** The Ruby mode, whose state starts and indents (its type leaves them optional). */
const rubyMode =
  /** @type {Required<Pick<StreamParser<RubyState>, 'startState' | 'indent'>> & StreamParser<RubyState>} */ (
    /** @type {unknown} */ (ruby)
  );

/**
 * The Ruby mode's state, and whether a `for` waits for its `in` (a keyword there alone).
 * @typedef {{ ruby: RubyState, forOpen: boolean }} State
 */

/** @type {StreamParser<State>} */
const parser = {
  name: 'kupcad',
  startState: (indentUnit) => ({ ruby: rubyMode.startState(indentUnit), forOpen: false }),
  copyState: (state) => ({ ruby: copyFields(state.ruby), forOpen: state.forOpen }),
  token(stream, state) {
    if (stream.sol()) state.forOpen = false;
    const style = rubyMode.token(stream, state.ruby);
    return style ? styleOf(stream, style, state) : null;
  },
  indent: (state, textAfter, context) => rubyMode.indent(state.ruby, textAfter, context),
  languageData: rubyMode.languageData,
};

/**
 * What the Ruby mode called a token, as KupCAD has it: a word by the core's vocabulary.
 * @param {StringStream} stream
 * @param {string} style the Ruby mode's
 * @param {State} state
 * @returns {string}
 */
function styleOf(stream, style, state) {
  const word = stream.current();
  switch (style) {
    case 'property':
      return METHODS.has(word) ? TOKENS.method : TOKENS.property;
    case 'tag':
      return TOKENS.className;
    case 'def':
      return TOKENS.definition;
    case 'keyword':
    case 'variable':
      if (word === 'for') state.forOpen = true;
      if (KEYWORDS.has(word)) return TOKENS.keyword;
      if (word === 'in' && state.forOpen) {
        state.forOpen = false;
        return TOKENS.keyword;
      }
      return FUNCTIONS.has(word) ? TOKENS.function : TOKENS.variable;
    default:
      return style;
  }
}

/**
 * A copy of a mode's state, as CodeMirror copies one whose mode has no copyState of its own (the
 * Ruby mode's): its fields, an array among them copied.
 * @param {RubyState} state
 * @returns {RubyState}
 */
function copyFields(state) {
  return Object.fromEntries(
    Object.entries(state).map(([key, value]) => [key, Array.isArray(value) ? [...value] : value]),
  );
}

/** KupCAD's language, for an editor to read a script by. */
export const kupcadLanguage = StreamLanguage.define(parser);

const completeKeywordOrFunction = completeFromList([
  ...vocabulary.keywords.map((label) => ({ label, type: 'keyword' })),
  ...vocabulary.functions.map((label) => ({ label, type: 'function' })),
]);
const METHOD_OPTIONS = vocabulary.methods.map((label) => ({ label, type: 'method' }));

/**
 * Completes a word with the keywords and the functions, and a name after a dot with the methods.
 * @param {CompletionContext} context
 * @returns {CompletionResult | null | Promise<CompletionResult | null>}
 */
export function completeKupcad(context) {
  const before = context.matchBefore(WORD_BEFORE);
  if (!before || (before.from === before.to && !context.explicit)) return null;
  if (!before.text.startsWith('.')) return completeKeywordOrFunction(context);
  return { from: before.from + 1, options: METHOD_OPTIONS, validFor: METHOD_NAME };
}

/** KupCAD for an editor: the language, and completion of its words. */
export function kupcad() {
  return new LanguageSupport(
    kupcadLanguage,
    kupcadLanguage.data.of({ autocomplete: completeKupcad }),
  );
}
