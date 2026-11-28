// Run a test block: the code lens the language server puts on a `test("name") do ... end`
// block (and the "Run all tests" one on the first) runs `kupcad test` on the script in a
// terminal, so its report reads as it does on the command line.

import * as path from 'node:path';
import * as vscode from 'vscode';
import { NOT_RUNNING } from './scripts.js';

/** The command the lenses carry, with `{ uri, name? }`: the name null runs the file's tests. */
export const RUN_TEST_COMMAND = 'kupcad.runTest';
/** The terminal the tests run in, one for all of them. */
export const TERMINAL_NAME = 'KupCAD tests';

/**
 * @typedef {object} TestCommandOptions
 * @property {() => string | null} kupcad the kupcad running now, or null
 * @property {vscode.LogOutputChannel} log
 */

/**
 * @param {TestCommandOptions} options
 * @returns {vscode.Disposable[]}
 */
export function registerTestCommands(options) {
  return [
    vscode.commands.registerCommand(RUN_TEST_COMMAND, (argument) =>
      runTest(options, argument).catch((error) => {
        void vscode.window.showErrorMessage(`The test run failed to start: ${String(error)}`);
      }),
    ),
  ];
}

/**
 * Runs the tests of the script at `argument.uri`, the one named `argument.name` alone when
 * given, in the tests terminal, saving the script first.
 * @param {TestCommandOptions} options
 * @param {{ uri: string, name?: string }} argument
 */
async function runTest(options, argument) {
  const kupcad = options.kupcad();
  if (!kupcad) {
    void vscode.window.showErrorMessage(NOT_RUNNING);
    return;
  }
  const uri = vscode.Uri.parse(argument.uri);
  const document = await vscode.workspace.openTextDocument(uri);
  if (document.isDirty && !(await document.save())) return;
  const command = testCommand(kupcad, uri.fsPath, argument.name);
  options.log.info(`Running ${command}`);
  const terminal =
    vscode.window.terminals.find((t) => t.name === TERMINAL_NAME) ??
    vscode.window.createTerminal({ name: TERMINAL_NAME, cwd: path.dirname(uri.fsPath) });
  terminal.show(true);
  terminal.sendText(command, true);
}

/**
 * The command line: `kupcad test <script> [--filter <name>]`, each part quoted for the shell.
 * @param {string} kupcad
 * @param {string} script
 * @param {string} [name]
 */
export function testCommand(kupcad, script, name) {
  const parts = [kupcad, 'test', script];
  if (name !== undefined) parts.push('--filter', name);
  return parts.map(quoted).join(' ');
}

/**
 * `part` as one word of a shell command: in single quotes on POSIX shells (nothing expands
 * in them), in double quotes on Windows, where a quote inside is doubled.
 * @param {string} part
 */
function quoted(part) {
  if (/^[\w./-]+$/.test(part)) return part;
  if (process.platform === 'win32') return `"${part.replaceAll('"', '""')}"`;
  return `'${part.replaceAll("'", "'\\''")}'`;
}
