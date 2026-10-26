// What a host and its viewer say to each other (the VS Code extension and its webview, the
// desktop app and its window): the document the viewer shows, the values its panel gives, and
// what the viewer asks the host to do. Each side reads the other's messages with a guard, as
// they arrive untyped (`postMessage`).

/** @import { HostMessage, ParamValue, ParamValues, ViewerMessage } from './types.js' */

/** How deep a parameter's value nests (core/src/core/param_rules.zig's): a list of tuples or of objects. */
export const MAX_PARAM_DEPTH = 2;

/** @param {unknown} value @returns {value is Record<string, unknown>} */
const isObject = (value) => typeof value === 'object' && value !== null && !Array.isArray(value);
/** @param {unknown} value @returns {value is string} */
const isString = (value) => typeof value === 'string';
/** @param {unknown} value @returns {value is number} a 1-based line or column */
const isPlace = (value) => Number.isInteger(value) && /** @type {number} */ (value) >= 1;

/**
 * Whether `value` is parameter values: names to a number, a string, a boolean, or an array or
 * an object of them, nested at most MAX_PARAM_DEPTH deep.
 * @param {unknown} value
 * @returns {value is ParamValues}
 */
export function isParamValues(value) {
  return isObject(value) && Object.values(value).every((v) => isParamValue(v, MAX_PARAM_DEPTH));
}

/**
 * @param {unknown} value
 * @param {number} depth how much deeper it may nest
 * @returns {value is ParamValue}
 */
function isParamValue(value, depth) {
  if (Array.isArray(value)) return depth > 0 && value.every((v) => isParamValue(v, depth - 1));
  if (isObject(value))
    return depth > 0 && Object.values(value).every((v) => isParamValue(v, depth - 1));
  return ['number', 'string', 'boolean'].includes(typeof value);
}

/** Each host message's fields, checked: by its type. */
const HOST_MESSAGES = {
  /** @param {Record<string, unknown>} m */
  document: (m) =>
    m.document === null ||
    (isObject(m.document) && isString(m.document.uri) && isString(m.document.name)),
  /** @param {Record<string, unknown>} m */
  overrides: (m) => isString(m.uri) && isParamValues(m.values),
  /** @param {Record<string, unknown>} m */
  presets: (m) => isString(m.uri) && Array.isArray(m.names) && m.names.every(isString),
  /** @param {Record<string, unknown>} m */
  log: (m) => isString(m.text),
};

/** Each viewer message's fields, checked: by its type. */
const VIEWER_MESSAGES = {
  ready: () => true,
  /** @param {Record<string, unknown>} m */
  setParams: (m) => isString(m.uri) && isParamValues(m.values),
  /** @param {Record<string, unknown>} m */
  applyPreset: (m) => isString(m.uri) && isString(m.name),
  /** @param {Record<string, unknown>} m */
  savePreset: (m) => isString(m.uri) && isParamValues(m.values),
  /** @param {Record<string, unknown>} m */
  export: (m) => isString(m.uri),
  /** @param {Record<string, unknown>} m */
  screenshot: (m) => isString(m.png),
  /** @param {Record<string, unknown>} m */
  problem: (m) => isString(m.message),
  /** @param {Record<string, unknown>} m */
  reveal: (m) => isString(m.uri) && isPlace(m.line) && isPlace(m.column),
};

/**
 * Whether `value` is a message a host sends its viewer.
 * @param {unknown} value
 * @returns {value is HostMessage}
 */
export function isHostMessage(value) {
  return isMessage(HOST_MESSAGES, value);
}

/**
 * Whether `value` is a message a viewer sends its host.
 * @param {unknown} value
 * @returns {value is ViewerMessage}
 */
export function isViewerMessage(value) {
  return isMessage(VIEWER_MESSAGES, value);
}

/**
 * @param {Record<string, (message: Record<string, unknown>) => boolean>} kinds
 * @param {unknown} value
 */
function isMessage(kinds, value) {
  if (!isObject(value) || !isString(value.type) || !Object.hasOwn(kinds, value.type)) return false;
  return kinds[value.type](value);
}
