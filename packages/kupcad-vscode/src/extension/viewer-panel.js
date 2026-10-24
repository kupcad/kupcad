// The viewer: a webview panel beside the editor, showing the .kup document the editor shows.
// Its page (src/webview/) gets the model straight from the language server's viewport socket;
// the panel tells it which document it shows and the values the document's parameters take,
// and passes on what it asks: a frame (`ready`), new values, a screenshot to save.

import * as vscode from 'vscode';
import { isViewerMessage } from '@kupcad/protocol';
import { buildCsp, createNonce, prepareWebviewHtml } from './webview-html.js';

/** @import { HostMessage, ParamValues, ShownDocument, ViewerMessage } from '@kupcad/protocol/types' */
/** @import { ServerLink } from '../types.js' */

export const VIEW_TYPE = 'kupcad.viewer';
const LANGUAGE_ID = 'kupcad';
const TITLE = 'KupCAD Viewer';
/** Where the built page is, under the extension. */
export const PAGE_DIR = 'dist-webview';

/**
 * @typedef {object} PanelOptions
 * @property {ServerLink} server
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
  /** The values the viewer gave each document's parameters, by URI: given again to a server that restarted. @type {Map<string, ParamValues>} */
  #overrides = new Map();
  /** @type {vscode.Disposable[]} */
  #disposables = [];
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
      options.server.onViewport(() => this.#serverStarted()),
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
   * Shows `document`, if it is a KupCAD script; another document leaves the one shown.
   * @param {vscode.TextDocument} document
   */
  show(document) {
    if (document.languageId !== LANGUAGE_ID) return;
    const uri = document.uri.toString();
    if (this.#shown?.uri === uri) return;
    this.#shown = { uri, name: basename(document.uri) };
    this.#panel.title = `${TITLE}: ${this.#shown.name}`;
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
        this.#overrides.set(message.uri, message.values);
        this.#ask(this.#options.server.setParams(message.uri, message.values), 'setParams');
        return;
      case 'screenshot':
        void this.#saveScreenshot(message.png);
        return;
      case 'problem':
        this.#options.log.warn(`The viewer: ${message.message}`);
        return;
    }
  }

  /** Tells the page the document shown, and the values its panel holds for it. */
  #tellDocument() {
    this.#post({ type: 'document', document: this.#shown });
    const values = this.#shown && this.#overrides.get(this.#shown.uri);
    if (this.#shown && values) this.#post({ type: 'overrides', uri: this.#shown.uri, values });
  }

  /**
   * The server started (again): the page connects to its socket, and the values given before
   * are given again, a restarted server knowing none.
   */
  #serverStarted() {
    this.#render();
    for (const [uri, values] of this.#overrides) {
      this.#ask(this.#options.server.setParams(uri, values), 'setParams');
    }
  }

  /** @param {HostMessage} message */
  #post(message) {
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
    const name = this.#shown?.name.replace(/\.kup$/, '') ?? 'model';
    const target = await vscode.window.showSaveDialog({
      defaultUri: vscode.Uri.joinPath(this.#folder(), `${name}.png`),
      filters: { 'PNG image': ['png'] },
    });
    if (!target) return;
    await vscode.workspace.fs.writeFile(target, Buffer.from(png, 'base64'));
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
  }
}

/** @param {vscode.Uri} uri */
const basename = (uri) => uri.path.slice(uri.path.lastIndexOf('/') + 1);

/** @param {unknown} error */
const errorText = (error) => (error instanceof Error ? error.message : String(error));
