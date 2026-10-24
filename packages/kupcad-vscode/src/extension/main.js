// The extension's host side (Node, in VS Code's extension host): it starts the language server
// for .kup documents, and opens the viewer, a webview the server sends its models to.

import * as fs from 'node:fs';
import * as path from 'node:path';
import * as vscode from 'vscode';
import { resolveServerPath } from './binary/resolve.js';
import { LanguageServer } from './server.js';
import { PAGE_DIR, ViewerPanel } from './viewer-panel.js';

export const OPEN_VIEWER_COMMAND = 'kupcad.openViewer';
/** The viewport socket's port the server tries first, unless the settings say another. */
const DEFAULT_VIEWPORT_PORT = 9001;
const NOT_FOUND =
  'The KupCAD language server was not found: install `kupcad` on your PATH, or set "kupcad.serverPath".';

/** @type {LanguageServer | null} */
let server = null;

/** @param {vscode.ExtensionContext} context */
export async function activate(context) {
  const log = vscode.window.createOutputChannel('KupCAD', { log: true });
  context.subscriptions.push(log);
  const config = vscode.workspace.getConfiguration('kupcad');
  const serverPath = resolveServerPath({
    configured: config.get('serverPath'),
    extensionPath: context.extensionPath,
  });
  const started = serverPath
    ? new LanguageServer({
        serverPath,
        viewportPort: config.get('viewport.port', DEFAULT_VIEWPORT_PORT),
        log,
      })
    : null;
  server = started;

  /** @type {ViewerPanel | null} */
  let viewer = null;
  const pagePath = path.join(context.extensionPath, PAGE_DIR, 'index.html');
  context.subscriptions.push(
    vscode.commands.registerCommand(OPEN_VIEWER_COMMAND, () => {
      if (!started) {
        void vscode.window.showErrorMessage(NOT_FOUND);
        return;
      }
      if (viewer && !viewer.closed) {
        viewer.reveal();
        return;
      }
      viewer = ViewerPanel.open({
        server: started,
        extensionUri: context.extensionUri,
        page: () => fs.readFileSync(pagePath, 'utf8'),
        log,
      });
    }),
  );

  if (!started) {
    void vscode.window.showErrorMessage(NOT_FOUND);
    return;
  }
  try {
    await started.start();
  } catch (error) {
    const why = error instanceof Error ? error.message : String(error);
    void vscode.window.showErrorMessage(`The KupCAD language server didn't start: ${why}`);
  }
}

export function deactivate() {
  return server?.stop();
}
