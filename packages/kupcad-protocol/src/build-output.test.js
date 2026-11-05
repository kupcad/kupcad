import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { buildFailure, failureText, whyBuildFailed } from './build-output.js';

/** What `kupcad build bad.kup --errors json` wrote, captured (scripts/capture-fixtures.js). */
const FAILED = readFileSync(new URL('./fixtures/build-failed.txt', import.meta.url), 'utf8');

describe('buildFailure', () => {
  it('reads the JSON line a build asked with --errors json writes last, as the real kupcad writes it', () => {
    expect(buildFailure(FAILED)).toEqual({
      kind: 'runtime',
      message: "NameError: Undefined variable 'undefined_var'",
      file: 'bad.kup',
      line: 1,
      column: 5,
    });
    // The words stay for a person, before it
    expect(FAILED.startsWith('{')).toBe(false);
    expect(whyBuildFailed(FAILED)).toBe("NameError: Undefined variable 'undefined_var'");
  });

  it('takes the last such line, the fields it knows, and nothing that is not one', () => {
    expect(
      buildFailure(
        'log\n{"error":{"kind":"export","message":"empty","file":null}}\n{"error":{"kind":"write","message":"FileNotFound","file":"/o/p.stl","line":null,"column":null}}\n',
      ),
    ).toEqual({
      kind: 'write',
      message: 'FileNotFound',
      file: '/o/p.stl',
      line: null,
      column: null,
    });
    expect(buildFailure('{"error":{"kind":"runtime","message":"x","line":"2"}}')).toEqual({
      kind: 'runtime',
      message: 'x',
      file: null,
      line: null,
      column: null,
    });
    for (const none of [
      '',
      'error(vm): RuntimeError: x\n',
      '{"error":{"kind":"x"}}',
      '{"error": nope',
      '{"result": 1}',
    ]) {
      expect(buildFailure(none)).toBeNull();
    }
  });
});

describe('whyBuildFailed', () => {
  it('says the first line of why, as kupcad build writes it, not its log, backtrace or summary', () => {
    const runtime =
      "info(session_manager): Initialized new session for /w/bad.kup\nerror(vm): RuntimeError: too thin\nerror(vm):     from script:1:8:in 'script'\nBuild failed: error.RuntimeError\n";
    expect(whyBuildFailed(runtime)).toBe('RuntimeError: too thin');
    const syntax =
      "info(session_manager): Initialized\n/w/bad.kup:2:1: E: Invalid expression starting with '' [invalid-expression]\n\n^\n\nBuild failed: 1 error in /w/bad.kup\n";
    expect(whyBuildFailed(syntax)).toBe(
      "/w/bad.kup:2:1: E: Invalid expression starting with '' [invalid-expression]",
    );
    expect(whyBuildFailed('info(x): only the log\n')).toBeNull();
  });

  it("isn't taken in by the script's own output, before the error", () => {
    const noisy =
      "info(session_manager): Initialized\nhello\n[Warning] careful\nerror(vm): RuntimeError: boom\nerror(vm):     from script:3:8:in 'script'\nBuild failed: error.RuntimeError\n";
    expect(whyBuildFailed(noisy)).toBe('RuntimeError: boom');
    expect(whyBuildFailed("hello\nError: Unknown option '--bogus'\n\nUsage: kupcad build\n")).toBe(
      "Unknown option '--bogus'",
    );
    expect(whyBuildFailed('hello\nBuild failed: error.OutOfMemory\n')).toBe(
      'Build failed: error.OutOfMemory',
    );
    expect(whyBuildFailed('hello\n')).toBeNull();
  });

  it('reads each kind of line by its exact shape', () => {
    // A log line's words follow its first `)`, which a colon must follow
    expect(whyBuildFailed('error(vm):   RuntimeError: x\n')).toBe('RuntimeError: x');
    expect(whyBuildFailed('error(vm) RuntimeError: x\n')).toBeNull();
    expect(whyBuildFailed('error(v)m): x\n')).toBeNull();
    expect(whyBuildFailed('error(vm):   \n')).toBeNull();
    // A place is something, a colon, a line and a column, with words after it
    expect(whyBuildFailed('a.kup:12:3: E: Bad\n')).toBe('a.kup:12:3: E: Bad');
    expect(whyBuildFailed(':1:1: E: Bad\n')).toBeNull();
    expect(whyBuildFailed('a.kup:x:3: E: Bad\n')).toBeNull();
    expect(whyBuildFailed('a.kup:1:1: E: \n')).toBeNull();
    expect(whyBuildFailed('says: E: x then a.kup:4:5: E: Bad\n')).toBe(
      'says: E: x then a.kup:4:5: E: Bad',
    );
    // A summary is one word's
    expect(whyBuildFailed('two words failed: x\n')).toBeNull();
    expect(whyBuildFailed('Export failed: x\n')).toBe('Export failed: x');
  });

  it("reads a long line the script wrote in time linear in it, as a regular expression didn't", () => {
    // The old patterns backtracked quadratically on these: 40 000 characters took 0.8 s, so
    // these 400 000 would take over a minute, past the test's timeout
    const long = 400_000;
    expect(whyBuildFailed(`error(x): ${' '.repeat(long)}a\rb\n`)).toBe('a\rb');
    expect(whyBuildFailed(`${':1:1: E: '.repeat(long / 9)}\rx\n`)).toBe(
      `${':1:1: E: '.repeat(long / 9)}\rx`,
    );
    expect(whyBuildFailed(`${'1:'.repeat(long / 2)} failed:\n`)).toBeNull();
    expect(whyBuildFailed(`Build failed: ${'x'.repeat(long)}\n`)).toBe(
      `Build failed: ${'x'.repeat(long)}`,
    );
  });
});

describe('failureText', () => {
  it("says the JSON line's message, else the words, else what the host knows", () => {
    expect(failureText(FAILED, 'code 1')).toBe("NameError: Undefined variable 'undefined_var'");
    expect(failureText('error(vm): RuntimeError: too thin\n', 'code 1')).toBe(
      'RuntimeError: too thin',
    );
    expect(failureText('info(x): a log\n', 'kupcad ended (code 1)')).toBe('kupcad ended (code 1)');
  });
});
