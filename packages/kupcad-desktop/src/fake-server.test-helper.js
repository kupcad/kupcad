// A stand-in for the bundled kupcad's language server, for the tests: started for a page's
// origin as the native side starts it, speaking LSP over the framed stdio.

import { frameMessage, MessageReader } from '@kupcad/editor';
import { PROTOCOL_VERSION } from '@kupcad/protocol';

/** @import { ProcessEvents } from './server.js' */

/**
 * A stand-in for `kupcad lsp`, started as the native side starts it: it answers `initialize`, says
 * its viewport is up at `port` (none for null), and answers every other request with null; with `answers`
 * false, it answers nothing (`answers` may be set on what it returns, for the processes started
 * after). Each process it starts is kept, with the messages it was sent; one killed ends, as the
 * native side says a process a signal ended did (code null).
 */
export function fakeServer({
  port = /** @type {number | null} */ (9001),
  protocolVersion = PROTOCOL_VERSION,
  answers = true,
} = {}) {
  /** @type {{ origin: string, memoryLimit: number, on: ProcessEvents, received: any[], killed: boolean }[]} */
  const processes = [];
  const fake = { spawn, processes, answers };
  /**
   * @param {string} origin
   * @param {number} memoryLimit
   * @param {ProcessEvents} on
   */
  async function spawn(origin, memoryLimit, on) {
    const answering = fake.answers;
    const reader = new MessageReader((error) => {
      throw error;
    });
    const process = { origin, memoryLimit, on, received: /** @type {any[]} */ ([]), killed: false };
    processes.push(process);
    /** @param {object} message */
    const send = (message) =>
      queueMicrotask(() => on.stdout(frameMessage(JSON.stringify(message))));
    return {
      write: async (/** @type {Uint8Array} */ bytes) => {
        for (const text of reader.push(bytes)) {
          const message = JSON.parse(text);
          process.received.push(message);
          if (!answering) continue;
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
        if (process.killed) return;
        process.killed = true;
        queueMicrotask(() => on.exit(null));
      },
    };
  }
  return fake;
}
