// Export and print: the script (the one given, the editor's, else the viewer's) saved, built by
// `kupcad build` with the values its parameters have in the viewer, and the file written where the
// user says, or opened in a slicer.

import * as fs from 'node:fs/promises';
import * as os from 'node:os';
import * as path from 'node:path';
import * as vscode from 'vscode';
import {
  buildArguments,
  FORMATS,
  printFile,
  runBuild,
  slicerCommand,
  startApart,
} from './export.js';

/** @import { ScriptValues } from './values.js' */

export const EXPORT_COMMAND = 'kupcad.export';
export const PRINT_COMMAND = 'kupcad.print';
const LANGUAGE_ID = 'kupcad';
const SAVE = 'Save';
const REVEAL = 'Reveal';
const NOT_RUNNING =
  "KupCAD's language server isn't running, nor its kupcad to build with: the KupCAD output says why.";

/**
 * @typedef {object} CommandOptions
 * @property {() => string | null} kupcad the kupcad running now, or null
 * @property {ScriptValues} values
 * @property {() => string | null} shown the URI of the script the viewer shows, if one
 * @property {vscode.LogOutputChannel} log
 * @property {typeof runBuild} [build]
 * @property {typeof startApart} [start]
 */

/**
 * @param {CommandOptions} options
 * @returns {vscode.Disposable[]}
 */
export function registerExportCommands(options) {
  return [
    vscode.commands.registerCommand(EXPORT_COMMAND, (given) => exportScript(options, given)),
    vscode.commands.registerCommand(PRINT_COMMAND, (given) => printScript(options, given)),
  ];
}

/**
 * Exports the script in the format the user picks, where the user says.
 * @param {CommandOptions} options
 * @param {vscode.Uri | string | undefined} given
 */
async function exportScript(options, given) {
  const ready = await scriptToBuild(options, given);
  if (!ready) return;
  const { document, kupcad } = ready;
  const name = scriptName(document);
  const choice = await vscode.window.showQuickPick(
    FORMATS.map((f) => ({ label: f.label, detail: f.detail, format: f.format })),
    { title: `Export ${name}`, placeHolder: 'The format' },
  );
  if (!choice) return;
  const target = await vscode.window.showSaveDialog({
    defaultUri: vscode.Uri.joinPath(document.uri, '..', `${name}.${choice.format}`),
    filters: { [choice.label]: [choice.format] },
    saveLabel: 'Export',
  });
  if (!target) return;
  const built = await build(
    options,
    kupcad,
    document,
    target.fsPath,
    `Exporting ${name} as ${choice.label}`,
  );
  if (!built) return;
  const chosen = await vscode.window.showInformationMessage(
    `Exported ${path.basename(target.fsPath)}.`,
    REVEAL,
  );
  if (chosen === REVEAL) await vscode.commands.executeCommand('revealFileInOS', target);
}

/**
 * Prints the script: a 3MF built in the temporary folder, opened in the slicer the settings name,
 * else in the program the system opens a 3MF with.
 * @param {CommandOptions} options
 * @param {vscode.Uri | string | undefined} given
 */
async function printScript(options, given) {
  const ready = await scriptToBuild(options, given);
  if (!ready) return;
  const { document, kupcad } = ready;
  const output = printFile(os.tmpdir(), document.uri.fsPath);
  await fs.mkdir(path.dirname(output), { recursive: true });
  const built = await build(
    options,
    kupcad,
    document,
    output,
    `Preparing ${scriptName(document)} for printing`,
  );
  if (!built) return;
  const slicer = vscode.workspace.getConfiguration('kupcad').get('print.slicer');
  if (typeof slicer === 'string' && slicer) {
    try {
      await (options.start ?? startApart)(slicerCommand(slicer, output, process.platform));
    } catch (error) {
      void vscode.window.showErrorMessage(
        `The slicer (${slicer}) couldn't be started: ${errorText(error)}`,
      );
    }
    return;
  }
  const opened = await vscode.env.openExternal(vscode.Uri.file(output));
  if (!opened) {
    void vscode.window.showErrorMessage(
      `${output} was built, and nothing opened it: set "kupcad.print.slicer" to your slicer.`,
    );
  }
}

/**
 * The script to build and the kupcad to build it with, the script saved: null when there is none
 * (the user told why), or the user left it unsaved.
 * @param {CommandOptions} options
 * @param {vscode.Uri | string | undefined} given
 * @returns {Promise<{ document: vscode.TextDocument, kupcad: string } | null>}
 */
async function scriptToBuild(options, given) {
  const document = await scriptOf(options, given);
  if (!document) {
    void vscode.window.showInformationMessage('Open a KupCAD script to build it.');
    return null;
  }
  if (document.uri.scheme !== 'file') {
    void vscode.window.showInformationMessage(
      `Save ${scriptName(document)} to a file first: kupcad builds files.`,
    );
    return null;
  }
  const kupcad = options.kupcad();
  if (!kupcad) {
    void vscode.window.showErrorMessage(NOT_RUNNING);
    return null;
  }
  if (document.isDirty) {
    const chosen = await vscode.window.showWarningMessage(
      `${scriptName(document)} has changes not saved, and kupcad builds the file: save it first?`,
      { modal: true },
      SAVE,
    );
    if (chosen !== SAVE || !(await document.save())) return null;
  }
  return { document, kupcad };
}

/**
 * The script given (a command's argument: a URI, or its text), else the editor's, else the one the
 * viewer shows.
 * @param {CommandOptions} options
 * @param {vscode.Uri | string | undefined} given
 * @returns {Promise<vscode.TextDocument | null>}
 */
async function scriptOf(options, given) {
  if (given)
    return vscode.workspace.openTextDocument(
      typeof given === 'string' ? vscode.Uri.parse(given) : given,
    );
  const active = vscode.window.activeTextEditor?.document;
  if (active?.languageId === LANGUAGE_ID) return active;
  const shown = options.shown();
  return shown ? vscode.workspace.openTextDocument(vscode.Uri.parse(shown)) : null;
}

/**
 * Builds the script to `output` with its values, a notification showing it (its cancel stops the
 * build): false when it failed (the user told why) or was stopped.
 * @param {CommandOptions} options
 * @param {string} kupcad
 * @param {vscode.TextDocument} document
 * @param {string} output
 * @param {string} title
 */
function build(options, kupcad, document, output, title) {
  const script = document.uri.fsPath;
  const args = buildArguments(script, output, options.values.of(document.uri.toString()));
  return vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title, cancellable: true },
    async (_progress, token) => {
      const stop = new AbortController();
      token.onCancellationRequested(() => stop.abort());
      try {
        await (options.build ?? runBuild)(kupcad, args, {
          cwd: path.dirname(script),
          signal: stop.signal,
        });
        return true;
      } catch (error) {
        if (stop.signal.aborted) return false;
        options.log.error(`kupcad ${args.join(' ')}: ${errorText(error)}`);
        void vscode.window.showErrorMessage(
          `${scriptName(document)} couldn't be built: ${errorText(error)}`,
        );
        return false;
      }
    },
  );
}

/** @param {vscode.TextDocument} document */
const scriptName = (document) => path.basename(document.uri.fsPath).replace(/\.kup$/, '');

/** @param {unknown} error */
const errorText = (error) => (error instanceof Error ? error.message : String(error));
