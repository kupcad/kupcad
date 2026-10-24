// Where the `kupcad` executable is: the `kupcad.serverPath` setting, `kupcad` on PATH, or the
// monorepo's dev build. Free of the `vscode` import, so it is tested without VS Code.

import * as fs from 'node:fs';
import * as path from 'node:path';

/** @param {string} p */
const isExecutable = (p) => {
  try {
    const st = fs.statSync(p);
    if (!st.isFile()) return false;
    if (process.platform === 'win32') return true;
    fs.accessSync(p, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
};

/**
 * Looks `name` up on PATH (adds PATHEXT suffixes on Windows).
 * @param {string} name
 * @param {NodeJS.ProcessEnv} [env]
 * @returns {string | undefined}
 */
export const findOnPath = (name, env = process.env) => {
  const dirs = (env.PATH || env.Path || '').split(path.delimiter).filter(Boolean);
  const exts = process.platform === 'win32' ? (env.PATHEXT || '.EXE;.CMD').split(';') : [''];
  for (const dir of dirs) {
    for (const ext of exts) {
      const candidate = path.join(dir, name + ext);
      if (isExecutable(candidate)) return candidate;
    }
  }
  return undefined;
};

/**
 * Server resolution order: explicit `kupcad.serverPath` setting, `kupcad` on PATH, then the
 * monorepo dev build (only exists when running the extension from a source checkout).
 * @param {{ configured: string | undefined, extensionPath: string, env?: NodeJS.ProcessEnv }} options
 * @returns {string | undefined}
 */
export const resolveServerPath = ({ configured, extensionPath, env = process.env }) => {
  if (configured) {
    const expanded = configured.replace(/^~(?=$|[\\/])/, env.HOME || env.USERPROFILE || '~');
    return isExecutable(expanded) ? expanded : undefined;
  }
  const onPath = findOnPath('kupcad', env);
  if (onPath) return onPath;
  const devPath = path.resolve(extensionPath, '../../core/zig-out/bin/kupcad');
  return isExecutable(devPath) ? devPath : undefined;
};
