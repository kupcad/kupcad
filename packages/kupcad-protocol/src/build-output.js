// What a failed `kupcad build` said of why, read from its output, for a host that runs it (the
// VS Code extension, the desktop app) to tell the person: the script's error, not the CLI's log.
// A host asks for it as JSON (`--errors json`, `buildFailure`), one line last; the words are read
// (`whyBuildFailed`) only when there is none, as from a kupcad that wasn't asked.
//
// Read by prefixes and plain searches, in time linear in the line: the script writes this output
// (`puts`, `raise`), and the regular expressions it was read with backtracked quadratically on a
// long line of spaces (40 000 characters took 0.8 s; a few hundred thousand froze the host).

/** Where a compile error's place ends and its words begin: `path:line:col: E: words`. */
const ERROR_MARK = ': E: ';
/** Between a failed step's name and its words: `Build failed: words`. */
const FAILED_MARK = ' failed: ';

/**
 * An error the run raised, its log line's words: `error(vm): RuntimeError: too thin`.
 * @param {string} line
 * @returns {string | null}
 */
function raised(line) {
  if (!line.startsWith('error(')) return null;
  const close = line.indexOf(')');
  if (line[close + 1] !== ':') return null;
  return line.slice(close + 2).trim() || null;
}

/**
 * A syntax or compile error at its place, the whole line: `/w/bad.kup:2:1: E: Invalid expression`.
 * @param {string} line
 * @returns {string | null}
 */
function atPlace(line) {
  for (let at = line.indexOf(ERROR_MARK); at >= 0; at = line.indexOf(ERROR_MARK, at + 1)) {
    if (endsWithPlace(line, at) && at + ERROR_MARK.length < line.length) return line;
  }
  return null;
}

/**
 * The CLI's refusal: `Error: Unknown option '--bogus'`.
 * @param {string} line
 * @returns {string | null}
 */
const refused = (line) =>
  line.startsWith('Error: ') ? line.slice('Error: '.length) || null : null;

/**
 * Its summary, the whole line: `Build failed: error.OutOfMemory`.
 * @param {string} line
 * @returns {string | null}
 */
function summary(line) {
  const at = line.indexOf(FAILED_MARK);
  if (at <= 0 || at + FAILED_MARK.length >= line.length) return null;
  return /^\w+$/.test(line.slice(0, at)) ? line : null;
}

/** The kinds of line that say why, best first. */
const WHY = [raised, atPlace, refused, summary];

/**
 * Whether `line` has a place, `something:line:col`, ending at `end`: digits, a colon, digits, a
 * colon, and at least one character before. It looks back no further than the place itself.
 * @param {string} line
 * @param {number} end
 */
function endsWithPlace(line, end) {
  let at = end;
  for (let part = 0; part < 2; part++) {
    const digitsEnd = at;
    while (at > 0 && isDigit(line.charCodeAt(at - 1))) at--;
    if (at === digitsEnd || line[at - 1] !== ':') return false;
    at--;
  }
  return at > 0;
}

/** @param {number} code */
const isDigit = (code) => code >= 48 && code <= 57;

/** @import { BuildFailure } from './types.js' */

/** How a failure's JSON line starts: `{"error": {...}}`. */
const FAILURE_START = '{"error"';

/**
 * Why a build failed, as `kupcad build --errors json` tells it: the last line that is an
 * `{"error": ...}` object, with its kind, its message and, where known, the file, line and
 * column; null without one (a kupcad that wasn't asked, or a failure before it could say),
 * when `whyBuildFailed` reads the words instead.
 * @param {string} stderr
 * @returns {BuildFailure | null}
 */
export function buildFailure(stderr) {
  const lines = stderr.split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line.startsWith(FAILURE_START)) continue;
    /** @type {unknown} */
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch {
      return null;
    }
    const error = /** @type {{ error?: Record<string, unknown> }} */ (parsed)?.error;
    if (typeof error?.kind !== 'string' || typeof error.message !== 'string') return null;
    return {
      kind: error.kind,
      message: error.message,
      file: typeof error.file === 'string' ? error.file : null,
      line: Number.isInteger(error.line) ? /** @type {number} */ (error.line) : null,
      column: Number.isInteger(error.column) ? /** @type {number} */ (error.column) : null,
    };
  }
  return null;
}

/**
 * What a failed build said of why (the first line of the best kind found), or null when it said
 * nothing that does. The script's own output (`puts`, a warning) is none of them.
 * @param {string} stderr
 * @returns {string | null}
 */
export function whyBuildFailed(stderr) {
  const lines = stderr.split('\n').map((line) => line.trim());
  for (const read of WHY) {
    for (const line of lines) {
      const said = read(line);
      if (said !== null) return said;
    }
  }
  return null;
}

/**
 * Why a build failed, for the person: what its JSON line says (`buildFailure`), else its words
 * (`whyBuildFailed`), else `fallback` (what the host knows: how the process ended). Each host
 * read it so itself.
 * @param {string} stderr
 * @param {string} fallback
 * @returns {string}
 */
export const failureText = (stderr, fallback) =>
  buildFailure(stderr)?.message ?? whyBuildFailed(stderr) ?? fallback;
