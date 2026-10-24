// The language server: `kupcad lsp` for the workspace's .kup documents, and what the extension
// asks of it beyond the language features: where its viewport socket is, the document the
// viewport shows, and the values a document's parameters take.

import * as vscode from 'vscode';
import { LanguageClient, TransportKind } from 'vscode-languageclient/node';
import {
  isCompatible,
  PREVIEW_COMMAND,
  PROTOCOL_VERSION,
  SET_PARAMS_COMMAND,
  VIEWPORT_READY_NOTIFICATION,
} from '@kupcad/protocol';

/** @import { ParamValues, ViewportReady } from '@kupcad/protocol/types' */
/** @import { ServerLink } from '../types.js' */

/** The port the server's viewport socket tries first, which it reads from its environment. */
const VIEWPORT_PORT_ENV = 'KUPCAD_VIEWPORT_PORT';
const EXECUTE_COMMAND = 'workspace/executeCommand';

/**
 * @typedef {object} ServerOptions
 * @property {string} serverPath
 * @property {number} viewportPort the port its socket tries first
 * @property {vscode.LogOutputChannel} log
 */

/** @implements {ServerLink} */
export class LanguageServer {
  /** @type {ServerOptions} */
  #options;
  /** @type {LanguageClient} */
  #client;
  /** @type {number | null} */
  #viewportPort = null;
  #viewport = new vscode.EventEmitter();

  /** @param {ServerOptions} options */
  constructor(options) {
    this.#options = options;
    this.#client = this.#clientOf(options.serverPath);
  }

  /**
   * Runs the kupcad at `serverPath` from now on (an update): the documents are opened in it
   * again, and the viewer follows its socket.
   * @param {string} serverPath
   */
  async restart(serverPath) {
    await this.#client.stop();
    this.#viewportPort = null;
    this.#options = { ...this.#options, serverPath };
    this.#client = this.#clientOf(serverPath);
    await this.#client.start();
  }

  /** @param {string} serverPath */
  #clientOf(serverPath) {
    const { viewportPort, log } = this.#options;
    const run = {
      command: serverPath,
      args: ['lsp'],
      transport: TransportKind.stdio,
      options: { env: { ...process.env, [VIEWPORT_PORT_ENV]: String(viewportPort) } },
    };
    const client = new LanguageClient(
      'kupcad',
      'KupCAD Language Server',
      { run, debug: run },
      {
        documentSelector: [{ scheme: 'file', language: 'kupcad' }],
        synchronize: { fileEvents: vscode.workspace.createFileSystemWatcher('**/*.kup') },
        outputChannel: log,
      },
    );
    client.onNotification(VIEWPORT_READY_NOTIFICATION, (/** @type {ViewportReady} */ ready) =>
      this.#viewportReady(ready),
    );
    return client;
  }

  /** The kupcad running now. */
  get serverPath() {
    return this.#options.serverPath;
  }

  get viewportPort() {
    return this.#viewportPort;
  }

  /** @param {(port: number) => void} listener */
  onViewport(listener) {
    return this.#viewport.event(listener);
  }

  start() {
    return this.#client.start();
  }

  stop() {
    this.#viewport.dispose();
    return this.#client.stop();
  }

  /** @param {string} uri */
  async preview(uri) {
    await this.#execute(PREVIEW_COMMAND, { uri });
  }

  /**
   * @param {string} uri
   * @param {ParamValues} values
   */
  async setParams(uri, values) {
    await this.#execute(SET_PARAMS_COMMAND, { uri, values });
  }

  /**
   * @param {string} command
   * @param {unknown} argument
   */
  #execute(command, argument) {
    return this.#client.sendRequest(EXECUTE_COMMAND, { command, arguments: [argument] });
  }

  /**
   * The server's socket is up, a restarted server's too: a port the viewer can connect to, if
   * the server speaks this extension's protocol.
   * @param {ViewportReady} ready
   */
  #viewportReady({ port, protocolVersion }) {
    if (!Number.isInteger(port) || port <= 0 || port > 65535) return;
    if (!isCompatible(protocolVersion)) {
      void vscode.window.showErrorMessage(
        `The kupcad language server speaks protocol version ${protocolVersion}, and this extension version ${PROTOCOL_VERSION}: the viewer can't show its models. Update the one that is older.`,
      );
      return;
    }
    this.#viewportPort = port;
    this.#viewport.fire(port);
  }
}
