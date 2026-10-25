// The core's findings as CodeMirror's diagnostics: `check`'s, and a place a run named (its error,
// a warning) given as one. Each is underlined where it is and marked in the gutter, and a fix
// the core offers is an action in its tooltip. The core places them by 1-based lines and
// columns in UTF-8 bytes (@kupcad/protocol's characterAt reads them).

import { characterAt } from '@kupcad/protocol';

/** @import { Diagnostic } from '@codemirror/lint' */
/** @import { Text } from '@codemirror/state' */
/** @import { EditorView } from '@codemirror/view' */
/** @import { Finding, Fix } from '@kupcad/protocol/types' */

/**
 * What the editor marks: a finding of `check`, or a place a run named, which has no end (the
 * mark is a point there).
 * @typedef {Pick<Finding, 'severity' | 'message' | 'line' | 'column'> & Partial<Pick<Finding, 'endLine' | 'endColumn' | 'code' | 'fix'>>} Mark
 */

/**
 * Where a place the core names (a 1-based line and column in UTF-8 bytes) is in `doc`: a line
 * past its last is its last, a column past a line's end its end.
 * @param {Text} doc
 * @param {number} line
 * @param {number} column
 */
export function positionOf(doc, line, column) {
  const at = doc.line(Math.min(Math.max(line, 1), doc.lines));
  return at.from + characterAt(at.text, column);
}

/**
 * The marks as diagnostics in `doc`, the text they were found in.
 * @param {Text} doc
 * @param {readonly Mark[]} marks
 * @returns {Diagnostic[]}
 */
export function diagnosticsOf(doc, marks) {
  return marks.map((mark) => {
    const from = positionOf(doc, mark.line, mark.column);
    const end =
      mark.endLine === undefined ? from : positionOf(doc, mark.endLine, mark.endColumn ?? 1);
    /** @type {Diagnostic} */
    const diagnostic = {
      from,
      to: Math.max(from, end),
      severity: mark.severity,
      message: mark.message,
    };
    if (mark.code) diagnostic.source = mark.code;
    if (mark.fix) diagnostic.actions = [actionOf(mark.fix, doc)];
    return diagnostic;
  });
}

/**
 * A fix as an action: its edits made, on the text it was found in; once the text is another,
 * nothing (its places are the old text's: the next check offers it again, placed in the new).
 * @param {Fix} fix
 * @param {Text} doc
 */
function actionOf(fix, doc) {
  const changes = fix.edits.map((edit) => ({
    from: positionOf(doc, edit.line, edit.column),
    to: positionOf(doc, edit.endLine, edit.endColumn),
    insert: edit.text,
  }));
  return {
    name: fix.title,
    /** @param {EditorView} view */
    apply(view) {
      if (view.state.doc.eq(doc)) view.dispatch({ changes });
    },
  };
}
