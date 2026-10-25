// @kupcad/editor: CodeMirror 6 for a KupCAD script, for any host (Editor), and for Svelte
// (`@kupcad/editor/svelte`); the language alone, for a host's own CodeMirror (kupcad()); and a
// client of `kupcad lsp` over a byte stream for it (language-server.js).

export { Editor, LANGUAGE_ID } from './editor.js';
export { diagnosticsOf, positionOf } from './findings.js';
export { completeKupcad, kupcad, kupcadLanguage } from './language.js';
export {
  FramingError,
  frameMessage,
  languageServerClient,
  MessageReader,
  streamTransport,
} from './language-server.js';
export { editorTheme, highlightStyle } from './theme.js';

/** @typedef {import('./findings.js').Mark} Mark */
/** @typedef {import('./language-server.js').ByteStream} ByteStream */
/** @typedef {import('@codemirror/lsp-client').LSPClient} LSPClient */
