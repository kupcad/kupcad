import { Text } from '@codemirror/state';
import { EditorView } from '@codemirror/view';
import { EditorState } from '@codemirror/state';
import { testCore } from '@kupcad/wasm/testing';
import { describe, expect, it } from 'vitest';
import { diagnosticsOf, positionOf } from './findings.js';

/** @import { Mark } from './findings.js' */

describe('a place the core names', () => {
  it('is its line and column, the column in UTF-8 bytes; past the text, its end', () => {
    const doc = Text.of(['x = 1', 'label = "é" + y', 'end']);
    // `y` is byte 16 of line 2: é is two bytes, one character
    expect(doc.sliceString(positionOf(doc, 2, 16), positionOf(doc, 2, 17))).toBe('y');
    expect(positionOf(doc, 2, 99)).toBe(doc.line(2).to);
    expect(positionOf(doc, 9, 1)).toBe(doc.line(3).from);
  });
});

describe('diagnosticsOf', () => {
  it("marks each finding from its place to its end, a run's place as a point", () => {
    const doc = Text.of(['w = 1', 'cube(w)']);
    /** @type {Mark[]} */
    const marks = [
      {
        severity: 'warning',
        message: 'unused',
        line: 1,
        column: 1,
        endLine: 1,
        endColumn: 2,
        code: 'unused-variable',
      },
      { severity: 'error', message: 'RuntimeError: boom', line: 2, column: 6 },
    ];
    const [unused, boom] = diagnosticsOf(doc, marks);
    expect(unused).toMatchObject({
      from: 0,
      to: 1,
      severity: 'warning',
      message: 'unused',
      source: 'unused-variable',
    });
    expect(boom).toMatchObject({ from: 11, to: 11, severity: 'error' });
    expect(boom.actions).toBeUndefined();
  });

  it("places the core's own findings, and makes their fix, on the text they were found in", async () => {
    const source = 'label = "é"\nunused = 3\ncube(2)\n';
    const findings = await (await testCore()).check(source);
    const view = new EditorView({ state: EditorState.create({ doc: source }) });
    try {
      const diagnostics = diagnosticsOf(view.state.doc, findings);
      expect(diagnostics.map((d) => view.state.doc.sliceString(d.from, d.to))).toEqual([
        'label',
        'unused',
      ]);
      const rename = diagnostics[1].actions?.[0];
      expect(rename?.name).toBe("Rename 'unused' to '_unused'");
      // Not on another text: its places are this one's; the same text again is this one
      view.dispatch({ changes: { from: 0, insert: '\n' } });
      rename?.apply(view, 0, 0);
      expect(view.state.doc.toString()).not.toContain('_unused');
      view.dispatch({ changes: { from: 0, to: 1 } });
      rename?.apply(view, 0, 0);
      expect(view.state.doc.line(2).text).toBe('_unused = 3');
    } finally {
      view.destroy();
    }
  });
});
