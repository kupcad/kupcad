// The editor's language server (@codemirror/lsp-client): `kupcad lsp` over a stream of bytes, a
// host's child process (the desktop app's), its messages framed as LSP frames them on stdio, a
// `Content-Length` header before each JSON body. The client gives the editor the server's
// diagnostics, completion, hover, signature help, formatting, renaming and definitions.

import { LSPClient, languageServerExtensions } from '@codemirror/lsp-client';

/** @import { Transport } from '@codemirror/lsp-client' */

const HEADER_END = new TextEncoder().encode('\r\n\r\n');
const CONTENT_LENGTH = /^content-length:\s*(\d+)\s*$/im;
/** A header block longer than this is no LSP header: the stream isn't the server's. */
const MAX_HEADER_BYTES = 1024;

/** A stream that isn't framed as LSP frames its messages. */
export class FramingError extends Error {
  /** @param {string} message */
  constructor(message) {
    super(message);
    this.name = 'FramingError';
  }
}

/**
 * `message` (JSON) as LSP frames it: its length in UTF-8 bytes, then it.
 * @param {string} message
 * @returns {Uint8Array}
 */
export function frameMessage(message) {
  const body = new TextEncoder().encode(message);
  const header = new TextEncoder().encode(`Content-Length: ${body.length}\r\n\r\n`);
  const framed = new Uint8Array(header.length + body.length);
  framed.set(header);
  framed.set(body, header.length);
  return framed;
}

/** The messages in a stream of LSP frames, as its chunks arrive, cut wherever they are. */
export class MessageReader {
  #pending = new Uint8Array(0);

  /**
   * The messages `chunk` completes, in order; what it starts waits for the next.
   * @param {Uint8Array} chunk
   * @returns {string[]}
   * @throws {FramingError} for a header with no length, or none where one should be
   */
  push(chunk) {
    const joined = new Uint8Array(this.#pending.length + chunk.length);
    joined.set(this.#pending);
    joined.set(chunk, this.#pending.length);
    /** @type {string[]} */
    const messages = [];
    let at = 0;
    for (;;) {
      const headerEnd = indexOf(joined, HEADER_END, at);
      if (headerEnd === -1) {
        if (joined.length - at > MAX_HEADER_BYTES) {
          throw new FramingError(`no LSP header in the first ${MAX_HEADER_BYTES} bytes`);
        }
        break;
      }
      const header = new TextDecoder().decode(joined.subarray(at, headerEnd));
      const length = CONTENT_LENGTH.exec(header)?.[1];
      if (length === undefined) throw new FramingError(`an LSP header with no length: ${header}`);
      const bodyStart = headerEnd + HEADER_END.length;
      const bodyEnd = bodyStart + Number(length);
      if (bodyEnd > joined.length) break;
      messages.push(new TextDecoder().decode(joined.subarray(bodyStart, bodyEnd)));
      at = bodyEnd;
    }
    this.#pending = joined.slice(at);
    return messages;
  }
}

/**
 * Where `needle` first is in `bytes` from `from`, or -1.
 * @param {Uint8Array} bytes
 * @param {Uint8Array} needle
 * @param {number} from
 */
function indexOf(bytes, needle, from) {
  outer: for (let i = from; i + needle.length <= bytes.length; i++) {
    for (let j = 0; j < needle.length; j++) if (bytes[i + j] !== needle[j]) continue outer;
    return i;
  }
  return -1;
}

/**
 * A byte stream to a language server: what is written to it, and what it sends.
 * @typedef {object} ByteStream
 * @property {(bytes: Uint8Array) => void} write
 * @property {(onChunk: (chunk: Uint8Array) => void) => void} read calls `onChunk` with each chunk
 *   the server sends, from now on
 */

/**
 * The client's transport over `stream`: each message framed on the way out, the frames read
 * back into messages on the way in. A stream that isn't framed as LSP frames is `onError`'s.
 * @param {ByteStream} stream
 * @param {(error: FramingError) => void} onError
 * @returns {Transport}
 */
export function streamTransport(stream, onError) {
  /** @type {Set<(message: string) => void>} */
  const handlers = new Set();
  const reader = new MessageReader();
  stream.read((chunk) => {
    /** @type {string[]} */
    let messages;
    try {
      messages = reader.push(chunk);
    } catch (error) {
      onError(/** @type {FramingError} */ (error));
      return;
    }
    for (const message of messages) for (const handler of handlers) handler(message);
  });
  return {
    send: (message) => stream.write(frameMessage(message)),
    subscribe: (handler) => void handlers.add(handler),
    unsubscribe: (handler) => void handlers.delete(handler),
  };
}

/**
 * @typedef {object} LanguageServerOptions
 * @property {string} rootUri the folder the server reads the scripts' imports from
 * @property {Record<string, (client: LSPClient, params: any) => boolean>} [notifications] the
 *   server's notifications of its own (`kupcad/viewportReady`), by method
 */

/**
 * A client of the language server, with every feature the editor takes from it: connect it
 * (`client.connect(streamTransport(...))`), then give each editor `client.plugin(uri)`.
 * @param {LanguageServerOptions} options
 * @returns {LSPClient}
 */
export function languageServerClient({ rootUri, notifications = {} }) {
  return new LSPClient({
    rootUri,
    extensions: languageServerExtensions(),
    notificationHandlers: notifications,
  });
}
