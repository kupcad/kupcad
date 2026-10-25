// @kupcad/editor: CodeMirror 6 for a KupCAD script, for any host (Editor), and for Svelte
// (`@kupcad/editor/svelte`); the language alone, for a host's own CodeMirror (kupcad()).

export { Editor } from './editor.js';
export { diagnosticsOf, positionOf } from './findings.js';
export { completeKupcad, kupcad, kupcadLanguage } from './language.js';
export { editorTheme, highlightStyle } from './theme.js';
