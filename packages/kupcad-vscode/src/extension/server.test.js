import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  PROTOCOL_VERSION,
  SET_PARAMS_COMMAND,
  VIEWPORT_READY_NOTIFICATION,
} from '@kupcad/protocol';
import { LanguageServer } from './server.js';
// The module Vitest gives the code as `vscode`
import { EventEmitter, fake, resetFake, window } from './testing/vscode.js';
import { ScriptValues } from '@kupcad/protocol';

/** The language clients made, as the stand-in below plays them. */
const clients = vi.hoisted(() => /** @type {any[]} */ ([]));
vi.mock('vscode-languageclient/node', () => {
  // The client's public states, as vscode-languageclient numbers them
  const State = { Stopped: 1, Running: 2, Starting: 3, StartFailed: 4 };
  class LanguageClient {
    /** @param {string} id @param {string} name @param {any} server @param {any} options */
    constructor(id, name, server, options) {
      this.server = server;
      this.options = options;
      this.state = State.Stopped;
      this.stops = 0;
      /** @type {Map<string, (params: any) => void>} */
      this.notifications = new Map();
      this.changes = new EventEmitter();
      /** @type {unknown[]} */
      this.requests = [];
      /** Whether its start fails. */
      this.failing = false;
      clients.push(this);
    }
    /** @param {number} newState */
    become(newState) {
      const oldState = this.state;
      this.state = newState;
      this.changes.fire({ oldState, newState });
    }
    async start() {
      this.become(State.Starting);
      await Promise.resolve();
      if (this.failing) {
        this.become(State.StartFailed);
        throw new Error('spawn ENOENT');
      }
      this.become(State.Running);
    }
    isRunning() {
      return this.state === State.Running;
    }
    async stop() {
      if (this.state !== State.Running)
        throw new Error(`Client is not running and can't be stopped`);
      this.stops += 1;
      this.become(State.Stopped);
    }
    /** @param {string} method @param {(params: any) => void} handler */
    onNotification(method, handler) {
      this.notifications.set(method, handler);
      return { dispose() {} };
    }
    /** @param {(event: any) => void} listener */
    onDidChangeState(listener) {
      return this.changes.event(listener);
    }
    /** @param {string} method @param {unknown} params */
    async sendRequest(method, params) {
      this.requests.push({ method, params });
    }
  }
  return { LanguageClient, State, TransportKind: { stdio: 0 } };
});

/** A server over the stand-in client, and the values store it gives again. */
function serverOf(serverPath = '/bin/kupcad') {
  const values = new ScriptValues();
  const server = new LanguageServer({
    serverPath,
    viewportPort: 9001,
    values,
    log: /** @type {any} */ (window.createOutputChannel()),
  });
  return { server, values };
}

beforeEach(() => {
  resetFake();
  clients.length = 0;
});

describe('LanguageServer', () => {
  it('runs kupcad lsp, its socket on the port given, for .kup files, watching them', async () => {
    const { server } = serverOf();
    await server.start();
    const [client] = clients;
    expect(client.server.run).toMatchObject({ command: '/bin/kupcad', args: ['lsp'] });
    expect(client.server.run.options.env.KUPCAD_VIEWPORT_PORT).toBe('9001');
    expect(client.options.documentSelector).toEqual([{ scheme: 'file', language: 'kupcad' }]);
    expect(client.options.synchronize.fileEvents).toBeDefined();
    expect(server.started).toBe(true);
  });

  it('follows the socket the server announces, and refuses one of another protocol, or no port', async () => {
    const { server } = serverOf();
    await server.start();
    /** @type {number[]} */
    const ports = [];
    server.onViewport((port) => ports.push(port));
    const announce = clients[0].notifications.get(VIEWPORT_READY_NOTIFICATION);
    for (const port of [0, 70_000, 1.5]) announce({ port, protocolVersion: PROTOCOL_VERSION });
    announce({ port: 9100, protocolVersion: PROTOCOL_VERSION + 1 });
    expect(ports).toEqual([]);
    expect(server.viewportPort).toBeNull();
    expect(fake.messages[0].text).toContain(`speaks protocol version ${PROTOCOL_VERSION + 1}`);
    announce({ port: 9100, protocolVersion: PROTOCOL_VERSION });
    expect(ports).toEqual([9100]);
    expect(server.viewportPort).toBe(9100);
  });

  it("gives a server that starts every script's values: its first start, and the client's own restart", async () => {
    const { server, values } = serverOf();
    values.set('file:///w/a.kup', { w: 3 });
    await server.start();
    const setParams = () =>
      clients[0].requests.filter(
        (/** @type {{ params: { command: string } }} */ request) =>
          request.params.command === SET_PARAMS_COMMAND,
      );
    expect(setParams()).toEqual([
      {
        method: 'workspace/executeCommand',
        params: {
          command: SET_PARAMS_COMMAND,
          arguments: [{ uri: 'file:///w/a.kup', values: { w: 3 } }],
        },
      },
    ]);
    // A crash, and the client starts the server again
    clients[0].become(1);
    clients[0].become(2);
    expect(setParams()).toHaveLength(2);
  });

  it('starts again on another kupcad: the old one stopped, its watcher disposed', async () => {
    const { server } = serverOf();
    await server.start();
    const watcher = clients[0].options.synchronize.fileEvents;
    const disposed = vi.spyOn(watcher, 'dispose');
    await server.restart({ serverPath: '/bin/kupcad-0.1.3' });
    expect(clients[0].stops).toBe(1);
    expect(disposed).toHaveBeenCalledOnce();
    expect(clients[1].server.run.command).toBe('/bin/kupcad-0.1.3');
    expect(clients[1].server.run.options.env.KUPCAD_VIEWPORT_PORT).toBe('9001');
    expect(server.serverPath).toBe('/bin/kupcad-0.1.3');
    expect(clients[1].isRunning()).toBe(true);
  });

  it('starts again from a client that failed to start, which has nothing to stop', async () => {
    const { server } = serverOf('/missing/kupcad');
    clients[0].failing = true;
    await expect(server.start()).rejects.toThrow('spawn ENOENT');
    expect(server.started).toBe(false);
    await server.restart({ serverPath: '/bin/kupcad' });
    expect(server.started).toBe(true);
    expect(clients[1].isRunning()).toBe(true);
  });

  it('runs restarts asked together one after another: one client runs at the end', async () => {
    const { server } = serverOf();
    await server.start();
    await Promise.all([
      server.restart({ serverPath: '/bin/a' }),
      server.restart({ serverPath: '/bin/b' }),
    ]);
    expect(clients.filter((client) => client.isRunning())).toHaveLength(1);
    expect(server.serverPath).toBe('/bin/b');
  });

  it('stops a client that was starting again only once it runs', async () => {
    const { server } = serverOf();
    await server.start();
    const client = clients[0];
    client.become(3); // the client starting the server again after a crash
    const stopping = server.stop();
    await Promise.resolve();
    expect(client.stops).toBe(0);
    client.become(2);
    await stopping;
    expect(client.stops).toBe(1);
  });
});
