import { forEachDiagnostic } from '@codemirror/lint';
import { EditorView } from '@codemirror/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Editor } from './editor.js';
import { completeKupcad } from './language.js';
import {
  FramingError,
  frameMessage,
  languageServerClient,
  MessageReader,
  streamTransport,
} from './language-server.js';

/** @import { ByteStream } from './language-server.js' */

const decoder = new TextDecoder();
/** A reader's `onError` where every stream is framed: one that isn't fails the test. */
const unframed = (/** @type {FramingError} */ error) => {
  throw error;
};
/** Two messages, one with a character of two UTF-8 bytes, as a server sends them back to back. */
const TWO = [
  '{"jsonrpc":"2.0","id":1,"result":{"label":"é"}}',
  '{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"hi"}}',
];

/** @param {Uint8Array[]} parts */
const concat = (parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
};

/** The editors a test made, disposed after it. @type {Editor[]} */
const made = [];
afterEach(() => {
  for (const editor of made.splice(0)) editor.dispose();
  document.body.replaceChildren();
});

/**
 * A stream to a server played by `answer`: each message the client sends is given to it, with
 * a function that sends one back.
 * @param {(message: any, send: (reply: object) => void) => void} answer
 * @returns {ByteStream}
 */
function serverStream(answer) {
  /** @type {((chunk: Uint8Array) => void) | null} */
  let toClient = null;
  const reader = new MessageReader(unframed);
  return {
    write(bytes) {
      for (const message of reader.push(bytes)) {
        answer(JSON.parse(message), (reply) =>
          queueMicrotask(() => toClient?.(frameMessage(JSON.stringify(reply)))),
        );
      }
    },
    read: (onChunk) => void (toClient = onChunk),
  };
}

describe('frames', () => {
  it("are a message's length in UTF-8 bytes, then the message", () => {
    expect(decoder.decode(frameMessage('{"a":"é"}'))).toBe('Content-Length: 10\r\n\r\n{"a":"é"}');
  });

  it('read back as the messages, cut wherever the chunks are, a character included', () => {
    const stream = concat(TWO.map(frameMessage));
    for (let cut = 1; cut < stream.length; cut++) {
      const reader = new MessageReader(unframed);
      const got = [...reader.push(stream.subarray(0, cut)), ...reader.push(stream.subarray(cut))];
      expect(got, `cut at ${cut}`).toEqual(TWO);
    }
    // Both in one chunk, and byte by byte
    expect(new MessageReader(unframed).push(stream)).toEqual(TWO);
    const bytewise = new MessageReader(unframed);
    expect([...stream].flatMap((byte) => bytewise.push(Uint8Array.of(byte)))).toEqual(TWO);
  });

  it('take a header with a type, and refuse one with no length or a stream with no header', () => {
    const typed = new TextEncoder().encode(
      'Content-Type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length: 2\r\n\r\n{}',
    );
    expect(new MessageReader(unframed).push(typed)).toEqual(['{}']);
    const onError = vi.fn();
    const lengthless = new TextEncoder().encode('Content-Type: x\r\n\r\n{}');
    expect(new MessageReader(onError).push(lengthless)).toEqual([]);
    const noise = new TextEncoder().encode('x'.repeat(2048));
    expect(new MessageReader(onError).push(noise)).toEqual([]);
    expect(onError.mock.calls.map(([error]) => error.message)).toEqual([
      'an LSP header with no length: Content-Type: x',
      'no LSP header in the first 1024 bytes',
    ]);
    expect(onError.mock.calls[0][0]).toBeInstanceOf(FramingError);
  });

  it('give the messages before a header that is no LSP header, and start over after it', () => {
    const onError = vi.fn();
    const reader = new MessageReader(onError);
    const lengthless = new TextEncoder().encode('Content-Type: x\r\n\r\n{}');
    expect(reader.push(concat([frameMessage('{"id":1}'), lengthless]))).toEqual(['{"id":1}']);
    expect(onError).toHaveBeenCalledTimes(1);
    expect(reader.push(frameMessage('{"id":2}'))).toEqual(['{"id":2}']);
  });
});

describe('streamTransport', () => {
  it('frames what it sends, and gives each handler the messages read, until unsubscribed', () => {
    /** @type {Uint8Array[]} */
    const written = [];
    /** @type {((chunk: Uint8Array) => void) | null} */
    let reading = null;
    /** @param {Uint8Array} chunk the server sends */
    const fromServer = (chunk) => reading?.(chunk);
    const onError = vi.fn();
    const transport = streamTransport(
      { write: (bytes) => written.push(bytes), read: (onChunk) => void (reading = onChunk) },
      onError,
    );
    transport.send('{"id":1}');
    expect(decoder.decode(written[0])).toBe('Content-Length: 8\r\n\r\n{"id":1}');
    const handler = vi.fn();
    transport.subscribe(handler);
    const stream = concat(TWO.map(frameMessage));
    fromServer(stream.subarray(0, 30));
    fromServer(stream.subarray(30));
    expect(handler.mock.calls.map(([message]) => message)).toEqual(TWO);
    transport.unsubscribe(handler);
    fromServer(frameMessage('{}'));
    expect(handler).toHaveBeenCalledTimes(2);
    // A stream that isn't LSP's is the host's to hear of
    fromServer(new TextEncoder().encode('Content-Type: x\r\n\r\n'));
    expect(onError).toHaveBeenCalledWith(expect.any(FramingError));
  });
});

describe('an editor with a language server', () => {
  it("opens its script on the server, marks the server's diagnostics, and leaves completion to it", async () => {
    const uri = 'file:///work/part.kup';
    /** @type {any[]} */
    const received = [];
    const stream = serverStream((message, send) => {
      received.push(message);
      if (message.method === 'initialize') {
        send({ jsonrpc: '2.0', id: message.id, result: { capabilities: { textDocumentSync: 2 } } });
      } else if (message.method === 'textDocument/didOpen') {
        const range = { start: { line: 0, character: 0 }, end: { line: 0, character: 1 } };
        send({
          jsonrpc: '2.0',
          method: 'textDocument/publishDiagnostics',
          params: { uri, diagnostics: [{ range, severity: 2, message: 'unused variable' }] },
        });
      }
    });
    const client = languageServerClient({ rootUri: 'file:///work' });
    client.connect(streamTransport(stream, () => {}));
    await client.initializing;

    const parent = document.createElement('div');
    document.body.append(parent);
    made.push(new Editor(parent, { value: 'w = 1\n', languageServer: { client, uri } }));
    const view = /** @type {EditorView} */ (EditorView.findFromDOM(parent));
    await vi.waitFor(() => {
      /** @type {string[]} */
      const marked = [];
      forEachDiagnostic(view.state, (d, from, to) => marked.push(`${d.message} ${from}-${to}`));
      expect(marked).toEqual(['unused variable 0-1']);
    });
    const opened = received.find((message) => message.method === 'textDocument/didOpen');
    expect(opened.params.textDocument).toMatchObject({
      uri,
      languageId: 'kupcad',
      text: 'w = 1\n',
    });
    // The server completes, knowing the script's names: the vocabulary is the editor's alone
    expect(view.state.languageDataAt('autocomplete', 0)).not.toContain(completeKupcad);
  });

  it("completes the language's words itself without one", () => {
    const parent = document.createElement('div');
    document.body.append(parent);
    made.push(new Editor(parent, { value: 'cu' }));
    const view = /** @type {EditorView} */ (EditorView.findFromDOM(parent));
    expect(view.state.languageDataAt('autocomplete', 0)).toContain(completeKupcad);
  });
});
