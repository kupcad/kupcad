// The core's releases on GitHub: read from its API, an ETag saving the download when nothing
// changed, and the newest one the extension's range of core versions and its channel take.

import { compareVersions, formatVersion, parseVersion, satisfies } from './versions.js';

/** @import { Version } from './versions.js' */

/** The repository's releases, newest first: more than a range ever spans. */
export const RELEASES_URL = 'https://api.github.com/repos/kupcad/kupcad/releases?per_page=50';
/** Where a person installs one by hand. */
export const RELEASES_PAGE = 'https://github.com/kupcad/kupcad/releases';
/** Where the repository's release files are downloaded from: an asset elsewhere is none. */
export const RELEASE_DOWNLOADS = 'https://github.com/kupcad/kupcad/releases/download/';
const NOT_MODIFIED = 304;

/**
 * @typedef {object} Release
 * @property {string} version
 * @property {boolean} prerelease
 * @property {Record<string, string>} assets each file's download URL, by its name
 */

/**
 * @typedef {object} ReleaseList what was read, kept for the next read
 * @property {string | null} etag
 * @property {Release[]} releases
 */

/**
 * The releases the API lists (`GET /repos/{owner}/{repo}/releases`): published, tagged with a
 * version, their files those in the repository's release downloads (RELEASE_DOWNLOADS).
 * @param {unknown} json
 * @returns {Release[]}
 */
export function releasesOf(json) {
  if (!Array.isArray(json)) throw new Error('the releases are no list');
  return json.flatMap((release) => {
    const version = parseVersion(String(release?.tag_name ?? ''));
    if (!version || release.draft) return [];
    /** @type {Record<string, string>} */
    const assets = {};
    for (const asset of release.assets ?? []) {
      const url = String(asset?.browser_download_url ?? '');
      if (url.startsWith(RELEASE_DOWNLOADS)) assets[asset.name] = url;
    }
    return [{ version: formatVersion(version), prerelease: Boolean(release.prerelease), assets }];
  });
}

/**
 * The newest release whose version is in `range`; a pre-release only on the `prerelease` channel.
 * @param {Release[]} releases
 * @param {string} range
 * @param {{ prerelease: boolean }} channel
 * @returns {Release | null}
 */
export function newestInRange(releases, range, { prerelease }) {
  /** @type {{ release: Release, version: Version } | null} */
  let newest = null;
  for (const release of releases) {
    const version = /** @type {Version} */ (parseVersion(release.version));
    if (release.prerelease && !prerelease) continue;
    if (!satisfies(version, range)) continue;
    if (!newest || compareVersions(version, newest.version) > 0) newest = { release, version };
  }
  return newest?.release ?? null;
}

/**
 * The releases the API lists now: what `known` holds when they didn't change (its ETag).
 * @param {typeof fetch} get
 * @param {ReleaseList | null} known
 * @returns {Promise<ReleaseList>}
 */
export async function readReleases(get, known) {
  /** @type {Record<string, string>} */
  const headers = { Accept: 'application/vnd.github+json' };
  if (known?.etag) headers['If-None-Match'] = known.etag;
  const response = await get(RELEASES_URL, { headers });
  if (response.status === NOT_MODIFIED && known) return known;
  if (!response.ok) throw new Error(`GitHub answered ${response.status} for the releases`);
  return { etag: response.headers.get('etag'), releases: releasesOf(await response.json()) };
}
