import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import { LanguageClient, TransportKind } from 'vscode-languageclient/node';
import {
  buildCsp,
  createNonce,
  devWebviewHtml,
  prepareWebviewHtml,
  resolveServerPath,
  VIEWPORT_PORT_ENV,
  VIEWPORT_READY_NOTIFICATION,
} from './webview.js';

const WEBVIEW_DIST_DIR = 'dist-webview';

/** @type {LanguageClient | undefined} */
let client;
/**
 * Port the LSP's viewport WebSocket actually bound (reported via kupcad/viewportReady).
 * @type {number | undefined}
 */
let viewportPort;
/** @type {Set<vscode.WebviewPanel>} */
const panels = new Set();

/**
 * @param {vscode.ExtensionContext} context
 * @param {vscode.WebviewPanel} panel
 */
const renderPanel = (context, panel) => {
  const isDev = context.extensionMode === vscode.ExtensionMode.Development;
  const nonce = createNonce();
  const csp = buildCsp({ cspSource: panel.webview.cspSource, nonce, viewportPort, isDev });

  if (isDev) {
    // Vite dev server with Hot Module Replacement
    panel.webview.html = prepareWebviewHtml(devWebviewHtml(), { csp, nonce, viewportPort });
    return;
  }

  const distRoot = vscode.Uri.joinPath(context.extensionUri, WEBVIEW_DIST_DIR);
  const indexPath = path.join(context.extensionPath, WEBVIEW_DIST_DIR, 'index.html');
  let html;
  try {
    html = fs.readFileSync(indexPath, 'utf8');
  } catch (err) {
    const why = err instanceof Error ? err.message : String(err);
    html = `<p>KupCAD viewer assets are missing (${why}). Run the extension build.</p>`;
  }
  panel.webview.html = prepareWebviewHtml(html, {
    csp,
    nonce,
    viewportPort,
    toWebviewUri: (rel) =>
      panel.webview.asWebviewUri(vscode.Uri.joinPath(distRoot, ...rel.split('/'))).toString(),
  });
};

/** @param {vscode.ExtensionContext} context */
export const activate = (context) => {
  context.subscriptions.push(
    vscode.commands.registerCommand('kupcad.showUI', () => {
      const panel = vscode.window.createWebviewPanel(
        'kupcadViewer',
        'KupCAD Viewer',
        vscode.ViewColumn.Beside,
        {
          enableScripts: true,
          // Only the bundled webview assets may be loaded from disk.
          localResourceRoots: [vscode.Uri.joinPath(context.extensionUri, WEBVIEW_DIST_DIR)],
        },
      );
      panels.add(panel);
      panel.onDidDispose(() => panels.delete(panel));
      renderPanel(context, panel);
    }),
  );

  const config = vscode.workspace.getConfiguration('kupcad');
  const serverPath = resolveServerPath({
    configured: config.get('serverPath'),
    extensionPath: context.extensionPath,
  });
  if (!serverPath) {
    vscode.window.showErrorMessage(
      'KupCAD language server not found. Install `kupcad` on your PATH or set "kupcad.serverPath".',
    );
    return;
  }

  // The server falls back to an ephemeral port if this one is taken and reports the real one.
  const env = { ...process.env, [VIEWPORT_PORT_ENV]: String(config.get('viewport.port', 9001)) };
  const exec = {
    command: serverPath,
    args: ['lsp'],
    transport: TransportKind.stdio,
    options: { env },
  };
  const serverOptions = { run: exec, debug: exec };

  // Define client options (Listen to .kup files)
  const clientOptions = {
    documentSelector: [{ scheme: 'file', language: 'kupcad' }],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher('**/*.kup'),
    },
  };

  client = new LanguageClient(
    'kupcadLanguageServer',
    'KupCAD Language Server',
    serverOptions,
    clientOptions,
  );

  context.subscriptions.push(
    client.onNotification(VIEWPORT_READY_NOTIFICATION, (params) => {
      const port = Number(params?.port);
      if (!Number.isInteger(port) || port <= 0 || port > 65535) return;
      viewportPort = port;
      // CSP connect-src is baked into the HTML, so re-render open viewers with the new port.
      for (const panel of panels) renderPanel(context, panel);
    }),
  );

  // Start the client (this also spawns the Zig server)
  client
    .start()
    .then(() => {
      console.log('KupCAD LSP Client successfully started!');
    })
    .catch((error) => {
      vscode.window.showErrorMessage(`Failed to start KupCAD LSP: ${error.message}`);
      console.error('LSP Startup Error:', error);
    });
};

export const deactivate = () => {
  if (!client) {
    return undefined;
  }
  return client.stop();
};
