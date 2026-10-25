// A stand-in for the bundled kupcad's language server, for the tests: started for a page's
// origin as the native side starts it, speaking LSP over the framed stdio.

import { frameMessage, MessageReader } from '@kupcad/editor';
import { PROTOCOL_VERSION } from '@kupcad/protocol';

/** @import { ProcessEvents } from './server.js' */

/**
 * A stand-in for `kupcad lsp`, started as the native side starts it: it answers `initialize`, says
 * its viewport is up at `port` (none for null), and answers every other request with null; with `answers`
 * false, it answers nothing. Each process it starts is kept, with the messages it was sent.
 */
export function fakeServer({
  port = /** @type {number | null} */ (9001),
  protocolVersion = PROTOCOL_VERSION,
  answers = true,
} = {}) {
  /** @type {{ origin: string, on: ProcessEvents, received: any[], killed: boolean }[]} */
  const processes = [];
  /**
   * @param {string} origin
   * @param {ProcessEvents} on
   */
  const spawn = async (origin, on) => {
    const reader = new MessageReader();
    const process = { origin, on, received: /** @type {any[]} */ ([]), killed: false };
    processes.push(process);
    /** @param {object} message */
    const send = (message) =>
      queueMicrotask(() => on.stdout(frameMessage(JSON.stringify(message))));
    return {
      write: async (/** @type {Uint8Array} */ bytes) => {
        for (const text of reader.push(bytes)) {
          const message = JSON.parse(text);
          process.received.push(message);
          if (!answers) continue;
          if (message.method === 'initialize') {
            send({ jsonrpc: '2.0', id: message.id, result: { capabilities: {} } });
            if (port !== null) {
              send({
                jsonrpc: '2.0',
                method: 'kupcad/viewportReady',
                params: { port, protocolVersion },
              });
            }
          } else if (message.id !== undefined) {
            send({ jsonrpc: '2.0', id: message.id, result: null });
          }
        }
      },
      kill: async () => {
        process.killed = true;
      },
    };
  };
  return { spawn, processes };
}
