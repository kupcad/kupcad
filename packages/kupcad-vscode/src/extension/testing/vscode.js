// A stand-in for VS Code's API, as far as the extension uses it, for its tests in Node (Vitest
// resolves `vscode` to this). What the extension does to it is kept in `fake`, for the tests to
// read, and what a user would do is a function the tests call (`fake.showEditor`,
// `webview.receive`). `resetFake()` starts each test afresh.

import * as path from 'node:path';

export class EventEmitter {
  /** @type {((value: any) => void)[]} */
  #listeners = [];

  /** @param {(value: any) => void} listener */
  event = (listener) => {
    this.#listeners.push(listener);
    return { dispose: () => (this.#listeners = this.#listeners.filter((l) => l !== listener)) };
  };

  /** @param {any} [value] */
  fire(value) {
    // A listener disposed meanwhile makes a new list: this one goes on
    for (const listener of this.#listeners) listener(value);
  }

  dispose() {
    this.#listeners = [];
  }
}

export class Uri {
  /**
   * @param {string} scheme
   * @param {string} uriPath
   */
  constructor(scheme, uriPath) {
    this.scheme = scheme;
    this.path = uriPath;
  }

  /** @param {string} file */
  static file(file) {
    return new Uri('file', path.posix.resolve('/', file));
  }

  /** @param {string} text */
  static parse(text) {
    const url = new URL(text);
    return new Uri(url.protocol.slice(0, -1), decodeURIComponent(url.pathname));
  }

  /**
   * @param {Uri} base
   * @param {...string} parts
   */
  static joinPath(base, ...parts) {
    return new Uri(base.scheme, path.posix.join(base.path, ...parts));
  }

  get fsPath() {
    return this.path;
  }

  toString() {
    return `${this.scheme}://${this.path}`;
  }
}

export const ViewColumn = { One: 1, Beside: -2 };
export const ExtensionMode = { Production: 1, Development: 2, Test: 3 };

/**
 * A document open in an editor.
 * @param {string} file
 * @param {string} [languageId]
 */
export function documentAt(file, languageId = 'kupcad') {
  return {
    uri: Uri.file(file),
    fileName: file,
    languageId,
    isDirty: false,
    save: async () => true,
  };
}

class Webview {
  html = '';
  cspSource = 'vscode-resource:';
  /** What the extension posted the page. @type {unknown[]} */
  posted = [];
  #received = new EventEmitter();
  onDidReceiveMessage = this.#received.event;

  /** @param {unknown} message */
  postMessage(message) {
    this.posted.push(message);
    return Promise.resolve(true);
  }

  /** @param {Uri} uri */
  asWebviewUri(uri) {
    return new Uri('https', `/webview${uri.path}`);
  }

  /**
   * The page sends `message`.
   * @param {unknown} message
   */
  receive(message) {
    this.#received.fire(message);
  }
}

class WebviewPanel {
  webview = new Webview();
  revealed = 0;
  #disposed = new EventEmitter();
  onDidDispose = this.#disposed.event;

  /**
   * @param {string} viewType
   * @param {string} title
   * @param {object} options
   */
  constructor(viewType, title, options) {
    this.viewType = viewType;
    this.title = title;
    this.options = options;
  }

  reveal() {
    this.revealed += 1;
  }

  dispose() {
    this.#disposed.fire();
  }
}

/** A log channel that keeps its lines. */
function logChannel() {
  /** @type {string[]} */
  const lines = [];
  /** @param {string} level */
  const at = (level) => (/** @type {string} */ line) => lines.push(`${level}: ${line}`);
  return {
    lines,
    trace: at('trace'),
    debug: at('debug'),
    info: at('info'),
    warn: at('warn'),
    error: at('error'),
    appendLine: at('info'),
    show() {},
    dispose() {},
  };
}

/** What the extension did, and what the user does: read and set by the tests. */
export const fake = {
  /** @type {WebviewPanel[]} */
  panels: [],
  /** @type {Map<string, (...args: any[]) => any>} */
  commands: new Map(),
  /** @type {{ level: string, text: string }[]} */
  messages: [],
  /** @type {Map<string, Uint8Array>} the files written, by path */
  written: new Map(),
  /** @type {Record<string, unknown>} the settings, by their full name */
  settings: {},
  /** What the save dialog answers: a file, or nothing (cancelled). @type {Uri | undefined} */
  saveAnswer: undefined,
  /** @type {ReturnType<typeof documentAt> | undefined} */
  activeDocument: undefined,
  activeEditorChanged: new EventEmitter(),
  /** @type {ReturnType<typeof logChannel>[]} */
  logs: [],

  /**
   * The editor shows `document`.
   * @param {ReturnType<typeof documentAt>} document
   */
  showEditor(document) {
    this.activeDocument = document;
    this.activeEditorChanged.fire({ document });
  },
};

export function resetFake() {
  fake.panels = [];
  fake.commands = new Map();
  fake.messages = [];
  fake.written = new Map();
  fake.settings = {};
  fake.saveAnswer = undefined;
  fake.activeDocument = undefined;
  fake.activeEditorChanged = new EventEmitter();
  fake.logs = [];
}

/** @param {string} level */
const say = (level) => async (/** @type {string} */ text) => {
  fake.messages.push({ level, text });
  return undefined;
};

export const window = {
  get activeTextEditor() {
    return fake.activeDocument && { document: fake.activeDocument };
  },
  /** @param {(editor: unknown) => void} listener */
  onDidChangeActiveTextEditor: (listener) => fake.activeEditorChanged.event(listener),
  /**
   * @param {string} viewType
   * @param {string} title
   * @param {number} _column
   * @param {object} options
   */
  createWebviewPanel(viewType, title, _column, options) {
    const panel = new WebviewPanel(viewType, title, options);
    fake.panels.push(panel);
    return panel;
  },
  createOutputChannel() {
    const channel = logChannel();
    fake.logs.push(channel);
    return channel;
  },
  showSaveDialog: async () => fake.saveAnswer,
  showErrorMessage: say('error'),
  showWarningMessage: say('warning'),
  showInformationMessage: say('information'),
};

export const workspace = {
  /** @param {string} section */
  getConfiguration(section) {
    return {
      /**
       * @param {string} key
       * @param {unknown} [fallback]
       */
      get: (key, fallback) => fake.settings[`${section}.${key}`] ?? fallback,
    };
  },
  get workspaceFolders() {
    return [{ uri: Uri.file('/work') }];
  },
  fs: {
    /**
     * @param {Uri} uri
     * @param {Uint8Array} bytes
     */
    writeFile: async (uri, bytes) => {
      fake.written.set(uri.path, bytes);
    },
  },
  createFileSystemWatcher: () => ({ dispose() {} }),
};

export const commands = {
  /**
   * @param {string} id
   * @param {(...args: any[]) => any} run
   */
  registerCommand(id, run) {
    fake.commands.set(id, run);
    return { dispose: () => fake.commands.delete(id) };
  },
  /**
   * @param {string} id
   * @param {...any} args
   */
  executeCommand: async (id, ...args) => fake.commands.get(id)?.(...args),
};
