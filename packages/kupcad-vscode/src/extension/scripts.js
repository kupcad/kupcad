// What the extension says of the KupCAD scripts it works on: their language, that they are
// files, their names, a place in one as VS Code counts it, and that there is no kupcad to run
// them with.

/** @import { TextDocument, Uri } from 'vscode' */

export const LANGUAGE_ID = 'kupcad';
/** The scheme of the documents kupcad runs: files, not an untitled one or a diff's. */
export const FILE_SCHEME = 'file';
const EXTENSION = /\.kup$/;

/**
 * Whether `document` is a KupCAD script in a file: one the language server runs.
 * @param {Pick<TextDocument, 'languageId' | 'uri'>} document
 */
export const isScriptFile = (document) =>
  document.languageId === LANGUAGE_ID && document.uri.scheme === FILE_SCHEME;

/**
 * The file a script's URI names: the last part of its path.
 * @param {Uri} uri
 */
export const fileName = (uri) => uri.path.slice(uri.path.lastIndexOf('/') + 1);

/**
 * A script's name: its file's without `.kup`, what an export or a screenshot is named after.
 * @param {Uri} uri
 */
export const scriptName = (uri) => fileName(uri).replace(EXTENSION, '');

/**
 * Where a 1-based column in UTF-8 bytes, as the core counts (a warning's), is in a line's `text`
 * as VS Code counts: UTF-16 code units from 0. Past the line, its end.
 * @param {string} text
 * @param {number} column
 */
export function characterAt(text, column) {
  let bytes = 0;
  let at = 0;
  for (const char of text) {
    if (bytes >= column - 1) break;
    const code = /** @type {number} */ (char.codePointAt(0));
    bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
    at += char.length;
  }
  return at;
}

/** What a command that needs kupcad says when none runs. */
export const NOT_RUNNING =
  "KupCAD's language server isn't running, nor a kupcad to build with: the KupCAD output says why.";
