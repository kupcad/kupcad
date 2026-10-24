// Versions as the core's releases name them (major.minor.patch, a pre-release after a hyphen:
// 0.2.0-rc.1), ordered as semver orders them, and the range of core versions the extension
// runs with (`>=0.1.0 <0.2.0`, its package.json's `kupcad.core`).

/**
 * @typedef {object} Version
 * @property {number} major
 * @property {number} minor
 * @property {number} patch
 * @property {(string | number)[]} pre the pre-release's identifiers; none for a release
 */

const VERSION = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/;
const COMPARATOR = /^(>=|<=|>|<|=)?(.+)$/;

/**
 * @param {string} text a version, a `v` before it allowed (a tag)
 * @returns {Version | null}
 */
export function parseVersion(text) {
  const match = VERSION.exec(text.trim());
  if (!match) return null;
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    pre: match[4] ? match[4].split('.').map((id) => (/^\d+$/.test(id) ? Number(id) : id)) : [],
  };
}

/**
 * Semver's order: by number, then a pre-release before its release, pre-releases by their
 * identifiers (a number before a word).
 * @param {Version} a
 * @param {Version} b
 * @returns {number} negative when `a` comes first, 0 when they are the same
 */
export function compareVersions(a, b) {
  for (const key of /** @type {const} */ (['major', 'minor', 'patch'])) {
    if (a[key] !== b[key]) return a[key] - b[key];
  }
  if (a.pre.length === 0 || b.pre.length === 0) return b.pre.length - a.pre.length;
  for (let i = 0; i < Math.min(a.pre.length, b.pre.length); i++) {
    const [x, y] = [a.pre[i], b.pre[i]];
    if (x === y) continue;
    if (typeof x === 'number' && typeof y === 'number') return x - y;
    if (typeof x === 'number') return -1;
    if (typeof y === 'number') return 1;
    return x < y ? -1 : 1;
  }
  return a.pre.length - b.pre.length;
}

/**
 * Whether `version` is in `range`: comparators (`>=0.1.0 <0.2.0`) it meets all of. A
 * pre-release is in it when the release it leads to is, so 0.2.0-rc.1 isn't taken for
 * `<0.2.0`.
 * @param {Version} version
 * @param {string} range
 * @returns {boolean}
 */
export function satisfies(version, range) {
  const release = { ...version, pre: [] };
  return range
    .trim()
    .split(/\s+/)
    .every((comparator) => {
      const [, op = '=', bound] = /** @type {RegExpExecArray} */ (COMPARATOR.exec(comparator));
      const limit = parseVersion(bound);
      if (!limit) throw new Error(`"${comparator}" is no version comparator`);
      const order = compareVersions(release, limit);
      switch (op) {
        case '>=':
          return order >= 0;
        case '>':
          return order > 0;
        case '<=':
          return order <= 0;
        case '<':
          return order < 0;
        default:
          return order === 0;
      }
    });
}

/** @param {Version} version */
export const formatVersion = ({ major, minor, patch, pre }) =>
  `${major}.${minor}.${patch}${pre.length > 0 ? `-${pre.join('.')}` : ''}`;
