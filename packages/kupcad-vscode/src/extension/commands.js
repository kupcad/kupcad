// Export: the script (the one given, the editor's, else the viewer's) saved, built by
// `kupcad build` with the values its parameters have in the viewer, in the format the user picks
// and where the user says.

import * as path from 'node:path';
import * as vscode from 'vscode';
import { EXPORT_FORMATS } from '@kupcad/protocol';
import { buildArguments, runBuild } from './export.js';
import { errorText } from '../errors.js';
import { FILE_SCHEME, fileName, LANGUAGE_ID, NOT_RUNNING, scriptName } from './scripts.js';

/** @import { ExportFormat } from '@kupcad/protocol/types' */
/** @import { ScriptValues } from './values.js' */

export const EXPORT_COMMAND = 'kupcad.export';
const SAVE = 'Save';
const REVEAL = 'Reveal';

/**
 * @typedef {object} CommandOptions
 * @property {() => string | null} kupcad the kupcad running now, or null
 * @property {ScriptValues} values
 * @property {() => string | null} shown the URI of the script the viewer shows, if one
 * @property {vscode.LogOutputChannel} log
 * @property {typeof runBuild} [build]
 */

/**
 * @param {CommandOptions} options
 * @returns {vscode.Disposable[]}
 */
export function registerExportCommands(options) {
  return [vscode.commands.registerCommand(EXPORT_COMMAND, (given) => exportScript(options, given))];
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
  const name = scriptName(document.uri);
  const choice = await vscode.window.showQuickPick(
    EXPORT_FORMATS.map((f) => ({ label: f.label, detail: f.detail, format: f.format })),
    { title: `Export ${name}`, placeHolder: 'The format' },
  );
  if (!choice) return;
  const target = await vscode.window.showSaveDialog({
    defaultUri: vscode.Uri.joinPath(document.uri, '..', `${name}.${choice.format}`),
    filters: { [choice.label]: [choice.format] },
    saveLabel: 'Export',
  });
  if (!target) return;
  const built = await build(options, {
    kupcad,
    document,
    output: target.fsPath,
    format: choice.format,
    title: `Exporting ${name} as ${choice.label}`,
  });
  if (!built) return;
  const chosen = await vscode.window.showInformationMessage(
    `Exported ${fileName(target)}.`,
    REVEAL,
  );
  if (chosen === REVEAL) await vscode.commands.executeCommand('revealFileInOS', target);
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
  if (document.uri.scheme !== FILE_SCHEME) {
    void vscode.window.showInformationMessage(
      `Save ${scriptName(document.uri)} to a file first: kupcad builds files.`,
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
      `${scriptName(document.uri)} has changes not saved, and kupcad builds the file: save it first?`,
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
 * @typedef {object} BuildRequest
 * @property {string} kupcad
 * @property {vscode.TextDocument} document
 * @property {string} output
 * @property {ExportFormat} format
 * @property {string} title the notification's
 */

/**
 * Builds the script to `output` with its values, a notification showing it (its cancel stops the
 * build): false when it failed (the user told why) or was stopped.
 * @param {CommandOptions} options
 * @param {BuildRequest} request
 */
function build(options, { kupcad, document, output, format, title }) {
  const script = document.uri.fsPath;
  const args = buildArguments(script, output, format, options.values.of(document.uri.toString()));
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
          `${scriptName(document.uri)} couldn't be built: ${errorText(error)}`,
        );
        return false;
      }
    },
  );
}
