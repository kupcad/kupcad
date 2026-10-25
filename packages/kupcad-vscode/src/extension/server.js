// The language server: `kupcad lsp` for the workspace's .kup documents, and what the extension
// asks of it beyond the language features: where its viewport socket is, the document the
// viewport shows, and the values a document's parameters take.

import * as vscode from 'vscode';
import { errorText } from '@kupcad/protocol';
import { LanguageClient, State, TransportKind } from 'vscode-languageclient/node';
import {
  isCompatible,
  PREVIEW_COMMAND,
  PROTOCOL_VERSION,
  SET_PARAMS_COMMAND,
  VIEWPORT_READY_NOTIFICATION,
} from '@kupcad/protocol';
import { FILE_SCHEME, LANGUAGE_ID } from './scripts.js';

/** @import { ParamValues, ViewportReady } from '@kupcad/protocol/types' */
/** @import { ServerLink } from '../types.js' */
/** @import { ScriptValues } from './values.js' */

/** The port the server's viewport socket tries first, which it reads from its environment. */
const VIEWPORT_PORT_ENV = 'KUPCAD_VIEWPORT_PORT';
const EXECUTE_COMMAND = 'workspace/executeCommand';
const KUP_FILES = '**/*.kup';

/**
 * @typedef {object} ServerOptions
 * @property {string} serverPath
 * @property {number} viewportPort the port its socket tries first
 * @property {ScriptValues} values what each script's parameters were given, which a server
 *   that starts is given again
 * @property {vscode.LogOutputChannel} log
 */

/** @implements {ServerLink} */
export class LanguageServer {
  /** @type {ServerOptions} */
  #options;
  /** @type {LanguageClient} */
  #client;
  /** The .kup files' watcher the client reports changes from, one a client. @type {vscode.FileSystemWatcher} */
  #watcher;
  /** @type {number | null} */
  #viewportPort = null;
  #viewport = new vscode.EventEmitter();
  /** The last start, restart or stop asked: each waits for the one before it. */
  #steps = Promise.resolve();
  #started = false;

  /** @param {ServerOptions} options */
  constructor(options) {
    this.#options = options;
    [this.#client, this.#watcher] = this.#clientOf();
  }

  /** The kupcad it runs. */
  get serverPath() {
    return this.#options.serverPath;
  }

  /** Whether the server started, and hasn't been stopped since or failed to start again. */
  get started() {
    return this.#started;
  }

  get viewportPort() {
    return this.#viewportPort;
  }

  /** @param {(port: number) => void} listener */
  onViewport(listener) {
    return this.#viewport.event(listener);
  }

  start() {
    return this.#serially(async () => {
      await this.#client.start();
      this.#started = true;
    });
  }

  /**
   * Runs kupcad as `change` says from now on (an update, a setting changed): the documents are
   * opened in it again, and the viewer follows its socket.
   * @param {Partial<Pick<ServerOptions, 'serverPath' | 'viewportPort'>>} change
   */
  restart(change) {
    return this.#serially(async () => {
      await this.#stopClient();
      this.#viewportPort = null;
      this.#options = { ...this.#options, ...change };
      [this.#client, this.#watcher] = this.#clientOf();
      await this.#client.start();
      this.#started = true;
    });
  }

  stop() {
    return this.#serially(async () => {
      await this.#stopClient();
      this.#viewport.dispose();
    });
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
   * Runs `step` once the steps asked before it are done, whether they succeeded or not.
   * @param {() => Promise<void>} step
   */
  #serially(step) {
    const run = this.#steps.then(step);
    this.#steps = run.catch(() => {});
    return run;
  }

  /** Stops the client, and its watcher: one that never started, or failed to, has no server to stop. */
  async #stopClient() {
    this.#started = false;
    this.#watcher.dispose();
    const client = this.#client;
    // Starting again after a crash: stopped once it has a connection to stop
    if (client.state === State.Starting) {
      await new Promise((settled) => {
        const watching = client.onDidChangeState(({ newState }) => {
          if (newState === State.Starting) return;
          watching.dispose();
          settled(undefined);
        });
      });
    }
    if (client.isRunning()) await client.stop();
  }

  /** @returns {[LanguageClient, vscode.FileSystemWatcher]} */
  #clientOf() {
    const { serverPath, viewportPort, log } = this.#options;
    const watcher = vscode.workspace.createFileSystemWatcher(KUP_FILES);
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
        documentSelector: [{ scheme: FILE_SCHEME, language: LANGUAGE_ID }],
        synchronize: { fileEvents: watcher },
        outputChannel: log,
      },
    );
    client.onNotification(VIEWPORT_READY_NOTIFICATION, (/** @type {ViewportReady} */ ready) =>
      this.#viewportReady(ready),
    );
    // Started, by us or by the client after a crash: the server knows no values yet
    client.onDidChangeState(({ newState }) => {
      if (newState === State.Running) this.#giveValues();
    });
    return [client, watcher];
  }

  /** Gives the server the values every script was given. */
  #giveValues() {
    for (const [uri, values] of this.#options.values.entries()) {
      this.setParams(uri, values).catch((error) =>
        this.#options.log.warn(
          `The values of ${uri} weren't given to the server: ${errorText(error)}`,
        ),
      );
    }
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
