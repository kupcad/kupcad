// A document's presets: named sets of its parameters' values, kept beside it as JSON a person can
// read and edit: `bracket.kup`'s in `bracket.presets.json`,
// `{ "presets": { "Small": { "width": 20 } } }`. The file's format alone: a host reads and
// writes it with its own file system.

import { errorText } from './error-text.js';
import { isParamValues } from './messages.js';

/** @import { Presets } from './types.js' */

const INDENT = 2;

/** A presets file that can't be read as one, saying why. */
export class PresetsError extends Error {
  /** @param {string} message */
  constructor(message) {
    super(message);
    this.name = 'PresetsError';
  }
}

/**
 * The path of the presets file of the script at `scriptPath`.
 * @param {string} scriptPath
 */
export const presetsPathOf = (scriptPath) => scriptPath.replace(/(\.kup)?$/, '.presets.json');

/**
 * The presets a file's text holds.
 * @param {string} text
 * @returns {Presets}
 * @throws {PresetsError}
 */
export function readPresets(text) {
  /** @type {unknown} */
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    throw new PresetsError(`it is no JSON (${errorText(error)})`);
  }
  const presets = /** @type {{ presets?: unknown } | null} */ (parsed)?.presets;
  if (typeof presets !== 'object' || presets === null || Array.isArray(presets)) {
    throw new PresetsError('it has no "presets" object');
  }
  for (const [name, values] of Object.entries(presets)) {
    if (!isParamValues(values)) {
      throw new PresetsError(
        `its preset "${name}" isn't values by name (a number, text, a boolean, or an array or an object of them, each)`,
      );
    }
  }
  return /** @type {Presets} */ (presets);
}

/**
 * A presets file's text: indented, a line at its end.
 * @param {Presets} presets
 */
export const writePresets = (presets) => `${JSON.stringify({ presets }, null, INDENT)}\n`;
