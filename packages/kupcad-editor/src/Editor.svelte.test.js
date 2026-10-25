import { forEachDiagnostic } from '@codemirror/lint';
import { EditorView } from '@codemirror/view';
import { render } from '@testing-library/svelte';
import { tick } from 'svelte';
import { expect, it } from 'vitest';
import Editor from './Editor.svelte';

it('binds the script both ways, marks the findings given, and frees CodeMirror unmounted', async () => {
  let value = 'cube(1)\n';
  /** @type {import('./editor.js').Editor | null} */
  let editor = null;
  const { rerender, unmount, container } = render(Editor, {
    props: {
      get value() {
        return value;
      },
      set value(next) {
        value = next;
      },
      get editor() {
        return editor;
      },
      set editor(made) {
        editor = made;
      },
      findings: [],
    },
  });
  const view = /** @type {EditorView} */ (
    EditorView.findFromDOM(/** @type {HTMLElement} */ (container.querySelector('.cm-editor')))
  );
  expect(editor).not.toBeNull();
  // The user's change reaches the binding
  view.dispatch({ changes: { from: 5, to: 6, insert: '4' } });
  expect(value).toBe('cube(4)\n');
  // The host's reaches the editor
  await rerender({ value: 'sphere(2)\n' });
  expect(view.state.doc.toString()).toBe('sphere(2)\n');
  await rerender({
    findings: [
      { severity: 'error', message: 'boom', line: 1, column: 1, endLine: 1, endColumn: 7 },
    ],
  });
  await tick();
  let marked = 0;
  forEachDiagnostic(view.state, () => (marked += 1));
  expect(marked).toBe(1);
  unmount();
  expect(editor).toBeNull();
  expect(container.querySelector('.cm-editor')).toBeNull();
});
