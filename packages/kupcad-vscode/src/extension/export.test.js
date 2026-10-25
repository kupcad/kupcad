import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { BuildError, buildArguments, runBuild } from './export.js';

const POSIX = process.platform !== 'win32';

/** @type {string} */
let dir;
beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'kupcad-export-'));
});
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

/**
 * A stand-in for kupcad: a shell script with `body`.
 * @param {string} body
 */
function kupcad(body) {
  const file = path.join(dir, 'kupcad');
  fs.writeFileSync(file, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  return file;
}

describe('export', () => {
  it("builds the script to the output in the format picked, a -p for each of the viewer's values", () => {
    expect(
      buildArguments('/w/part.kup', '/w/part.stl', 'stl', {
        width: 40,
        hollow: true,
        label: 'A b=c',
        holes: [
          [0, 0],
          [10, 0],
        ],
      }),
    ).toEqual([
      'build',
      '/w/part.kup',
      '-o',
      '/w/part.stl',
      '-f',
      'stl',
      '-p',
      'width=40',
      '-p',
      'hollow=true',
      '-p',
      'label=A b=c',
      '-p',
      'holes=[[0,0],[10,0]]',
    ]);
    // A name without the format's extension is still written in it
    expect(buildArguments('/w/part.kup', '/w/part', '3mf', {})).toEqual([
      'build',
      '/w/part.kup',
      '-o',
      '/w/part',
      '-f',
      '3mf',
    ]);
  });

  it.runIf(POSIX)(
    'runs kupcad in the folder given, and says what it said when it failed, its log left out',
    async () => {
      const recorder = kupcad(`pwd > "${dir}/where"; echo "$@" > "${dir}/args"`);
      await runBuild(recorder, ['build', 'part.kup'], { cwd: os.tmpdir() });
      expect(fs.realpathSync(fs.readFileSync(path.join(dir, 'where'), 'utf8').trim())).toBe(
        fs.realpathSync(os.tmpdir()),
      );
      expect(fs.readFileSync(path.join(dir, 'args'), 'utf8').trim()).toBe('build part.kup');

      const failing = kupcad(
        'echo "info(session_manager): Initialized" >&2; echo "error(vm): RuntimeError: boom" >&2; exit 1',
      );
      await expect(runBuild(failing, [], { cwd: dir })).rejects.toThrow(
        new BuildError('RuntimeError: boom'),
      );
      const silent = kupcad('exit 2');
      await expect(runBuild(silent, [], { cwd: dir })).rejects.toThrow(/Command failed/);
    },
  );

  it.runIf(POSIX)('stops a build when its signal aborts', async () => {
    const slow = kupcad('sleep 5');
    const controller = new AbortController();
    const running = runBuild(slow, [], { cwd: dir, signal: controller.signal });
    controller.abort();
    await expect(running).rejects.toMatchObject({ name: 'AbortError' });
  });
});
