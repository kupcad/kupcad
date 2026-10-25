// A document's presets: named sets of its parameters' values, kept beside it as JSON a person can
// read and edit: `bracket.kup`'s in `bracket.presets.json`,
// `{ "presets": { "Small": { "width": 20 } } }`. Free of the `vscode` import.

import { errorText, isParamValues } from '@kupcad/protocol';

/** @import { ParamValues } from '@kupcad/protocol/types' */

/** @typedef {Record<string, ParamValues>} Presets a document's, by name, in the file's order */

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
        `its preset "${name}" isn't values by name (a number, text or a boolean each)`,
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
