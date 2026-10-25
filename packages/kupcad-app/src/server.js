// The language server the app runs: the bundled kupcad's (`kupcad lsp`), which the native side
// starts for the page and holds (src-tauri/src/server.rs), its stdio framed for the editor's
// client (@kupcad/editor's streamTransport). Its viewport socket admits this page by its origin
// (`--viewport-origin`). A server that ends is started again, a little later each time, and the
// client reconnects to it, opening the scripts the editors hold on it again.

import { languageServerClient, streamTransport } from '@kupcad/editor';
import {
  isCompatible,
  PREVIEW_COMMAND,
  PROTOCOL_VERSION,
  SET_PARAMS_COMMAND,
  VIEWPORT_READY_NOTIFICATION,
} from '@kupcad/protocol';
import { Channel, invoke } from '@tauri-apps/api/core';

/** @import { LSPClient } from '@kupcad/editor' */
/** @import { ParamValues, ViewportReady } from '@kupcad/protocol/types' */

/** The first wait before starting a server that ended again, and the longest, in milliseconds. */
export const RESTART_MS = { first: 500, most: 10_000 };

/**
 * A server process, as the app talks to it.
 * @typedef {object} ServerProcess
 * @property {(bytes: Uint8Array) => Promise<void>} write to its stdin
 * @property {() => Promise<void>} kill
 */

/**
 * What a server process tells, as it runs.
 * @typedef {object} ProcessEvents
 * @property {(chunk: Uint8Array) => void} stdout
 * @property {(text: string) => void} stderr its log
 * @property {(code: number | null) => void} exit
 */

/**
 * Starts a server for the page at `origin`: `kupcad lsp --stdio --viewport-origin <origin>`.
 * @typedef {(origin: string, on: ProcessEvents) => Promise<ServerProcess>} Spawn
 */

/**
 * What the server tells the app.
 * @typedef {object} ServerEvents
 * @property {(url: string | null) => void} viewport its viewport socket's URL, once it is up;
 *   null while there is none the app can read
 * @property {(running: boolean) => void} state it started, or it ended
 * @property {(text: string) => void} log
 */

/**
 * @typedef {object} ServerOptions
 * @property {string} rootUri the folder the server reads the scripts' imports from
 * @property {string} origin this page's, which the server's viewport socket admits
 * @property {ServerEvents} on
 * @property {Record<string, (client: LSPClient, params: any) => boolean>} [notifications] the
 *   server's notifications the app hears itself, by method, besides `kupcad/viewportReady`
 * @property {Spawn} [spawn] the process, by default the native side's
 * @property {typeof setTimeout} [setTimeout]
 */

/**
 * What the native side tells of the server it runs (src-tauri/src/server.rs's ServerEvent).
 * @typedef {{ event: 'stdout', data: number[] } | { event: 'stderr', data: string } | { event: 'exit', data: number | null }} ServerEvent
 */

/** @type {Spawn} */
async function sidecar(origin, on) {
  /** @type {Channel<ServerEvent>} */
  const events = new Channel((message) => {
    if (message.event === 'stdout') on.stdout(Uint8Array.from(message.data));
    else if (message.event === 'stderr') on.stderr(message.data);
    else on.exit(message.data);
  });
  await invoke('start_server', { origin, onEvent: events });
  const decoder = new TextDecoder();
  return {
    // The frames are text: their headers and their JSON, UTF-8
    write: (bytes) => invoke('write_server', { text: decoder.decode(bytes) }),
    kill: () => invoke('stop_server'),
  };
}

export class LanguageServer {
  /** The editors' client of the server, the same across restarts. @type {LSPClient} */
  client;
  /** @type {string} */
  #origin;
  /** @type {ServerEvents} */
  #on;
  /** @type {Spawn} */
  #spawn;
  /** @type {typeof setTimeout} */
  #later;
  /** @type {ServerProcess | null} */
  #process = null;
  #wait = RESTART_MS.first;
  #stopped = false;
  /** @type {ReturnType<typeof setTimeout> | undefined} */
  #restart;

  /** @param {ServerOptions} options */
  constructor({
    rootUri,
    origin,
    on,
    notifications = {},
    spawn = sidecar,
    setTimeout = globalThis.setTimeout,
  }) {
    this.#origin = origin;
    this.#on = on;
    this.#spawn = spawn;
    this.#later = setTimeout;
    this.client = languageServerClient({
      rootUri,
      notifications: {
        ...notifications,
        [VIEWPORT_READY_NOTIFICATION]: (_client, /** @type {ViewportReady} */ ready) => {
          this.#viewportReady(ready);
          return true;
        },
      },
    });
  }

  /**
   * Starts the server, and connects the client to it; it rejects if the server doesn't start, or
   * ends before it is up.
   */
  async start() {
    this.#stopped = false;
    /** @type {((chunk: Uint8Array) => void) | null} */
    let reading = null;
    /** @type {ServerProcess | null} */
    let started = null;
    /** @type {((code: number | null) => void) | null} */
    let endedEarly = null;
    /** @type {Promise<never>} */
    const ends = new Promise((_resolve, reject) => {
      endedEarly = (code) => reject(new Error(`kupcad lsp ended (code ${code}) before it was up`));
    });
    // Once it is up, its end is #ended's alone
    ends.catch(() => {});
    started = await this.#spawn(this.#origin, {
      stdout: (chunk) => reading?.(chunk),
      stderr: (text) => this.#on.log(text),
      exit: (code) => {
        endedEarly?.(code);
        this.#ended(started, code);
      },
    });
    const process = started;
    this.#process = process;
    const stream = {
      write: (/** @type {Uint8Array} */ bytes) =>
        void process.write(bytes).catch((error) => this.#on.log(`kupcad: ${error}`)),
      read: (/** @type {(chunk: Uint8Array) => void} */ onChunk) => void (reading = onChunk),
    };
    this.client.connect(streamTransport(stream, (error) => this.#on.log(error.message)));
    this.#on.state(true);
    // The client's initialization never settles for a process that ends first
    await Promise.race([this.client.initializing, ends]);
    this.#wait = RESTART_MS.first;
  }

  /**
   * Shows the document at `uri` in the viewport, and has its frame sent.
   * @param {string} uri
   */
  preview(uri) {
    return this.#command(PREVIEW_COMMAND, { uri });
  }

  /**
   * Runs the document at `uri` with `values` from now on.
   * @param {string} uri
   * @param {ParamValues} values
   */
  setParams(uri, values) {
    return this.#command(SET_PARAMS_COMMAND, { uri, values });
  }

  /** Stops the server for good. */
  async stop() {
    this.#stopped = true;
    clearTimeout(this.#restart);
    const process = this.#process;
    this.#process = null;
    if (process) this.client.disconnect();
    await process?.kill();
  }

  /**
   * @param {string} command
   * @param {unknown} argument
   */
  #command(command, argument) {
    // The client keeps a transport it was disconnected from: a request would wait on a process
    // that is gone until it timed out
    if (!this.#process) return Promise.reject(new Error("kupcad lsp isn't running"));
    this.client.sync();
    return this.client.request('workspace/executeCommand', { command, arguments: [argument] });
  }

  /** @param {ViewportReady} ready */
  #viewportReady({ port, protocolVersion }) {
    if (!isCompatible(protocolVersion)) {
      this.#on.log(
        `kupcad speaks protocol ${protocolVersion}, and this app reads ${PROTOCOL_VERSION}: the model can't be shown`,
      );
      this.#on.viewport(null);
      return;
    }
    this.#on.viewport(`ws://127.0.0.1:${port}`);
  }

  /**
   * @param {ServerProcess | null} process the one that ended
   * @param {number | null} code
   */
  #ended(process, code) {
    // A process stopped, then replaced, may still say so
    if (process !== this.#process) return;
    this.#process = null;
    this.client.disconnect();
    this.#on.viewport(null);
    this.#on.state(false);
    if (this.#stopped) return;
    this.#on.log(`kupcad lsp ended (code ${code}); starting it again`);
    this.#startLater();
  }

  /** Starts the server again after the wait, which doubles each time, and again if it fails. */
  #startLater() {
    this.#restart = this.#later(() => {
      this.#restart = undefined;
      this.start().catch((error) => {
        this.#on.log(`kupcad lsp didn't start: ${error}`);
        // One that ended before it was up is started again by #ended; one never started isn't
        if (!this.#stopped && this.#restart === undefined) this.#startLater();
      });
    }, this.#wait);
    this.#wait = Math.min(this.#wait * 2, RESTART_MS.most);
  }
}
