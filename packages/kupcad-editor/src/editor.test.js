import { undo } from '@codemirror/commands';
import { forEachDiagnostic } from '@codemirror/lint';
import { EditorView } from '@codemirror/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Editor } from './editor.js';

/** The editors a test made, disposed after it. @type {Editor[]} */
const made = [];
afterEach(() => {
  for (const editor of made.splice(0)) editor.dispose();
  document.body.replaceChildren();
});

/**
 * An editor on a box of the page, and its CodeMirror view.
 * @param {import('./editor.js').EditorOptions} [options]
 */
function editorOn(options) {
  const parent = document.createElement('div');
  document.body.append(parent);
  const editor = new Editor(parent, options);
  made.push(editor);
  const view = /** @type {EditorView} */ (EditorView.findFromDOM(parent));
  return { editor, view, parent };
}

describe('Editor', () => {
  it("tells the host of the user's changes, and not of its own", () => {
    const onchange = vi.fn();
    const { editor, view } = editorOn({ value: 'cube(1)\n', onchange, label: 'part.kup' });
    expect(editor.value).toBe('cube(1)\n');
    expect(view.contentDOM.getAttribute('aria-label')).toBe('part.kup');
    view.dispatch({ changes: { from: 5, to: 6, insert: '2' } });
    expect(onchange).toHaveBeenCalledWith('cube(2)\n');
    editor.setValue('sphere(3)\n');
    expect(editor.value).toBe('sphere(3)\n');
    expect(onchange).toHaveBeenCalledOnce();
    // The same script again changes nothing: the cursor stays
    view.dispatch({ selection: { anchor: 3 } });
    editor.setValue('sphere(3)\n');
    expect(view.state.selection.main.head).toBe(3);
  });

  it('marks the findings given, in place of the last, and takes the cursor to a place', () => {
    const { editor, view } = editorOn({ value: 'w = 1\ncube(w)\n' });
    editor.setFindings([
      { severity: 'warning', message: 'unused', line: 1, column: 1, endLine: 1, endColumn: 2 },
    ]);
    editor.setFindings([
      { severity: 'error', message: 'boom', line: 2, column: 6, endLine: 2, endColumn: 7 },
    ]);
    /** @type {string[]} */
    const marked = [];
    forEachDiagnostic(view.state, (d, from, to) => marked.push(`${d.message} ${from}-${to}`));
    expect(marked).toEqual(['boom 11-12']);
    editor.reveal(2, 6);
    expect(view.state.selection.main.head).toBe(11);
  });

  it('starts as a snapshot of another left it: its undo history, its selection', () => {
    const first = editorOn({ value: 'cube(1)\n' });
    first.view.dispatch({ changes: { from: 5, to: 6, insert: '2' }, selection: { anchor: 6 } });
    const snapshot = JSON.parse(JSON.stringify(first.editor.snapshot()));
    first.editor.dispose();
    made.splice(made.indexOf(first.editor), 1);

    const onchange = vi.fn();
    const again = editorOn({ value: 'cube(2)\n', restore: snapshot, onchange });
    expect(again.view.state.selection.main.head).toBe(6);
    expect(undo(again.view)).toBe(true);
    expect(again.editor.value).toBe('cube(1)\n');
    expect(onchange).toHaveBeenCalledExactlyOnceWith('cube(1)\n');
  });

  it("puts the host's text in place of a snapshot's where they differ, undoably", () => {
    const first = editorOn({ value: 'cube(1)\n' });
    const snapshot = first.editor.snapshot();
    // The file changed on disk since the snapshot
    const { editor, view } = editorOn({ value: 'sphere(2)\n', restore: snapshot });
    expect(editor.value).toBe('sphere(2)\n');
    expect(undo(view)).toBe(true);
    expect(editor.value).toBe('cube(1)\n');
  });

  it("passes over a snapshot it can't read", () => {
    const { editor, view } = editorOn({ value: 'cube(1)\n', restore: { doc: 7, history: 'no' } });
    expect(editor.value).toBe('cube(1)\n');
    expect(undo(view)).toBe(false);
  });

  it('is gone from its box once disposed', () => {
    const { editor, parent } = editorOn();
    expect(parent.querySelector('.cm-editor')).not.toBeNull();
    editor.dispose();
    made.length = 0;
    expect(parent.querySelector('.cm-editor')).toBeNull();
  });
});
