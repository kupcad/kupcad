// The editor's language server (@codemirror/lsp-client): `kupcad lsp` over a stream of bytes, a
// host's child process (the desktop app's), its messages framed as LSP frames them on stdio, a
// `Content-Length` header before each JSON body. The client gives the editor the server's
// diagnostics, completion, hover, signature help, formatting, renaming and definitions.

import { LSPClient, languageServerExtensions } from '@codemirror/lsp-client';
import { sanitizeHTML } from './sanitize.js';

/** @import { LSPClientExtension, Transport } from '@codemirror/lsp-client' */

/** The server asks for a token for the progress of its long work (lsp_progress.zig). */
const CREATE_PROGRESS = 'window/workDoneProgress/create';
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

/**
 * The messages in a stream of LSP frames, as its chunks arrive, cut wherever they are. A stream
 * that isn't framed so (a header with no length, or none where one should be) is `onError`'s:
 * the messages before the fault are read, what follows it is dropped, and reading starts over
 * with the next chunk.
 */
export class MessageReader {
  #pending = new Uint8Array(0);
  /** @type {(error: FramingError) => void} */
  #onError;

  /** @param {(error: FramingError) => void} onError */
  constructor(onError) {
    this.#onError = onError;
  }

  /**
   * The messages `chunk` completes, in order; what it starts waits for the next.
   * @param {Uint8Array} chunk
   * @returns {string[]}
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
          return this.#unframed(messages, `no LSP header in the first ${MAX_HEADER_BYTES} bytes`);
        }
        break;
      }
      const header = new TextDecoder().decode(joined.subarray(at, headerEnd));
      const length = CONTENT_LENGTH.exec(header)?.[1];
      if (length === undefined) {
        return this.#unframed(messages, `an LSP header with no length: ${header}`);
      }
      const bodyStart = headerEnd + HEADER_END.length;
      const bodyEnd = bodyStart + Number(length);
      if (bodyEnd > joined.length) break;
      messages.push(new TextDecoder().decode(joined.subarray(bodyStart, bodyEnd)));
      at = bodyEnd;
    }
    this.#pending = joined.slice(at);
    return messages;
  }

  /**
   * `messages`, read before a fault in the framing: what follows it is dropped.
   * @param {string[]} messages
   * @param {string} why
   */
  #unframed(messages, why) {
    this.#pending = new Uint8Array(0);
    this.#onError(new FramingError(why));
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
 * The server's `window/workDoneProgress/create` is answered here, and not passed on: the
 * client (@codemirror/lsp-client 6.3.0) answers every request of the server's with
 * MethodNotFound and takes no handlers for them, and a token refused may not be used. Remove
 * this once it takes them: the answer belongs with workDoneProgress's handlers.
 * @param {ByteStream} stream
 * @param {(error: FramingError) => void} onError
 * @returns {Transport}
 */
export function streamTransport(stream, onError) {
  /** @type {Set<(message: string) => void>} */
  const handlers = new Set();
  const reader = new MessageReader(onError);
  /** @param {string} message */
  const send = (message) => stream.write(frameMessage(message));
  stream.read((chunk) => {
    for (const message of reader.push(chunk)) {
      const id = progressRequestId(message);
      if (id !== undefined) send(JSON.stringify({ jsonrpc: '2.0', id, result: null }));
      else for (const handler of handlers) handler(message);
    }
  });
  return {
    send,
    subscribe: (handler) => void handlers.add(handler),
    unsubscribe: (handler) => void handlers.delete(handler),
  };
}

/**
 * The id of `message` if it is the server's `window/workDoneProgress/create`.
 * @param {string} message
 * @returns {string | number | undefined}
 */
function progressRequestId(message) {
  // Read whole only when it may be one: the rest are the client's to read
  if (!message.includes(CREATE_PROGRESS)) return undefined;
  const value = JSON.parse(message);
  return value.method === CREATE_PROGRESS && 'id' in value ? value.id : undefined;
}

/**
 * The server's long work as it tells it (`$/progress`), for a host to show: an extension of the
 * client's that says it takes it (`window.workDoneProgress`). `onprogress` is given the title
 * of the work under way (`Building part.kup`), the newest where several are, or null once all
 * have ended; `clear()` drops them all, for a server that ended or was disconnected, whose
 * ends won't come.
 * @param {{ onprogress: (title: string | null) => void }} options
 */
export function workDoneProgress({ onprogress }) {
  /** The work begun and not ended, by token, the newest last. @type {Map<string | number, string>} */
  const open = new Map();
  const told = () => onprogress([...open.values()].at(-1) ?? null);
  return {
    clientCapabilities: { window: { workDoneProgress: true } },
    notificationHandlers: {
      /**
       * @param {LSPClient} _client
       * @param {{ token: string | number, value: { kind: string, title?: string } }} params
       */
      '$/progress': (_client, { token, value }) => {
        if (value.kind === 'begin') {
          // Begun again, it is the newest
          open.delete(token);
          open.set(token, value.title ?? '');
          told();
        } else if (value.kind === 'end' && open.delete(token)) told();
        return true;
      },
    },
    clear() {
      if (open.size === 0) return;
      open.clear();
      told();
    },
  };
}

/** @typedef {ReturnType<typeof workDoneProgress>} WorkDoneProgress */

/**
 * @typedef {object} LanguageServerOptions
 * @property {string} rootUri the folder the server reads the scripts' imports from
 * @property {Record<string, (client: LSPClient, params: any) => boolean>} [notifications] the
 *   server's notifications of its own (`kupcad/viewportReady`), by method
 * @property {LSPClientExtension[]} [extensions] the host's own, besides the editor's
 *   (workDoneProgress)
 */

/**
 * A client of the language server, with every feature the editor takes from it: connect it
 * (`client.connect(streamTransport(...))`), then give each editor `client.plugin(uri)`. The
 * server's documentation is shown with the HTML Markdown writes alone (`sanitizeHTML`).
 * @param {LanguageServerOptions} options
 * @returns {LSPClient}
 */
export function languageServerClient({ rootUri, notifications = {}, extensions = [] }) {
  return new LSPClient({
    rootUri,
    extensions: [...languageServerExtensions(), ...extensions],
    notificationHandlers: notifications,
    sanitizeHTML,
  });
}
