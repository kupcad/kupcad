// What a front end needs to read what the core sends it: the protocol's version and names, the
// reader of a preview frame, where a place it names is in a string (places.js), the formats it
// writes (formats.js), what an error says (error-text.js) and why a build failed
// (build-output.js); the messages between a host and its viewer (messages.js), and what every
// host does alike (host.js); and a document's presets file (presets.js). The shapes are in types.d.ts (`@kupcad/protocol/types`).

/** @import { FrameHeader, Kind, Model, Preview } from './types.js' */

/**
 * The version of the protocol this package reads (core/src/preview/frame.zig's): the preview
 * frame, `kupcad/viewportReady`, `kupcad.setParams` and `kupcad.preview`. It goes up when one of them changes
 * shape; a field added as optional leaves it.
 */
export const PROTOCOL_VERSION = 1;

/** The language server's notification of its viewport socket, a `ViewportReady`. */
export const VIEWPORT_READY_NOTIFICATION = 'kupcad/viewportReady';

/**
 * The language server's command (`workspace/executeCommand`) that gives a document's parameters
 * values: its one argument is a `SetParamsArgument`.
 */
export const SET_PARAMS_COMMAND = 'kupcad.setParams';

/**
 * The language server's command that chooses the document its viewport shows, and asks for its
 * frame: its one argument is a `PreviewArgument`.
 */
export const PREVIEW_COMMAND = 'kupcad.preview';

export { isHostMessage, isParamValues, isViewerMessage, MAX_PARAM_DEPTH } from './messages.js';
export { characterAt } from './places.js';
export { errorText } from './error-text.js';
export { whyBuildFailed } from './build-output.js';
export { EXPORT_FORMATS } from './formats.js';
export { PresetsError, presetsPathOf, readPresets, writePresets } from './presets.js';
export {
  anotherDocument,
  paramOptions,
  paramText,
  ScriptValues,
  VIEWPORT_HOST,
  viewportUrl,
} from './host.js';

/** The bytes before a frame's header: its length, u32 little-endian. */
const LENGTH_BYTES = 4;

/** @type {readonly Kind[]} */
const KINDS = ['3d', '2d', 'none'];

/** A frame this package can't read: cut short, not JSON, or of another protocol version. */
export class ProtocolError extends Error {
  /** @param {string} message */
  constructor(message) {
    super(message);
    this.name = 'ProtocolError';
  }
}

/**
 * Whether this package reads what a core speaking `protocolVersion` sends (a frame's,
 * `kupcad/viewportReady`'s, `kupcad version --json`'s).
 * @param {unknown} protocolVersion
 * @returns {boolean}
 */
export function isCompatible(protocolVersion) {
  return protocolVersion === PROTOCOL_VERSION;
}

/**
 * The preview frame in `bytes`, as the core writes it: the header's length (u32,
 * little-endian), the header (JSON), then the body, the model as GLB for a '3d' frame, as SVG
 * for a '2d' one, nothing for 'none'. The GLB is a view on `bytes`, not a copy.
 * @param {ArrayBuffer | Uint8Array} bytes
 * @returns {Preview}
 * @throws {ProtocolError} when the frame is cut short, its header isn't a JSON object, or it is
 *   of a protocol version or a kind this package doesn't know.
 */
export function readFrame(bytes) {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  if (view.byteLength < LENGTH_BYTES) {
    throw new ProtocolError(`a frame of ${view.byteLength} bytes has no header length`);
  }
  const headerLength = new DataView(view.buffer, view.byteOffset, LENGTH_BYTES).getUint32(0, true);
  const bodyStart = LENGTH_BYTES + headerLength;
  if (bodyStart > view.byteLength) {
    throw new ProtocolError(
      `a frame of ${view.byteLength} bytes is too short for its header of ${headerLength}`,
    );
  }
  const header = parseHeader(new TextDecoder().decode(view.subarray(LENGTH_BYTES, bodyStart)));
  return { header, model: modelOf(header, view.subarray(bodyStart)) };
}

/**
 * @param {string} text
 * @returns {FrameHeader}
 */
function parseHeader(text) {
  /** @type {unknown} */
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new ProtocolError('a frame header is not JSON');
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new ProtocolError('a frame header is not a JSON object');
  }
  const header = /** @type {FrameHeader} */ (parsed);
  if (!isCompatible(header.protocolVersion)) {
    throw new ProtocolError(
      `a frame of protocol version ${header.protocolVersion}; this reads version ${PROTOCOL_VERSION}`,
    );
  }
  if (!KINDS.includes(header.kind)) throw new ProtocolError(`a frame of kind ${header.kind}`);
  return header;
}

/**
 * The model a frame's body is, as its header's kind says.
 * @param {FrameHeader} header
 * @param {Uint8Array} body
 * @returns {Model}
 */
function modelOf(header, body) {
  switch (header.kind) {
    case '3d':
      return { kind: '3d', glb: body, parts: header.parts };
    case '2d':
      return { kind: '2d', svg: new TextDecoder().decode(body) };
    case 'none':
      return { kind: 'none' };
  }
}
