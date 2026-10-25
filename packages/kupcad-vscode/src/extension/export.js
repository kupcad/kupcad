// Export: the script built by `kupcad build` with the values its parameters have in the viewer,
// so what is written is what the CLI builds. Free of the `vscode` import.

import { execFile } from 'node:child_process';

/** @import { ExportFormat, ParamValues } from '@kupcad/protocol/types' */
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
