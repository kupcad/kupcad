// A panel's values as plain data, for a message or a worker: a state's proxy can't be cloned.

/** @import { ParamValues } from '@kupcad/protocol/types' */

/**
 * `values`, a state's, as plain data.
 * @param {ParamValues} values
 * @returns {ParamValues}
 */
export function plainValues(values) {
  // Snapshot's type of the recursive ParamValue is too deep for TypeScript to work out
  return /** @type {ParamValues} */ ($state.snapshot(/** @type {unknown} */ (values)));
}
