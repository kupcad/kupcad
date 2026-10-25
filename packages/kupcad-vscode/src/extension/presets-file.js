// A script's presets file (presets.js says what it holds), through VS Code's file system: read,
// a preset put in it, and watched, wherever the script is (in the workspace or not).

import * as vscode from 'vscode';
import { presetsPathOf, readPresets, writePresets } from '@kupcad/protocol';
import { fileName } from './scripts.js';

/** @import { ParamValues } from '@kupcad/protocol/types' */
/** @import { Presets } from '@kupcad/protocol/types' */

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export class PresetsFile {
  /** @param {vscode.Uri} script */
  constructor(script) {
    this.uri = script.with({ path: presetsPathOf(script.path) });
  }

  /** The file's name, which it is known by beside its script. */
  get name() {
    return fileName(this.uri);
  }

  /**
   * The presets in the file: none without one.
   * @returns {Promise<Presets>}
   * @throws {Error} for a file that can't be read, or read as presets
   */
  async read() {
    /** @type {Uint8Array} */
    let bytes;
    try {
      bytes = await vscode.workspace.fs.readFile(this.uri);
    } catch (error) {
      if (/** @type {{ code?: string }} */ (error).code === 'FileNotFound') return {};
      throw error;
    }
    return readPresets(decoder.decode(bytes));
  }

  /**
   * Puts `values` in the file as the preset `name`, replacing one of that name: the file is read
   * now, so what was written to it meanwhile is kept.
   * @param {string} name
   * @param {ParamValues} values
   */
  async put(name, values) {
    const presets = await this.read();
    await vscode.workspace.fs.writeFile(
      this.uri,
      encoder.encode(writePresets({ ...presets, [name]: values })),
    );
  }

  /**
   * Calls `changed` whenever the file is edited, made or removed.
   * @param {() => void} changed
   * @returns {vscode.Disposable}
   */
  watch(changed) {
    const folder = vscode.Uri.joinPath(this.uri, '..');
    const watcher = vscode.workspace.createFileSystemWatcher(
      new vscode.RelativePattern(folder, this.name),
    );
    return vscode.Disposable.from(
      watcher,
      watcher.onDidChange(changed),
      watcher.onDidCreate(changed),
      watcher.onDidDelete(changed),
    );
  }
}
