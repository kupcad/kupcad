import { describe, expect, it } from 'vitest';
import { newestInRange, readReleases, releasesOf, RELEASES_URL } from './releases.js';

/** A release as GitHub's API lists it. */
const listed = (/** @type {string} */ tag, /** @type {object} */ more = {}) => ({
  tag_name: tag,
  draft: false,
  prerelease: tag.includes('-'),
  assets: [
    {
      name: `kupcad_${tag.slice(1)}_linux_amd64.tar.gz`,
      browser_download_url: `https://example.com/${tag}.tar.gz`,
    },
  ],
  ...more,
});
const LISTED = [
  listed('v0.2.0'),
  listed('v0.1.3-rc.1'),
  listed('v0.1.2'),
  listed('v0.1.1'),
  listed('v0.1.4', { draft: true }),
  listed('nightly'),
];

describe('releases', () => {
  it('reads the published releases tagged with a version, their files by name', () => {
    const releases = releasesOf(LISTED);
    expect(releases.map((r) => r.version)).toEqual(['0.2.0', '0.1.3-rc.1', '0.1.2', '0.1.1']);
    expect(releases[2]).toEqual({
      version: '0.1.2',
      prerelease: false,
      assets: { 'kupcad_0.1.2_linux_amd64.tar.gz': 'https://example.com/v0.1.2.tar.gz' },
    });
    expect(() => releasesOf({ message: 'Not Found' })).toThrow(/no list/);
  });

  it('takes the newest in range, a pre-release only on its channel', () => {
    const releases = releasesOf(LISTED);
    expect(newestInRange(releases, '>=0.1.0 <0.2.0', { prerelease: false })?.version).toBe('0.1.2');
    expect(newestInRange(releases, '>=0.1.0 <0.2.0', { prerelease: true })?.version).toBe(
      '0.1.3-rc.1',
    );
    expect(newestInRange(releases, '>=0.3.0', { prerelease: true })).toBeNull();
  });

  it('reads them again only when they changed, by their ETag', async () => {
    /** @type {{ url: string, headers: Record<string, string> }[]} */
    const asked = [];
    /** @type {typeof fetch} */
    const get = async (url, init) => {
      const headers = /** @type {Record<string, string>} */ (init?.headers);
      asked.push({ url: String(url), headers });
      if (headers['If-None-Match'] === '"v1"') return new Response(null, { status: 304 });
      return Response.json(LISTED, { headers: { etag: '"v1"' } });
    };
    const first = await readReleases(get, null);
    expect(first.etag).toBe('"v1"');
    expect(await readReleases(get, first)).toBe(first);
    expect(asked.map((a) => [a.url, a.headers['If-None-Match']])).toEqual([
      [RELEASES_URL, undefined],
      [RELEASES_URL, '"v1"'],
    ]);
    await expect(readReleases(async () => new Response('', { status: 403 }), null)).rejects.toThrow(
      'GitHub answered 403',
    );
  });
});
