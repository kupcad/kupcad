// The extension's host side (Node, in VS Code's extension host): it starts the language server
// for .kup documents (the kupcad found, or installed, by the binary manager), keeps its own
// install up to date, and opens the viewer, a webview the server sends its models to.

import * as fs from 'node:fs';
import * as path from 'node:path';
import * as vscode from 'vscode';
import { BinaryManager, CHECK_FOR_UPDATES_COMMAND } from './binary/manager.js';
import { errorText } from '../errors.js';
import { registerExportCommands } from './commands.js';
import { LanguageServer } from './server.js';
import { NOT_RUNNING } from './scripts.js';
import { ScriptValues } from './values.js';
import { PAGE_DIR, ViewerPanel } from './viewer-panel.js';

export const OPEN_VIEWER_COMMAND = 'kupcad.openViewer';
/** The viewport socket's port the server tries first, unless the settings say another. */
const DEFAULT_VIEWPORT_PORT = 9001;

/** The extension's settings, as they are now. */
const settings = () => vscode.workspace.getConfiguration('kupcad');

/** @type {LanguageServer | null} */
let server = null;

/** @param {vscode.ExtensionContext} context */
export async function activate(context) {
  server = null;
  const log = vscode.window.createOutputChannel('KupCAD', { log: true });
  context.subscriptions.push(log);
  const binaries = new BinaryManager({
    range: context.extension.packageJSON.kupcad.core,
    managedDir: path.join(context.globalStorageUri.fsPath, 'bin'),
    extensionPath: context.extensionPath,
    state: context.globalState,
    log,
    settings,
  });
  /** Runs the kupcad an update installed, when there is one. @param {string | null} next */
  const restartOn = async (next) => {
    if (next && server) await server.restart(next);
  };

  /** @type {ViewerPanel | null} */
  let viewer = null;
  const values = new ScriptValues();
  const pagePath = path.join(context.extensionPath, PAGE_DIR, 'index.html');
  context.subscriptions.push(
    vscode.commands.registerCommand(OPEN_VIEWER_COMMAND, () => {
      if (!server) {
        void vscode.window.showErrorMessage(NOT_RUNNING);
        return;
      }
      if (viewer && !viewer.closed) {
        viewer.reveal();
        return;
      }
      viewer = ViewerPanel.open({
        server,
        values,
        extensionUri: context.extensionUri,
        page: () => fs.readFileSync(pagePath, 'utf8'),
        log,
      });
    }),
    vscode.commands.registerCommand(CHECK_FOR_UPDATES_COMMAND, async () =>
      restartOn(await binaries.checkForUpdates({ asked: true })),
    ),
    ...registerExportCommands({
      kupcad: () => server?.serverPath ?? null,
      values,
      shown: () => (viewer?.closed ? null : (viewer?.shown?.uri ?? null)),
      log,
    }),
  );

  // The manager says why when there is none
  const found = await binaries.server();
  if (!found) return;
  log.info(`Running kupcad ${found.version} (${found.path})`);
  server = new LanguageServer({
    serverPath: found.path,
    viewportPort: settings().get('viewport.port', DEFAULT_VIEWPORT_PORT),
    log,
  });
  try {
    await server.start();
  } catch (error) {
    const why = errorText(error);
    void vscode.window.showErrorMessage(`The KupCAD language server didn't start: ${why}`);
    return;
  }
  void binaries.checkForUpdates({ asked: false }).then(restartOn);
}

export async function deactivate() {
  await server?.stop();
  server = null;
}
