import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { nativeKupcad } from './launch.js';

/** Where npm installed a package, as require.resolve finds it. @param {string} id */
const installed = (id) => `/lib/node_modules/${id}`;
/** A package npm didn't install. */
const missing = () => {
  throw new Error('Cannot find module');
};

describe('the native kupcad the command runs', () => {
  it("is its system's package's bin/kupcad", () => {
    expect(nativeKupcad('linux-x64', installed)).toEqual({
      path: join('/lib/node_modules/@kupcad/cli-linux-x64', 'bin', 'kupcad'),
    });
    expect(nativeKupcad('win32-x64', installed)).toEqual({
      path: join('/lib/node_modules/@kupcad/cli-win32-x64', 'bin', 'kupcad.exe'),
    });
  });

  it("says what to do where its system's package isn't installed", () => {
    const found = nativeKupcad('darwin-arm64', missing);
    expect(found).toMatchObject({ problem: expect.stringContaining('@kupcad/cli-darwin-arm64') });
    expect(found).toMatchObject({ problem: expect.stringContaining('--omit=optional') });
  });

  it('names the builds there are on a system with none', () => {
    const found = nativeKupcad(null);
    expect(found).toMatchObject({ problem: expect.stringContaining('darwin-arm64, darwin-x64') });
    expect(found).toMatchObject({ problem: expect.stringContaining('github.com/kupcad/kupcad') });
  });
});
