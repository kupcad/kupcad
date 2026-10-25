// The viewer: a webview panel beside the editor, showing the .kup document the editor shows.
// Its page (src/webview/) gets the model straight from the language server's viewport socket;
// the panel tells it which document it shows and the values the document's parameters take,
// and passes on what it asks: a frame (`ready`), new values, a screenshot to save, a place in the
// script to show in its editor. It keeps the document's presets (presets-file.js): their names
// for the page, again when their file changes, one applied, the panel's values saved as one.

import * as vscode from 'vscode';
import { isViewerMessage } from '@kupcad/protocol';
import { errorText } from '../errors.js';
import { EXPORT_COMMAND } from './commands.js';
import { PresetsFile } from './presets-file.js';
import { characterAt, fileName, isScriptFile, scriptName } from './scripts.js';
import { buildCsp, createNonce, prepareWebviewHtml } from './webview-html.js';

/** @import { HostMessage, ParamValues, ShownDocument, ViewerMessage } from '@kupcad/protocol/types' */
/** @import { ServerLink } from '../types.js' */
/** @import { Presets } from './presets.js' */
/** @import { ScriptValues } from './values.js' */

export const VIEW_TYPE = 'kupcad.viewer';
const TITLE = 'KupCAD Viewer';
/** Where the built page is, under the extension. */
export const PAGE_DIR = 'dist-webview';
const REPLACE = 'Replace';

/** @param {string} uri a script's */
const presetsFileOf = (uri) => new PresetsFile(vscode.Uri.parse(uri));

/**
 * @typedef {object} PanelOptions
 * @property {ServerLink} server
 * @property {ScriptValues} values the values each script's parameters were given
 * @property {vscode.Uri} extensionUri
 * @property {() => string} page the built page's HTML
 * @property {vscode.LogOutputChannel} log
 */

export class ViewerPanel {
  /** @type {vscode.WebviewPanel} */
  #panel;
  /** @type {PanelOptions} */
  #options;
  /** @type {ShownDocument | null} */
  #shown = null;
  /** @type {vscode.Disposable[]} */
  #disposables = [];
  /** The watch of the shown document's presets file. @type {vscode.Disposable | null} */
  #presetsWatch = null;
  #closed = false;

  /**
   * A panel beside the editor, showing the document the editor shows.
   * @param {PanelOptions} options
   * @returns {ViewerPanel}
   */
  static open(options) {
    const panel = vscode.window.createWebviewPanel(VIEW_TYPE, TITLE, vscode.ViewColumn.Beside, {
      enableScripts: true,
      retainContextWhenHidden: true,
      // Only the built page may be loaded from the disk
      localResourceRoots: [vscode.Uri.joinPath(options.extensionUri, PAGE_DIR)],
    });
    return new ViewerPanel(panel, options);
  }

  /**
   * @param {vscode.WebviewPanel} panel
   * @param {PanelOptions} options
   */
  constructor(panel, options) {
    this.#panel = panel;
    this.#options = options;
    this.#disposables.push(
      panel.webview.onDidReceiveMessage((message) => this.#receive(message)),
      vscode.window.onDidChangeActiveTextEditor((editor) => {
        if (editor) this.show(editor.document);
      }),
      // The server started (again): the page connects to its socket
      options.server.onViewport(() => this.#render()),
      panel.onDidDispose(() => this.#disposed()),
    );
    this.#render();
    const active = vscode.window.activeTextEditor;
    if (active) this.show(active.document);
  }

  /** The document shown, or null. */
  get shown() {
    return this.#shown;
  }

  /** Whether the panel was closed. */
  get closed() {
    return this.#closed;
  }

  reveal() {
    this.#panel.reveal(vscode.ViewColumn.Beside, true);
  }

  /**
   * Shows `document`, if it is a KupCAD script in a file (the server runs no other); another
   * document leaves the one shown.
   * @param {vscode.TextDocument} document
   */
  show(document) {
    if (!isScriptFile(document)) return;
    const uri = document.uri.toString();
    if (this.#shown?.uri === uri) return;
    this.#shown = { uri, name: fileName(document.uri) };
    this.#panel.title = `${TITLE}: ${this.#shown.name}`;
    // Its presets file edited, made or removed outside the panel
    this.#presetsWatch?.dispose();
    this.#presetsWatch = new PresetsFile(document.uri).watch(() => void this.#tellPresets());
    this.#tellDocument();
    this.#ask(this.#options.server.preview(uri), 'show');
  }

  dispose() {
    this.#panel.dispose();
  }

  /** The page: the built one, under a CSP that lets it reach the viewport socket alone. */
  #render() {
    const webview = this.#panel.webview;
    const nonce = createNonce();
    const viewportPort = this.#options.server.viewportPort ?? undefined;
    const pageRoot = vscode.Uri.joinPath(this.#options.extensionUri, PAGE_DIR);
    webview.html = prepareWebviewHtml(this.#options.page(), {
      csp: buildCsp({ cspSource: webview.cspSource, nonce, viewportPort }),
      nonce,
      viewportPort,
      toWebviewUri: (path) =>
        webview.asWebviewUri(vscode.Uri.joinPath(pageRoot, ...path.split('/'))).toString(),
    });
  }

  /** @param {unknown} message */
  #receive(message) {
    if (!isViewerMessage(message)) {
      this.#options.log.warn(
        `The viewer sent a message of no known shape: ${JSON.stringify(message)}`,
      );
      return;
    }
    this.#handle(message);
  }

  /** @param {ViewerMessage} message */
  #handle(message) {
    switch (message.type) {
      case 'ready':
        // A page loaded again (a new port, a reload) knows nothing yet
        this.#tellDocument();
        if (this.#shown) this.#ask(this.#options.server.preview(this.#shown.uri), 'ready');
        return;
      case 'setParams':
        this.#options.values.set(message.uri, message.values);
        this.#ask(this.#options.server.setParams(message.uri, message.values), 'setParams');
        return;
      case 'applyPreset':
        void this.#applyPreset(message.uri, message.name);
        return;
      case 'savePreset':
        void this.#savePreset(message.uri, message.values);
        return;
      case 'export':
        void vscode.commands.executeCommand(EXPORT_COMMAND, message.uri);
        return;
      case 'screenshot':
        void this.#saveScreenshot(message.png);
        return;
      case 'problem':
        this.#options.log.warn(`The viewer: ${message.message}`);
        return;
      case 'reveal':
        void this.#revealPlace(message.uri, message.line, message.column);
        return;
    }
  }

  /**
   * Shows the script at a place its run named (1-based, its column in UTF-8 bytes): in the
   * editor showing it, else in one showing another file, else beside the panel.
   * @param {string} uri
   * @param {number} line
   * @param {number} column
   */
  async #revealPlace(uri, line, column) {
    try {
      const document = await vscode.workspace.openTextDocument(vscode.Uri.parse(uri));
      const at = Math.min(line, document.lineCount) - 1;
      const place = new vscode.Position(at, characterAt(document.lineAt(at).text, column));
      const editors = vscode.window.visibleTextEditors;
      const editor = editors.find((shown) => shown.document.uri.toString() === uri) ?? editors[0];
      await vscode.window.showTextDocument(document, {
        viewColumn: editor?.viewColumn ?? vscode.ViewColumn.Beside,
        selection: new vscode.Range(place, place),
      });
    } catch (error) {
      void vscode.window.showErrorMessage(
        `${fileName(vscode.Uri.parse(uri))} can't be shown: ${errorText(error)}`,
      );
    }
  }

  /** Tells the page the document shown, the values its panel holds for it, and its presets. */
  #tellDocument() {
    this.#post({ type: 'document', document: this.#shown });
    if (this.#shown && this.#options.values.has(this.#shown.uri)) {
      const { uri } = this.#shown;
      this.#post({ type: 'overrides', uri, values: this.#options.values.of(uri) });
    }
    void this.#tellPresets();
  }

  /** Tells the page the names of the shown document's presets: none when its file can't be read (logged). */
  async #tellPresets() {
    if (!this.#shown) return;
    const { uri } = this.#shown;
    const file = presetsFileOf(uri);
    /** @type {string[]} */
    let names = [];
    try {
      names = Object.keys(await file.read());
    } catch (error) {
      this.#options.log.warn(`${file.uri.path} can't be read: ${errorText(error)}`);
    }
    this.#post({ type: 'presets', uri, names });
  }

  /**
   * The document runs with its preset's values, and the page's panel shows them.
   * @param {string} uri
   * @param {string} name
   */
  async #applyPreset(uri, name) {
    const file = presetsFileOf(uri);
    /** @type {Presets} */
    let presets;
    try {
      presets = await file.read();
    } catch (error) {
      void vscode.window.showErrorMessage(`${file.name} can't be read: ${errorText(error)}`);
      return;
    }
    // Gone meanwhile, or a name no preset has (`constructor` is none)
    if (!Object.hasOwn(presets, name)) return;
    const values = presets[name];
    this.#options.values.set(uri, values);
    this.#post({ type: 'overrides', uri, values });
    this.#ask(this.#options.server.setParams(uri, values), 'applyPreset');
  }

  /**
   * Keeps `values` as a preset of the document, under the name the user gives it (one already
   * there replaced when the user says so).
   * @param {string} uri
   * @param {ParamValues} values
   */
  async #savePreset(uri, values) {
    const file = presetsFileOf(uri);
    const typed = await vscode.window.showInputBox({
      title: 'Save the parameters as a preset',
      prompt: `Kept in ${file.name}, beside the script`,
      placeHolder: 'Small',
      validateInput: (text) => (text.trim() ? null : 'A preset needs a name'),
    });
    const name = typed?.trim();
    if (!name) return;
    try {
      // The file as it is once the name is chosen: it may have been edited meanwhile
      if (Object.hasOwn(await file.read(), name)) {
        const chosen = await vscode.window.showWarningMessage(
          `The preset "${name}" is there already: replace it?`,
          { modal: true },
          REPLACE,
        );
        if (chosen !== REPLACE) return;
      }
      await file.put(name, values);
    } catch (error) {
      void vscode.window.showErrorMessage(
        `The preset "${name}" wasn't saved in ${file.name}: ${errorText(error)}`,
      );
      return;
    }
    await this.#tellPresets();
  }

  /**
   * Tells the page `message`, unless the panel was closed meanwhile (a file read on).
   * @param {HostMessage} message
   */
  #post(message) {
    if (this.#closed) return;
    void this.#panel.webview.postMessage(message);
  }

  /**
   * Logs why a request to the server failed.
   * @param {Promise<void>} request
   * @param {string} what
   */
  #ask(request, what) {
    request.catch((error) => this.#options.log.error(`${what}: ${errorText(error)}`));
  }

  /** @param {string} png the image's bytes in base64 */
  async #saveScreenshot(png) {
    const name = this.#shown ? scriptName(vscode.Uri.parse(this.#shown.uri)) : 'model';
    const target = await vscode.window.showSaveDialog({
      defaultUri: vscode.Uri.joinPath(this.#folder(), `${name}.png`),
      filters: { 'PNG image': ['png'] },
    });
    if (!target) return;
    try {
      await vscode.workspace.fs.writeFile(target, Buffer.from(png, 'base64'));
    } catch (error) {
      void vscode.window.showErrorMessage(
        `The screenshot wasn't saved in ${fileName(target)}: ${errorText(error)}`,
      );
    }
  }

  /** The folder of the document shown, else the workspace's. */
  #folder() {
    if (this.#shown) return vscode.Uri.joinPath(vscode.Uri.parse(this.#shown.uri), '..');
    return vscode.workspace.workspaceFolders?.[0]?.uri ?? vscode.Uri.file('.');
  }

  #disposed() {
    this.#closed = true;
    for (const disposable of this.#disposables) disposable.dispose();
    this.#disposables = [];
    this.#presetsWatch?.dispose();
    this.#presetsWatch = null;
  }
}
