// A place the core names (a warning's, a finding's) as a JavaScript string counts it: the core's
// columns are 1-based and count UTF-8 bytes, a string's indices count UTF-16 code units from 0.

/**
 * Where a 1-based column in UTF-8 bytes is in a line's `text`, as an index into it (UTF-16 code
 * units from 0, as an editor counts). Past the line, its end.
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
