// How the editor looks: by the --kc-* tokens a host sets (@kupcad/panels's tokens.css), else the
// page's own colours (CSS system colours, light or dark as the page is); the code's colours by
// the --kc-code-* tokens (keyword, string, comment, constant, function, definition), else
// GitHub's, light or dark.

import { HighlightStyle } from '@codemirror/language';
import { EditorView } from '@codemirror/view';
import { tags } from '@lezer/highlight';

/**
 * The colour of a kind of code: its token's, else GitHub's for the page's scheme.
 * @param {string} kind
 * @param {string} light
 * @param {string} dark
 */
const code = (kind, light, dark) => `var(--kc-code-${kind}, light-dark(${light}, ${dark}))`;
const FG = 'var(--kc-fg, CanvasText)';
const BG = 'var(--kc-bg, Canvas)';
const MUTED = 'var(--kc-muted, GrayText)';
const BORDER = 'var(--kc-border, GrayText)';
const ACCENT = 'var(--kc-accent, Highlight)';

export const editorTheme = EditorView.theme({
  '&': {
    height: '100%',
    color: FG,
    backgroundColor: BG,
    fontSize: 'var(--kc-code-font-size, var(--kc-font-size, 13px))',
    // What light-dark() picks by, where the page says nothing of its scheme
    colorScheme: 'light dark',
  },
  '.cm-scroller': {
    fontFamily: 'var(--kc-code-font, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace)',
    lineHeight: '1.5',
  },
  '.cm-gutters': { color: MUTED, backgroundColor: BG, borderRight: `1px solid ${BORDER}` },
  '.cm-activeLine': { backgroundColor: `color-mix(in srgb, ${ACCENT} 6%, transparent)` },
  '.cm-activeLineGutter': { backgroundColor: `color-mix(in srgb, ${ACCENT} 10%, transparent)` },
  '.cm-cursor, .cm-dropCursor': { borderLeftColor: FG },
  '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection': {
    backgroundColor: `color-mix(in srgb, ${ACCENT} 28%, transparent)`,
  },
  '.cm-matchingBracket': { backgroundColor: `color-mix(in srgb, ${ACCENT} 20%, transparent)` },
  '.cm-tooltip': { color: FG, backgroundColor: BG, border: `1px solid ${BORDER}` },
  '.cm-tooltip-autocomplete ul li[aria-selected]': {
    color: 'var(--kc-accent-fg, HighlightText)',
    backgroundColor: ACCENT,
  },
  '.cm-panels': { color: FG, backgroundColor: BG },
});

export const highlightStyle = HighlightStyle.define([
  { tag: tags.keyword, color: code('keyword', '#cf222e', '#ff7b72') },
  { tag: [tags.string, tags.special(tags.string)], color: code('string', '#0a3069', '#a5d6ff') },
  { tag: tags.comment, color: code('comment', '#6e7781', '#8b949e'), fontStyle: 'italic' },
  {
    tag: [tags.number, tags.bool, tags.null, tags.atom],
    color: code('constant', '#0550ae', '#79c0ff'),
  },
  {
    tag: [
      tags.standard(tags.function(tags.variableName)),
      tags.standard(tags.function(tags.propertyName)),
    ],
    color: code('function', '#8250df', '#d2a8ff'),
  },
  {
    tag: [tags.definition(tags.variableName), tags.className],
    color: code('definition', '#953800', '#ffa657'),
  },
]);
