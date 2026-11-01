// What every host of the viewer's page does alike (the VS Code extension's panel, the desktop
// app's page): keeps the values each script's parameters were given, and writes them as
// `kupcad build -p` takes them, limits the memory a script it runs may hold (its setting), reads
// the viewport socket's URL from the port the language server names, and takes a page's message
// about the document shown alone. The hosts differ in the rest (presets, exports, where a place is shown).

/** @import { ParamValue, ParamValues, ShownDocument, ViewerMessage } from './types.js' */

/**
 * `values` as `kupcad build` options: `-p name=text` each, an array's or an object's text its
 * JSON (`String` wrote `[10, 20]` as `10,20`, which no Array parameter reads).
 * @param {ParamValues} values
 * @returns {string[]}
 */
export const paramOptions = (values) =>
  Object.entries(values).flatMap(([name, value]) => ['-p', `${name}=${paramText(value)}`]);

/**
 * `value` as the text after `-p name=`.
 * @param {ParamValue} value
 * @returns {string}
 */
export const paramText = (value) =>
  typeof value === 'object' ? JSON.stringify(value) : String(value);

/**
 * The most memory, in GB, a script a host runs may hold, unless the person sets more: the
 * default of the hosts' setting. `kupcad` itself has none, and a script someone else wrote,
 * opened in the editor, could take the machine down (one reached 60 GB in 15 s).
 */
export const DEFAULT_MEMORY_LIMIT_GB = 8;
/** The largest the setting may be: a petabyte, past which it is the default again. */
const MAX_MEMORY_LIMIT_GB = 1024 * 1024;

/**
 * The memory limit, in GB, a setting holds: a whole number from 1 up to a petabyte; anything
 * else (none, a hand-edited file's text, 0) is the default, as kupcad would refuse it.
 * @param {unknown} gigabytes
 * @returns {number}
 */
export function memoryLimitOf(gigabytes) {
  const valid =
    typeof gigabytes === 'number' &&
    Number.isInteger(gigabytes) &&
    gigabytes >= 1 &&
    gigabytes <= MAX_MEMORY_LIMIT_GB;
  return valid ? gigabytes : DEFAULT_MEMORY_LIMIT_GB;
}

/**
 * `kupcad build`'s and `kupcad lsp`'s option for a host's memory limit of `gigabytes`
 * (`memoryLimitOf`), the same setting for an export and the preview, so a model the host exports
 * previews too. It wins over a project's `vm_memory_limit`, as the command line wins over the
 * project's file (core/src/cli/memory_flag.zig).
 * @param {unknown} gigabytes
 * @returns {string[]}
 */
export const memoryLimitOptions = (gigabytes) => [
  '--memory-limit',
  `${memoryLimitOf(gigabytes)}GB`,
];

/** Where the language server's viewport socket listens. */
export const VIEWPORT_HOST = '127.0.0.1';
/** The largest port there is. */
const MAX_PORT = 65535;

/**
 * The socket the viewer connects to, at the port `kupcad/viewportReady` named; null for one
 * that is no port (the notification is the server's, read as it came).
 * @param {unknown} port
 * @returns {string | null}
 */
export function viewportUrl(port) {
  return Number.isInteger(port) &&
    /** @type {number} */ (port) > 0 &&
    /** @type {number} */ (port) <= MAX_PORT
    ? `ws://${VIEWPORT_HOST}:${port}`
    : null;
}

/**
 * The document `message` names when it isn't the one `shown`; null when it names that one or
 * none. A page naming another would have its host write beside it, build it or open it, so its
 * message is refused.
 * @param {ViewerMessage} message
 * @param {ShownDocument | null} shown
 * @returns {string | null}
 */
export function anotherDocument(message, shown) {
  return 'uri' in message && message.uri !== shown?.uri ? message.uri : null;
}

/**
 * The values each script's parameters were given (the panel, a preset), by the script's URI:
 * what the language server runs it with, and what an export builds it with.
 */
export class ScriptValues {
  /** @type {Map<string, ParamValues>} */
  #values = new Map();

  /**
   * The values the script at `uri` was given: none when it was given none.
   * @param {string} uri
   * @returns {ParamValues}
   */
  of(uri) {
    return this.#values.get(uri) ?? {};
  }

  /**
   * Whether the script at `uri` was given values.
   * @param {string} uri
   */
  has(uri) {
    return this.#values.has(uri);
  }

  /**
   * @param {string} uri
   * @param {ParamValues} values
   */
  set(uri, values) {
    this.#values.set(uri, values);
  }

  /** Every script given values, with them. */
  entries() {
    return this.#values.entries();
  }
}
