import { describe, expect, it } from 'vitest';
import { binaryOf, packageOf, platformKey, PLATFORMS } from './platforms.js';

/** A system, glibc's or not. @param {string} platform @param {string} arch */
const system = (platform, arch, glibc = true) => ({ platform, arch, glibc: () => glibc });

describe('the system kupcad runs on', () => {
  it.each([
    ['darwin', 'arm64', 'darwin-arm64'],
    ['darwin', 'x64', 'darwin-x64'],
    ['linux', 'arm64', 'linux-arm64'],
    ['linux', 'x64', 'linux-x64'],
    ['win32', 'arm64', 'win32-arm64'],
    ['win32', 'x64', 'win32-x64'],
  ])('%s %s has a build: %s', (platform, arch, key) => {
    expect(platformKey(system(platform, arch))).toBe(key);
  });

  it('has none for a system or a processor no build is made for', () => {
    expect(platformKey(system('freebsd', 'x64'))).toBeNull();
    expect(platformKey(system('linux', 'ia32'))).toBeNull();
  });

  it('has none on Linux with musl: the builds link glibc', () => {
    expect(platformKey(system('linux', 'x64', false))).toBeNull();
    // glibc matters on Linux alone
    expect(platformKey(system('darwin', 'arm64', false))).toBe('darwin-arm64');
  });

  it("names each system's package and its kupcad", () => {
    expect(packageOf('linux-x64')).toBe('@kupcad/cli-linux-x64');
    expect(binaryOf('win32')).toBe('kupcad.exe');
    expect(binaryOf('linux')).toBe('kupcad');
    // Each named as the release archives are
    expect(Object.values(PLATFORMS).map((platform) => platform.archive)).toEqual([
      'darwin_arm64',
      'darwin_amd64',
      'linux_arm64',
      'linux_amd64',
      'windows_arm64',
      'windows_amd64',
    ]);
  });
});
