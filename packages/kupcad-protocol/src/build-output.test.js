import { describe, expect, it } from 'vitest';
import { whyBuildFailed } from './build-output.js';

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
});
