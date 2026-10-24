// What the extension says of the KupCAD scripts it works on: their language, their names, and
// that there is no kupcad to run them with.

/** @import { Uri } from 'vscode' */

export const LANGUAGE_ID = 'kupcad';
const EXTENSION = /\.kup$/;

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

/** What a command that needs kupcad says when none runs. */
export const NOT_RUNNING =
  "KupCAD's language server isn't running, nor a kupcad to build with: the KupCAD output says why.";
