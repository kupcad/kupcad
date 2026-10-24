// The language server's viewport socket, as the page reads it: each binary message a preview
// frame (@kupcad/protocol's readFrame). A socket that closes (the server restarted, or wasn't
// up yet) is opened again, a little later each time.

import { readFrame } from '@kupcad/protocol';

/** @import { Preview } from '@kupcad/protocol/types' */

/** The first wait before opening a closed socket again, and the longest, in milliseconds. */
export const RETRY_MS = { first: 250, most: 5000 };

/**
 * @typedef {object} ViewportEvents
 * @property {(preview: Preview) => void} frame a frame arrived
 * @property {() => void} open the socket opened: the host asks the server for a frame
 * @property {(open: boolean) => void} state it opened or closed
 * @property {(message: string) => void} problem a frame this page can't read
 */

/**
 * Connects to the socket at `url`, until the returned function is called.
 * @param {string} url
 * @param {ViewportEvents} on
 * @param {{ WebSocket?: typeof WebSocket, setTimeout?: typeof setTimeout }} [platform]
 * @returns {() => void} closes it for good
 */
export function connectViewport(url, on, platform = {}) {
  const Socket = platform.WebSocket ?? globalThis.WebSocket;
  const later = platform.setTimeout ?? globalThis.setTimeout;
  let wait = RETRY_MS.first;
  let closed = false;
  /** @type {WebSocket | null} */
  let socket = null;

  const open = () => {
    if (closed) return;
    socket = new Socket(url);
    socket.binaryType = 'arraybuffer';
    socket.addEventListener('open', () => {
      wait = RETRY_MS.first;
      on.state(true);
      on.open();
    });
    socket.addEventListener('message', ({ data }) => {
      if (!(data instanceof ArrayBuffer)) return;
      try {
        on.frame(readFrame(data));
      } catch (error) {
        on.problem(error instanceof Error ? error.message : String(error));
      }
    });
    socket.addEventListener('close', () => {
      on.state(false);
      if (closed) return;
      later(open, wait);
      wait = Math.min(wait * 2, RETRY_MS.most);
    });
  };
  open();
  return () => {
    closed = true;
    socket?.close();
  };
}
