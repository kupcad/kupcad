// Export and print: the script built by `kupcad build` with the values its parameters have in the
// viewer, so what is written is what the CLI builds. Free of the `vscode` import.

import { execFile, spawn } from 'node:child_process';
import * as fs from 'node:fs/promises';
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
/** A print's folder, a new one under the system's temporary folder each time. */
export const PRINT_DIR_PREFIX = 'kupcad-print-';
/** What a print is built as: a slicer's format. */
export const PRINT_FORMAT = '3mf';
/** What a build may say, at most: its log and why it failed. */
const MAX_OUTPUT_BYTES = 16 * 1024 * 1024;
/**
 * The lines of a failed build that say why, best first, each giving its words: an error the run
 * raised (its log line), a syntax or compile error at its place, the CLI's refusal, its summary.
 * The script's own output (`puts`, a warning) is none of them.
 */
const WHY = [
  /^error\([^)]*\):\s*(.+)$/,
  /^(.+:\d+:\d+: E: .+)$/,
  /^Error: (.+)$/,
  /^(\w+ failed: .+)$/,
];

/** Why `kupcad build` failed: what it said. */
export class BuildError extends Error {
  /** @param {string} message */
  constructor(message) {
    super(message);
    this.name = 'BuildError';
  }
}

/**
 * `kupcad build`'s arguments: the script, the output in `format` (whatever its name's extension),
 * and a `-p name=value` for each value.
 * @param {string} script
 * @param {string} output
 * @param {ExportFormat} format
 * @param {ParamValues} values
 * @returns {string[]}
 */
export function buildArguments(script, output, format, values) {
  const params = Object.entries(values).flatMap(([name, value]) => ['-p', `${name}=${value}`]);
  return ['build', script, '-o', output, '-f', format, ...params];
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
 * What a failed build said of why (`WHY`'s first line found), or null when it said nothing that
 * does.
 * @param {string} stderr
 * @returns {string | null}
 */
export function whyItFailed(stderr) {
  const lines = stderr.split('\n').map((line) => line.trim());
  for (const pattern of WHY) {
    for (const line of lines) {
      const said = pattern.exec(line);
      if (said) return said[1];
    }
  }
  return null;
}

/**
 * Where a print named `name` is built: a 3MF in a folder of its own under `tmp`, made now, so no
 * other print (nor anyone else on the machine) writes there.
 * @param {string} tmp the system's temporary folder
 * @param {string} name
 * @returns {Promise<string>}
 */
export async function makePrintFile(tmp, name) {
  const dir = await fs.mkdtemp(path.join(tmp, PRINT_DIR_PREFIX));
  return path.join(dir, `${name}.${PRINT_FORMAT}`);
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
