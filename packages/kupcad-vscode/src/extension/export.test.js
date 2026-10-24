import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  BuildError,
  buildArguments,
  FORMATS,
  printFile,
  runBuild,
  slicerCommand,
  startApart,
  whyItFailed,
} from './export.js';

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
  it('offers each format kupcad build writes, once', () => {
    expect(FORMATS.map((f) => f.format).toSorted()).toEqual([
      '3mf',
      'dxf',
      'glb',
      'gltf',
      'obj',
      'step',
      'stl',
      'svg',
    ]);
  });

  it("builds the script to the output, a -p for each of the viewer's values", () => {
    expect(
      buildArguments('/w/part.kup', '/w/part.stl', { width: 40, hollow: true, label: 'A b=c' }),
    ).toEqual([
      'build',
      '/w/part.kup',
      '-o',
      '/w/part.stl',
      '-p',
      'width=40',
      '-p',
      'hollow=true',
      '-p',
      'label=A b=c',
    ]);
    expect(buildArguments('/w/part.kup', '/w/part.stl', {})).toEqual([
      'build',
      '/w/part.kup',
      '-o',
      '/w/part.stl',
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

describe('whyItFailed', () => {
  it('says the first line of why, as kupcad build writes it, not its log, backtrace or summary', () => {
    const runtime =
      "info(session_manager): Initialized new session for /w/bad.kup\nerror(vm): RuntimeError: too thin\nerror(vm):     from script:1:8:in 'script'\nBuild failed: error.RuntimeError\n";
    expect(whyItFailed(runtime)).toBe('RuntimeError: too thin');
    const syntax =
      "info(session_manager): Initialized\n/w/bad.kup:2:1: E: Invalid expression starting with '' [invalid-expression]\n\n^\n\nBuild failed: 1 error in /w/bad.kup\n";
    expect(whyItFailed(syntax)).toBe(
      "/w/bad.kup:2:1: E: Invalid expression starting with '' [invalid-expression]",
    );
    expect(whyItFailed('info(x): only the log\n')).toBeNull();
  });
});

describe('print', () => {
  it("builds a 3MF of the script's name in the temporary folder's print folder", () => {
    expect(printFile('/tmp', '/w/parts/bracket.kup')).toBe(
      path.join('/tmp', 'kupcad-print', 'bracket.3mf'),
    );
  });

  it('opens it with the slicer the settings name: a macOS app by open -a, anything else run with it', () => {
    expect(slicerCommand('/Applications/PrusaSlicer.app', '/tmp/a.3mf', 'darwin')).toEqual({
      command: 'open',
      args: ['-a', '/Applications/PrusaSlicer.app', '/tmp/a.3mf'],
    });
    expect(slicerCommand('/usr/bin/prusa-slicer', '/tmp/a.3mf', 'linux')).toEqual({
      command: '/usr/bin/prusa-slicer',
      args: ['/tmp/a.3mf'],
    });
    expect(slicerCommand('C:\\Slicer\\slicer.exe', 'a.3mf', 'win32')).toEqual({
      command: 'C:\\Slicer\\slicer.exe',
      args: ['a.3mf'],
    });
  });

  it.runIf(POSIX)('starts a slicer apart, and says when it is none', async () => {
    const marker = path.join(dir, 'started');
    await startApart({ command: kupcad(`touch "${marker}"`), args: [] });
    await expect.poll(() => fs.existsSync(marker)).toBe(true);
    await expect(
      startApart({ command: path.join(dir, 'missing'), args: [] }),
    ).rejects.toMatchObject({ code: 'ENOENT' });
  });
});
