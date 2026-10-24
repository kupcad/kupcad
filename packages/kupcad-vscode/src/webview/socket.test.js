import { PROTOCOL_VERSION } from '@kupcad/protocol';
import { expect, it } from 'vitest';
import { connectViewport, RETRY_MS } from './socket.js';

/** The sockets opened, each an event target the test drives as the server would. */
function sockets() {
  /** @type {FakeSocket[]} */
  const opened = [];
  class FakeSocket extends EventTarget {
    binaryType = 'blob';
    closed = false;
    /** @param {string} url */
    constructor(url) {
      super();
      this.url = url;
      opened.push(this);
    }
    close() {
      this.closed = true;
    }
    /** @param {unknown} data */
    send(data) {
      this.dispatchEvent(Object.assign(new Event('message'), { data }));
    }
  }
  return { opened, WebSocket: /** @type {any} */ (FakeSocket) };
}

/** A frame of no model, as the server writes it: its header's length, then the header. */
function emptyFrame() {
  const header = new TextEncoder().encode(
    JSON.stringify({
      protocolVersion: PROTOCOL_VERSION,
      document: 'file:///w/a.kup',
      kind: 'none',
      parts: [],
      warnings: [],
      params: { schema: { meta: {}, parameters: [] }, values: {} },
      error: null,
      timing: { runMs: 1, renderMs: 0 },
    }),
  );
  const bytes = new Uint8Array(4 + header.byteLength);
  new DataView(bytes.buffer).setUint32(0, header.byteLength, true);
  bytes.set(header, 4);
  return bytes.buffer;
}

/** What the page was told. */
function listener() {
  /** @type {unknown[][]} */
  const heard = [];
  return {
    heard,
    on: {
      frame: (/** @type {any} */ preview) => heard.push(['frame', preview.header.document]),
      open: () => heard.push(['open']),
      state: (/** @type {boolean} */ open) => heard.push(['state', open]),
      problem: (/** @type {string} */ message) => heard.push(['problem', message]),
    },
  };
}

it("reads each binary message as a frame, and says what it can't read", () => {
  const { opened, WebSocket } = sockets();
  const { heard, on } = listener();
  connectViewport('ws://127.0.0.1:9001', on, { WebSocket });
  const socket = opened[0];
  expect(socket.binaryType).toBe('arraybuffer');
  socket.dispatchEvent(new Event('open'));
  socket.send(emptyFrame());
  socket.send('a text message');
  socket.send(new Uint8Array([9, 0, 0, 0, 123]).buffer);
  expect(heard.slice(0, 3)).toEqual([['state', true], ['open'], ['frame', 'file:///w/a.kup']]);
  expect(heard[3][0]).toBe('problem');
  expect(heard).toHaveLength(4);
});

it('opens a closed socket again, waiting longer each time up to a most, and not once closed for good', () => {
  const { opened, WebSocket } = sockets();
  const { on } = listener();
  /** @type {number[]} */
  const waits = [];
  /** @type {(() => void)[]} */
  const due = [];
  const setTimeout = /** @type {any} */ (
    (/** @type {() => void} */ run, /** @type {number} */ ms) => {
      waits.push(ms);
      due.push(run);
    }
  );
  const close = connectViewport('ws://127.0.0.1:9001', on, { WebSocket, setTimeout });
  for (let i = 0; i < 6; i++) {
    opened[i].dispatchEvent(new Event('close'));
    /** @type {() => void} */ (due.shift())();
  }
  expect(waits).toEqual([250, 500, 1000, 2000, 4000, RETRY_MS.most]);
  // Opened, the next wait starts over
  opened[6].dispatchEvent(new Event('open'));
  opened[6].dispatchEvent(new Event('close'));
  expect(waits.at(-1)).toBe(RETRY_MS.first);
  close();
  expect(opened[6].closed).toBe(true);
  /** @type {() => void} */ (due.shift())();
  expect(opened).toHaveLength(7);
});
