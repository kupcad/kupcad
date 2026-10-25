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
   * @param {string} [authority] the host, for a URL
   */
  constructor(scheme, uriPath, authority = '') {
    this.scheme = scheme;
    this.path = uriPath;
    this.authority = authority;
  }

  /** @param {string} file */
  static file(file) {
    return new Uri('file', path.posix.resolve('/', file));
  }

  /** @param {string} text */
  static parse(text) {
    const url = new URL(text);
    return new Uri(url.protocol.slice(0, -1), decodeURIComponent(url.pathname), url.host);
  }

  /**
   * @param {Uri} base
   * @param {...string} parts
   */
  static joinPath(base, ...parts) {
    return new Uri(base.scheme, path.posix.join(base.path, ...parts), base.authority);
  }

  /**
   * This URI with the parts given changed.
   * @param {{ scheme?: string, path?: string }} change
   */
  with(change) {
    return new Uri(change.scheme ?? this.scheme, change.path ?? this.path, this.authority);
  }

  get fsPath() {
    return this.path;
  }

  toString() {
    return `${this.scheme}://${this.authority}${this.path}`;
  }
}

export class Disposable {
  /** @param {() => void} callOnDispose */
  constructor(callOnDispose) {
    this.dispose = callOnDispose;
  }

  /** @param {...{ dispose(): unknown }} disposables */
  static from(...disposables) {
    return new Disposable(() => {
      for (const disposable of disposables) disposable.dispose();
    });
  }
}

/** A glob relative to a folder: a file there, say, wherever the workspace is. */
export class RelativePattern {
  /**
   * @param {Uri} base
   * @param {string} pattern
   */
  constructor(base, pattern) {
    this.baseUri = base;
    this.pattern = pattern;
  }
}

export const ViewColumn = { One: 1, Two: 2, Beside: -2 };

export class Position {
  /**
   * @param {number} line
   * @param {number} character
   */
  constructor(line, character) {
    this.line = line;
    this.character = character;
  }
}

export class Range {
  /**
   * @param {Position} start
   * @param {Position} end
   */
  constructor(start, end) {
    this.start = start;
    this.end = end;
  }
}
export const ProgressLocation = { SourceControl: 1, Window: 10, Notification: 15 };

export const env = {
  /** @param {Uri} uri */
  openExternal: async (uri) => {
    fake.opened.push(uri.toString());
    return fake.opens;
  },
};

/** A store of what the extension keeps between sessions (its globalState). */
export function memento() {
  /** @type {Map<string, unknown>} */
  const kept = new Map();
  return {
    kept,
    /**
     * @param {string} key
     * @param {unknown} [fallback]
     */
    get: (key, fallback) => (kept.has(key) ? kept.get(key) : fallback),
    /**
     * @param {string} key
     * @param {unknown} value
     */
    update: async (key, value) => {
      kept.set(key, value);
    },
  };
}
export const ExtensionMode = { Production: 1, Development: 2, Test: 3 };

/**
 * A document open in an editor: a file's, or one of another scheme (`untitled`, a diff's `git`).
 * @param {string} file
 * @param {string} [languageId]
 * @param {string} [scheme]
 */
export function documentAt(file, languageId = 'kupcad', scheme = 'file') {
  const document = {
    uri: Uri.file(file).with({ scheme }),
    fileName: file,
    languageId,
    isDirty: false,
    saves: 0,
    /** What it holds: a test sets it. */
    text: '',
    async save() {
      document.saves += 1;
      document.isDirty = false;
      return true;
    },
    get lineCount() {
      return document.text.split('\n').length;
    },
    /** @param {number} line */
    lineAt(line) {
      const lines = document.text.split('\n');
      if (line < 0 || line >= lines.length) throw new Error(`Illegal value for line: ${line}`);
      return { text: lines[line] };
    },
  };
  fake.documents.set(document.uri.toString(), document);
  return document;
}

class Webview {
  cspSource = 'vscode-resource:';
  /** What the extension posted the page. @type {unknown[]} */
  posted = [];
  /** Whether its panel was closed: VS Code throws on using it then. */
  disposed = false;
  #html = '';
  #received = new EventEmitter();
  onDidReceiveMessage = this.#received.event;

  get html() {
    return this.#html;
  }

  set html(html) {
    this.#assertLive();
    this.#html = html;
  }

  /** @param {unknown} message */
  postMessage(message) {
    this.#assertLive();
    this.posted.push(message);
    return Promise.resolve(true);
  }

  /** @param {Uri} uri */
  asWebviewUri(uri) {
    return new Uri('https', uri.path, 'webview');
  }

  /**
   * The page sends `message`.
   * @param {unknown} message
   */
  receive(message) {
    this.#received.fire(message);
  }

  #assertLive() {
    if (this.disposed) throw new Error('Webview is disposed');
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
    if (this.webview.disposed) return;
    this.webview.disposed = true;
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
  /** @type {{ level: string, text: string, buttons: string[], modal: boolean }[]} */
  messages: [],
  /** The button the user picks on a message: one of its buttons, or none (dismissed). @type {string | undefined} */
  answer: undefined,
  /** What was opened outside VS Code. @type {string[]} */
  opened: [],
  /** The progress notifications: their titles, whether they can be cancelled, and what each reported. @type {{ title: string, cancellable: boolean, reports: unknown[] }[]} */
  progress: [],
  /** @type {Map<string, Uint8Array>} the file system: what was there, and what was written, by path */
  files: new Map(),
  /** What the input box answers: a text, or nothing (cancelled). @type {string | undefined} */
  inputAnswer: undefined,
  /** The input boxes shown, by their options. @type {object[]} */
  inputs: [],
  /** The file watchers not disposed, each with the glob of the paths it watches. @type {{ glob: string, changed: EventEmitter, created: EventEmitter, deleted: EventEmitter }[]} */
  watchers: [],
  /** The documents open, by URI. @type {Map<string, ReturnType<typeof documentAt>>} */
  documents: new Map(),
  /** The label the user picks in a quick pick, or none (dismissed). @type {string | undefined} */
  pick: undefined,
  /** The quick picks shown: their items' labels. @type {string[][]} */
  picks: [],
  /** Whether opening a file outside VS Code works. */
  opens: true,
  /** The progress notifications running, to cancel. @type {EventEmitter[]} */
  cancellations: [],
  settingsChanged: new EventEmitter(),

  /**
   * The user changed the settings named (their full names).
   * @param {string[]} names
   */
  changeSettings(...names) {
    this.settingsChanged.fire({
      affectsConfiguration: (/** @type {string} */ name) => names.includes(name),
    });
  },

  /** The user cancels the progress notifications running. */
  cancelProgress() {
    for (const cancelled of this.cancellations) cancelled.fire();
  },

  /**
   * A file changed on disk, as the watchers of its path hear it.
   * @param {string} file
   */
  fileChanged(file) {
    for (const watcher of this.watchers) {
      if (path.posix.matchesGlob(file, watcher.glob)) watcher.changed.fire(Uri.file(file));
    }
  },
  /** @type {Record<string, unknown>} the settings, by their full name */
  settings: {},
  /** What the save dialog answers: a file, or nothing (cancelled). @type {Uri | undefined} */
  saveAnswer: undefined,
  /** @type {ReturnType<typeof documentAt> | undefined} */
  activeDocument: undefined,
  activeEditorChanged: new EventEmitter(),
  /** The editors shown, each with its column. @type {{ document: ReturnType<typeof documentAt>, viewColumn: number }[]} */
  visibleEditors: [],
  /** What `showTextDocument` was asked to show, and where. @type {{ uri: string, viewColumn: number | undefined, selection: Range | undefined }[]} */
  shownDocuments: [],
  /** @type {ReturnType<typeof logChannel>[]} */
  logs: [],

  /**
   * The editor shows `document`, or none has the focus (a panel has it, say).
   * @param {ReturnType<typeof documentAt> | undefined} document
   */
  showEditor(document) {
    this.activeDocument = document;
    this.activeEditorChanged.fire(document && { document });
  },
};

export function resetFake() {
  fake.panels = [];
  fake.commands = new Map();
  fake.messages = [];
  fake.answer = undefined;
  fake.opened = [];
  fake.progress = [];
  fake.files = new Map();
  fake.inputAnswer = undefined;
  fake.inputs = [];
  fake.watchers = [];
  fake.documents = new Map();
  fake.pick = undefined;
  fake.picks = [];
  fake.opens = true;
  fake.cancellations = [];
  fake.settingsChanged = new EventEmitter();
  fake.settings = {};
  fake.saveAnswer = undefined;
  fake.activeDocument = undefined;
  fake.activeEditorChanged = new EventEmitter();
  fake.visibleEditors = [];
  fake.shownDocuments = [];
  fake.logs = [];
}

/**
 * A message of `level`: its text, then its options (`{ modal }`), if any, and its buttons.
 * @param {string} level
 */
const say =
  (level) =>
  async (/** @type {string} */ text, /** @type {unknown[]} */ ...rest) => {
    const buttons = /** @type {string[]} */ (rest.filter((item) => typeof item === 'string'));
    const options = /** @type {{ modal?: boolean } | undefined} */ (
      rest.find((item) => typeof item === 'object')
    );
    fake.messages.push({ level, text, buttons, modal: options?.modal === true });
    return buttons.includes(/** @type {string} */ (fake.answer)) ? fake.answer : undefined;
  };

export const window = {
  get activeTextEditor() {
    return fake.activeDocument && { document: fake.activeDocument };
  },
  /** @param {(editor: unknown) => void} listener */
  onDidChangeActiveTextEditor: (listener) => fake.activeEditorChanged.event(listener),
  get visibleTextEditors() {
    return fake.visibleEditors;
  },
  /**
   * @param {ReturnType<typeof documentAt>} document
   * @param {{ viewColumn?: number, selection?: Range }} [options]
   */
  async showTextDocument(document, options = {}) {
    fake.shownDocuments.push({
      uri: document.uri.toString(),
      viewColumn: options.viewColumn,
      selection: options.selection,
    });
    return { document };
  },
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
  /** @param {object} options */
  showInputBox: async (options) => {
    fake.inputs.push(options);
    return fake.inputAnswer;
  },
  /**
   * @param {{ title: string, cancellable?: boolean }} options
   * @param {(progress: { report(value: unknown): void }, token: { onCancellationRequested: EventEmitter['event'] }) => Promise<unknown>} task
   */
  async withProgress(options, task) {
    const shown = {
      title: options.title,
      cancellable: options.cancellable === true,
      reports: /** @type {unknown[]} */ ([]),
    };
    fake.progress.push(shown);
    const cancelled = new EventEmitter();
    fake.cancellations.push(cancelled);
    return task(
      { report: (value) => shown.reports.push(value) },
      { onCancellationRequested: cancelled.event },
    );
  },
  /** @param {{ label: string }[]} items */
  showQuickPick: async (items) => {
    fake.picks.push(items.map((item) => item.label));
    return items.find((item) => item.label === fake.pick);
  },
  showErrorMessage: say('error'),
  showWarningMessage: say('warning'),
  showInformationMessage: say('information'),
};

export const workspace = {
  /** @param {(event: { affectsConfiguration(name: string): boolean }) => void} listener */
  onDidChangeConfiguration: (listener) => fake.settingsChanged.event(listener),
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
  /** @param {Uri} uri */
  openTextDocument: async (uri) =>
    fake.documents.get(uri.toString()) ?? documentAt(uri.path, 'kupcad', uri.scheme),
  get workspaceFolders() {
    return [{ uri: Uri.file('/work') }];
  },
  fs: {
    /**
     * @param {Uri} uri
     * @param {Uint8Array} bytes
     */
    writeFile: async (uri, bytes) => {
      fake.files.set(uri.path, bytes);
    },
    /** @param {Uri} uri */
    readFile: async (uri) => {
      const bytes = fake.files.get(uri.path);
      if (!bytes) throw Object.assign(new Error(`${uri.path} not found`), { code: 'FileNotFound' });
      return bytes;
    },
  },
  /** @param {string | RelativePattern} pattern a glob of the workspace's paths, or one in a folder */
  createFileSystemWatcher(pattern) {
    const watcher = {
      glob:
        typeof pattern === 'string'
          ? pattern
          : path.posix.join(pattern.baseUri.path, pattern.pattern),
      changed: new EventEmitter(),
      created: new EventEmitter(),
      deleted: new EventEmitter(),
    };
    fake.watchers.push(watcher);
    return {
      onDidChange: watcher.changed.event,
      onDidCreate: watcher.created.event,
      onDidDelete: watcher.deleted.event,
      dispose: () => (fake.watchers = fake.watchers.filter((w) => w !== watcher)),
    };
  },
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
   * Runs the command registered as `id`: VS Code rejects one that isn't.
   * @param {string} id
   * @param {...any} args
   */
  executeCommand: async (id, ...args) => {
    const run = fake.commands.get(id);
    if (!run) throw new Error(`command '${id}' not found`);
    return run(...args);
  },
};
