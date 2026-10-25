import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { BuildError, buildArguments, runBuild, whyItFailed } from './export.js';

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

  it("isn't taken in by the script's own output, before the error", () => {
    const noisy =
      "info(session_manager): Initialized\nhello\n[Warning] careful\nerror(vm): RuntimeError: boom\nerror(vm):     from script:3:8:in 'script'\nBuild failed: error.RuntimeError\n";
    expect(whyItFailed(noisy)).toBe('RuntimeError: boom');
    expect(whyItFailed("hello\nError: Unknown option '--bogus'\n\nUsage: kupcad build\n")).toBe(
      "Unknown option '--bogus'",
    );
    expect(whyItFailed('hello\nBuild failed: error.OutOfMemory\n')).toBe(
      'Build failed: error.OutOfMemory',
    );
    expect(whyItFailed('hello\n')).toBeNull();
  });
});
