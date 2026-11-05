// Export: the script built by `kupcad build` with the values its parameters have in the viewer,
// so what is written is what the CLI builds. Free of the `vscode` import.

import { execFile } from 'node:child_process';
import { failureText, memoryLimitOptions, paramOptions } from '@kupcad/protocol';

/** @import { ExportFormat, ParamValues } from '@kupcad/protocol/types' */
/** What a build may say, at most: its log and why it failed. */
const MAX_OUTPUT_BYTES = 16 * 1024 * 1024;

/** Why `kupcad build` failed: what it said. */
export class BuildError extends Error {
  /** @param {string} message */
  constructor(message) {
    super(message);
    this.name = 'BuildError';
  }
}

/** How a failure is asked for: one JSON line last (`buildFailure`), the words before it. */
const ERRORS_OPTIONS = ['--errors', 'json'];

/**
 * `kupcad build`'s arguments: the script, the output in `format` (whatever its name's extension),
 * a `-p name=value` for each value (`paramOptions`), the memory limit, `memoryLimit` GB, and a
 * failure told as JSON.
 * @param {string} script
 * @param {string} output
 * @param {ExportFormat} format
 * @param {ParamValues} values
 * @param {number} memoryLimit
 * @returns {string[]}
 */
export function buildArguments(script, output, format, values, memoryLimit) {
  return [
    'build',
    script,
    '-o',
    output,
    '-f',
    format,
    ...paramOptions(values),
    ...memoryLimitOptions(memoryLimit),
    ...ERRORS_OPTIONS,
  ];
}

/**
 * Builds with the kupcad at `kupcad`, in the script's folder (where its imports are).
 * @param {string} kupcad
 * @param {string[]} args `buildArguments`'
 * @param {{ cwd: string, signal?: AbortSignal }} options
 * @returns {Promise<void>}
 * @throws {BuildError} saying what kupcad said (`@kupcad/protocol`'s `failureText`)
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
        reject(new BuildError(failureText(stderr, error.message)));
      },
    );
  });
}
