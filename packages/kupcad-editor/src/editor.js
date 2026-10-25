// The editor: CodeMirror 6 for a KupCAD script, for any host; Editor.svelte wraps it for Svelte.
// It highlights the language and completes its words (language.js), indents its blocks, and
// marks the findings its host gives it (findings.js: the core's `check`, a run's error), each
// underlined and in the gutter, its fix an action. With a language server
// (language-server.js), the server completes, marks and answers instead: hovers, signatures,
// formatting, renaming, definitions. It tells its host of each change the user makes to the
// script; one the host makes (setValue) it doesn't.

import {
  autocompletion,
  closeBrackets,
  closeBracketsKeymap,
  completionKeymap,
} from '@codemirror/autocomplete';
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands';
import {
  bracketMatching,
  indentOnInput,
  indentUnit,
  syntaxHighlighting,
} from '@codemirror/language';
import { lintGutter, lintKeymap, setDiagnostics } from '@codemirror/lint';
import { highlightSelectionMatches, searchKeymap } from '@codemirror/search';
import { Annotation, EditorState } from '@codemirror/state';
import {
  drawSelection,
  EditorView,
  highlightActiveLine,
  highlightActiveLineGutter,
  keymap,
  lineNumbers,
} from '@codemirror/view';
import { diagnosticsOf, positionOf } from './findings.js';
import { kupcad } from './language.js';
import { editorTheme, highlightStyle } from './theme.js';

/** @import { LSPClient } from '@codemirror/lsp-client' */
/** @import { Mark } from './findings.js' */

/** A change the host made (setValue): not the user's, so not told back. */
const fromHost = Annotation.define();
/** Two spaces a level, as `kupcad fmt` indents. */
const INDENT = '  ';
/** The language, as a language server is told a document's (and VS Code names it). */
export const LANGUAGE_ID = 'kupcad';

/**
 * @typedef {object} EditorOptions
 * @property {string} [value] the script it starts with
 * @property {(value: string) => void} [onchange] the user changed the script: it now is `value`
 * @property {string} [label] what the script is, for a screen reader
 * @property {{ client: LSPClient, uri: string }} [languageServer] the server the script is known
 *   to, by its URI: it completes and marks the script then, and the host gives no findings
 */

export class Editor {
  /** @type {EditorView} */
  #view;

  /**
   * @param {HTMLElement} parent where it goes
   * @param {EditorOptions} [options]
   */
  constructor(parent, { value = '', onchange, label = 'The script', languageServer } = {}) {
    this.#view = new EditorView({
      parent,
      state: EditorState.create({
        doc: value,
        extensions: [
          lineNumbers(),
          highlightActiveLineGutter(),
          history(),
          drawSelection(),
          indentOnInput(),
          indentUnit.of(INDENT),
          EditorState.tabSize.of(INDENT.length),
          bracketMatching(),
          closeBrackets(),
          autocompletion(),
          highlightActiveLine(),
          highlightSelectionMatches(),
          lintGutter(),
          kupcad({ complete: !languageServer }),
          syntaxHighlighting(highlightStyle),
          editorTheme,
          keymap.of([
            ...closeBracketsKeymap,
            ...defaultKeymap,
            ...searchKeymap,
            ...historyKeymap,
            ...completionKeymap,
            ...lintKeymap,
            indentWithTab,
          ]),
          languageServer ? languageServer.client.plugin(languageServer.uri, LANGUAGE_ID) : [],
          EditorView.contentAttributes.of({ 'aria-label': label }),
          EditorView.updateListener.of((update) => {
            const user = !update.transactions.some((tr) => tr.annotation(fromHost));
            if (update.docChanged && user) onchange?.(update.state.doc.toString());
          }),
        ],
      }),
    });
  }

  /** The script as it is now. */
  get value() {
    return this.#view.state.doc.toString();
  }

  /**
   * Puts `value` in place of the script, unless it is the script already; the host isn't told.
   * @param {string} value
   */
  setValue(value) {
    if (value === this.value) return;
    this.#view.dispatch({
      changes: { from: 0, to: this.#view.state.doc.length, insert: value },
      annotations: fromHost.of(true),
    });
  }

  /**
   * Marks `findings` in place of the ones marked, found in the script as it is now.
   * @param {readonly Mark[]} findings
   */
  setFindings(findings) {
    const { state } = this.#view;
    this.#view.dispatch(setDiagnostics(state, diagnosticsOf(state.doc, findings)));
  }

  /**
   * Puts the cursor at a place the core names (a 1-based line and column, in UTF-8 bytes), in
   * view, and gives the editor the focus.
   * @param {number} line
   * @param {number} column
   */
  reveal(line, column) {
    const at = positionOf(this.#view.state.doc, line, column);
    this.#view.dispatch({
      selection: { anchor: at },
      effects: EditorView.scrollIntoView(at, { y: 'center' }),
    });
    this.#view.focus();
  }

  focus() {
    this.#view.focus();
  }

  dispose() {
    this.#view.destroy();
  }
}
