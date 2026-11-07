// What `kupcad` (bin/kupcad.js) does: finds the native kupcad npm installed for this system (the
// `kupcad` package's optional dependency for it) and runs it with the same arguments, its input,
// output and exit code the command's own.

import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { binaryOf, packageOf, platformKey, PLATFORMS } from './platforms.js';

/** Where the builds are, for a system with none. */
const RELEASES = 'https://github.com/kupcad/kupcad/releases';

/**
 * The path of the native kupcad installed for the system `key`, or why there is none.
 * @param {string | null} key the system's (platformKey's)
 * @param {(id: string) => string} resolve finds a package's file, as `require.resolve` does
 * @returns {{ path: string } | { problem: string }}
 */
export function nativeKupcad(key, resolve = createRequire(import.meta.url).resolve) {
  if (key === null) {
    return {
      problem:
        `kupcad has no build for this system (${process.platform} ${process.arch}` +
        `${process.platform === 'linux' ? ', which needs glibc' : ''}). ` +
        `The builds there are: ${Object.keys(PLATFORMS).join(', ')}. See ${RELEASES}`,
    };
  }
  const name = packageOf(key);
  try {
    const folder = dirname(resolve(`${name}/package.json`));
    return { path: join(folder, 'bin', binaryOf(PLATFORMS[key].os)) };
  } catch {
    return {
      problem:
        `${name}, kupcad for this system, isn't installed: npm installs it with kupcad unless ` +
        'optional dependencies are left out (--omit=optional, --no-optional). Install kupcad ' +
        'again with them.',
    };
  }
}

/**
 * Runs the native kupcad with `args`, and gives back its exit code (a signal that ended it is
 * sent on to this process, so it ends as kupcad did).
 * @param {string[]} args
 * @returns {number}
 */
export function launch(args) {
  const found = nativeKupcad(platformKey());
  if ('problem' in found) {
    console.error(found.problem);
    return 1;
  }
  const run = spawnSync(found.path, args, { stdio: 'inherit', windowsHide: false });
  if (run.error) {
    console.error(`kupcad couldn't run ${found.path}: ${run.error.message}`);
    return 1;
  }
  if (run.signal) process.kill(process.pid, run.signal);
  return run.status ?? 1;
}
