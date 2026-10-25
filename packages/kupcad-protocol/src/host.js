// What every host of the viewer's page does alike (the VS Code extension's panel, the desktop
// app's page): keeps the values each script's parameters were given, reads the viewport
// socket's URL from the port the language server names, and takes a page's message about the
// document shown alone. The hosts differ in the rest (presets, exports, where a place is shown).

/** @import { ParamValues, ShownDocument, ViewerMessage } from './types.js' */

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
