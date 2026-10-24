// Export and print: the script built by `kupcad build` with the values its parameters have in the
// viewer, so what is written is what the CLI builds. Free of the `vscode` import.

import { execFile, spawn } from 'node:child_process';
import * as path from 'node:path';

/** @import { ExportFormat, ParamValues } from '@kupcad/protocol/types' */

/**
 * @typedef {object} FormatChoice
 * @property {ExportFormat} format the file's extension too
 * @property {string} label
 * @property {string} detail what it is for
 */

/** The formats an export offers, in the order it offers them. @type {FormatChoice[]} */
export const FORMATS = [
  { format: 'stl', label: 'STL', detail: 'A mesh, for a slicer or any 3D tool' },
  {
    format: '3mf',
    label: '3MF',
    detail: 'A mesh with its parts, copies and colours, for a slicer',
  },
  { format: 'step', label: 'STEP', detail: 'Exact geometry, for CAD (the B-Rep engine)' },
  { format: 'glb', label: 'GLB', detail: 'Binary glTF, with its parts and colours, for the web' },
  { format: 'gltf', label: 'glTF', detail: 'glTF as JSON' },
  { format: 'obj', label: 'OBJ', detail: 'Wavefront OBJ, a part an object' },
  { format: 'svg', label: 'SVG', detail: 'A drawing on XY, for a laser cutter' },
  { format: 'dxf', label: 'DXF', detail: 'The drawing as DXF, for CAD and CNC' },
];
/** Where prints are built, under the system's temporary folder. */
export const PRINT_DIR = 'kupcad-print';
const PRINT_FORMAT = '3mf';
/** What a build may say, at most: its log and why it failed. */
const MAX_OUTPUT_BYTES = 16 * 1024 * 1024;
/** The log lines of a build, which aren't why it failed. */
const LOG_LINE = /^(info|debug)\(/;
/** What an error's line starts with in the log: its level and scope. */
const LOG_PREFIX = /^(error|warning)\([^)]*\):\s*/;

/** Why `kupcad build` failed: what it said. */
export class BuildError extends Error {
  /** @param {string} message */
  constructor(message) {
    super(message);
    this.name = 'BuildError';
  }
}

/**
 * `kupcad build`'s arguments: the script, the output, and a `-p name=value` for each value.
 * @param {string} script
 * @param {string} output its extension says the format
 * @param {ParamValues} values
 * @returns {string[]}
 */
export function buildArguments(script, output, values) {
  const params = Object.entries(values).flatMap(([name, value]) => ['-p', `${name}=${value}`]);
  return ['build', script, '-o', output, ...params];
}

/**
 * Builds with the kupcad at `kupcad`, in the script's folder (where its imports are).
 * @param {string} kupcad
 * @param {string[]} args `buildArguments`'
 * @param {{ cwd: string, signal?: AbortSignal }} options
 * @returns {Promise<void>}
 * @throws {BuildError} saying what kupcad said
 */
export function runBuild(kupcad, args, { cwd, signal }) {
  return new Promise((resolve, reject) => {
    execFile(
      kupcad,
      args,
      { cwd, signal, maxBuffer: MAX_OUTPUT_BYTES },
      (error, _stdout, stderr) => {
        if (!error) return resolve();
        if (error.name === 'AbortError') return reject(error);
        reject(new BuildError(whyItFailed(stderr) ?? error.message));
      },
    );
  });
}

/**
 * What a failed build said of why: its first line that isn't the log's (an error's level taken
 * off), not its backtrace nor the summary after it.
 * @param {string} stderr
 * @returns {string | null}
 */
export function whyItFailed(stderr) {
  for (const raw of stderr.split('\n')) {
    const line = raw.trim();
    if (!line || LOG_LINE.test(line)) continue;
    return line.replace(LOG_PREFIX, '');
  }
  return null;
}

/**
 * Where a print of `script` is built: a 3MF of its name in `tmp`'s print folder.
 * @param {string} tmp the system's temporary folder
 * @param {string} script
 */
export function printFile(tmp, script) {
  const name = path.basename(script).replace(/\.kup$/, '');
  return path.join(tmp, PRINT_DIR, `${name}.${PRINT_FORMAT}`);
}

/**
 * How the slicer the settings name opens `file`: a macOS app by `open -a`, anything else run
 * with the file.
 * @param {string} slicer
 * @param {string} file
 * @param {string} platform Node's `process.platform`
 * @returns {{ command: string, args: string[] }}
 */
export function slicerCommand(slicer, file, platform) {
  if (platform === 'darwin' && /\.app\/?$/.test(slicer))
    return { command: 'open', args: ['-a', slicer, file] };
  return { command: slicer, args: [file] };
}

/**
 * Starts `command`, left to run on its own (a slicer outlives the extension's call).
 * @param {{ command: string, args: string[] }} run
 * @returns {Promise<void>} once it started; rejected when it couldn't
 */
export function startApart({ command, args }) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { detached: true, stdio: 'ignore' });
    child.once('error', reject);
    child.once('spawn', () => {
      child.unref();
      resolve();
    });
  });
}
