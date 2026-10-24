// The values the user gives each script's parameters (the viewer's panel, a preset), by the
// script's URI: what the language server runs it with, and what an export builds it with.

/** @import { ParamValues } from '@kupcad/protocol/types' */

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
