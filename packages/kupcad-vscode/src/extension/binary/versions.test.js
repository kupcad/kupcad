import { describe, expect, it } from 'vitest';
import { compareVersions, formatVersion, parseVersion, satisfies } from './versions.js';

/** @param {string} text */
const v = (text) => {
  const version = parseVersion(text);
  if (!version) throw new Error(`${text} is no version`);
  return version;
};

describe('parseVersion', () => {
  it('reads a release, a tag, a pre-release and build metadata', () => {
    expect(v('0.1.0')).toEqual({ major: 0, minor: 1, patch: 0, pre: [] });
    expect(v('v1.2.3')).toEqual({ major: 1, minor: 2, patch: 3, pre: [] });
    expect(v('0.2.0-rc.1')).toEqual({ major: 0, minor: 2, patch: 0, pre: ['rc', 1] });
    expect(v('0.2.0+build.5')).toEqual({ major: 0, minor: 2, patch: 0, pre: [] });
    expect(formatVersion(v('v0.2.0-rc.1'))).toBe('0.2.0-rc.1');
    for (const text of ['0.1', 'latest', '1.2.3.4', '01.2.3x'])
      expect(parseVersion(text)).toBeNull();
  });
});

describe('compareVersions', () => {
  it('orders as semver does: by number, a pre-release before its release', () => {
    const ordered = [
      '0.1.0',
      '0.1.1',
      '0.2.0-alpha',
      '0.2.0-alpha.1',
      '0.2.0-alpha.beta',
      '0.2.0-beta.2',
      '0.2.0-beta.11',
      '0.2.0-rc.1',
      '0.2.0',
      '1.0.0',
    ];
    const shuffled = ordered.toReversed();
    expect(shuffled.map(v).toSorted(compareVersions).map(formatVersion)).toEqual(ordered);
    expect(compareVersions(v('1.0.0'), v('v1.0.0'))).toBe(0);
  });
});

describe('satisfies', () => {
  it('meets every comparator of the range', () => {
    const range = '>=0.1.0 <0.2.0';
    expect(satisfies(v('0.1.0'), range)).toBe(true);
    expect(satisfies(v('0.1.9'), range)).toBe(true);
    expect(satisfies(v('0.2.0'), range)).toBe(false);
    expect(satisfies(v('0.0.9'), range)).toBe(false);
    expect(satisfies(v('1.0.0'), '1.0.0')).toBe(true);
    expect(satisfies(v('1.0.1'), '>1.0.0 <=1.0.1')).toBe(true);
  });

  it('takes a pre-release in when the release it leads to is', () => {
    const range = '>=0.1.0 <0.2.0';
    expect(satisfies(v('0.1.5-rc.1'), range)).toBe(true);
    expect(satisfies(v('0.2.0-rc.1'), range)).toBe(false);
  });

  it('refuses a range it cannot read', () => {
    expect(() => satisfies(v('0.1.0'), '>=one')).toThrow(/no version comparator/);
  });
});
