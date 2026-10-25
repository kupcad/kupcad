// The extension's host side (Node, in VS Code's extension host): it starts the language server
// for .kup documents (the kupcad found, or installed, by the binary manager), starts it again on
// an update or a setting changed, and opens the viewer, a webview the server sends its models to.

import * as fs from 'node:fs';
import { errorText, ScriptValues } from '@kupcad/protocol';
import * as path from 'node:path';
import * as vscode from 'vscode';
import { BinaryManager, UPDATE_CLI_COMMAND } from './binary/manager.js';
import { registerExportCommands } from './commands.js';
import { LanguageServer } from './server.js';
import { NOT_RUNNING } from './scripts.js';
import { PAGE_DIR, ViewerPanel } from './viewer-panel.js';

export const OPEN_VIEWER_COMMAND = 'kupcad.openViewer';
/** The viewport socket's port the server tries first, unless the settings say another. */
const DEFAULT_VIEWPORT_PORT = 9001;
/** The settings the server is started with: changed, it starts again. */
const SERVER_SETTINGS = ['kupcad.serverPath', 'kupcad.viewport.port'];

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
    development: context.extensionMode === vscode.ExtensionMode.Development,
    state: context.globalState,
    log,
    settings,
  });
  const values = new ScriptValues();

  /**
   * Runs the kupcad the manager finds (installing one when none is), with the settings as they
   * are now: started the first time, started again after. False when there is none, or it
   * didn't start: the user was told why.
   */
  const startServer = async () => {
    const found = await binaries.server();
    if (!found) return false;
    const viewportPort = settings().get('viewport.port', DEFAULT_VIEWPORT_PORT);
    try {
      if (server) {
        await server.restart({ serverPath: found.path, viewportPort });
      } else {
        server = new LanguageServer({ serverPath: found.path, viewportPort, values, log });
        await server.start();
      }
    } catch (error) {
      void vscode.window.showErrorMessage(
        `The KupCAD language server didn't start: ${errorText(error)}`,
      );
      return false;
    }
    log.info(`Running kupcad ${found.version} (${found.path})`);
    return true;
  };

  /**
   * Runs the kupcad an update installed, if one did, and removes the installs it replaced.
   * @param {string | null} next
   */
  const runUpdate = async (next) => {
    if (!next || !server || next === server.serverPath) return;
    await server.restart({ serverPath: next });
    await binaries.prune();
  };

  /** @type {ViewerPanel | null} */
  let viewer = null;
  const pagePath = path.join(context.extensionPath, PAGE_DIR, 'index.html');
  context.subscriptions.push(
    vscode.commands.registerCommand(OPEN_VIEWER_COMMAND, () => {
      if (!server?.started) {
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
    // With none running (an install that failed offline, say), it tries again
    vscode.commands.registerCommand(UPDATE_CLI_COMMAND, async () => {
      if (!server?.started) await startServer();
      else await runUpdate(await binaries.checkForUpdates({ asked: true }));
    }),
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (SERVER_SETTINGS.some((name) => event.affectsConfiguration(name))) void startServer();
    }),
    ...registerExportCommands({
      kupcad: () => server?.serverPath ?? null,
      values,
      shown: () => (viewer?.closed ? null : (viewer?.shown?.uri ?? null)),
      log,
    }),
  );

  if (!(await startServer())) return;
  binaries
    .checkForUpdates({ asked: false })
    .then(runUpdate)
    .catch((error) => log.error(`The update of kupcad failed: ${errorText(error)}`));
}

export async function deactivate() {
  await server?.stop();
  server = null;
}
