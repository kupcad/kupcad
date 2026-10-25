import { readFileSync } from 'node:fs';
import { describe, expect, it, vi } from 'vitest';
import {
  AttestationError,
  ATTESTATIONS_URL,
  sigstoreCheck,
  unsnappy,
  verifyAttested,
} from './attestation.js';

// A real attestation, as GitHub keeps it (Snappy): the GitHub CLI's release workflow's build
// provenance of its 2.103.2 archives, made by actions/attest-build-provenance as kupcad's
// release makes its own; and Sigstore's public trusted root then, as TUF gives it
const SNAPPED = new Uint8Array(
  readFileSync(new URL('fixtures/gh-provenance.json.sn', import.meta.url)),
);
const TRUSTED_ROOT = JSON.parse(
  readFileSync(new URL('fixtures/sigstore-trusted-root.json', import.meta.url), 'utf8'),
);
const BUNDLE = JSON.parse(new TextDecoder().decode(unsnappy(SNAPPED, 1 << 20)));
const GH_WORKFLOW = 'https://github.com/cli/cli/.github/workflows/deployment.yml@refs/heads/trunk';
/** The SHA-256 of gh_2.103.2_linux_amd64.tar.gz, one of the files it attests. */
const ATTESTED = '62ccf747115ddc61237efffdde66a3c8f70ba249433dc64f70801089b59c59c8';

/**
 * GitHub, serving the attestations of `listed` digests: their bundles kept apart, Snappy, as
 * GitHub keeps them.
 * @param {Record<string, unknown[]>} listed the API's attestations of each digest
 * @returns {typeof fetch}
 */
const github = (listed) => async (url) => {
  const at = String(url);
  if (at === 'https://blob.example/bundle.sn') return new Response(SNAPPED);
  const digest = at.startsWith(ATTESTATIONS_URL) ? at.slice(ATTESTATIONS_URL.length) : '';
  const attestations = listed[digest];
  if (!attestations) return new Response('{"message":"Not Found"}', { status: 404 });
  return Response.json({ attestations });
};
const KEPT_APART = [{ bundle: null, bundle_url: 'https://blob.example/bundle.sn' }];
/** A check every bundle passes. */
const passes = async () => {};
/** A check every bundle fails, as a forged one does. */
const forged = async () => {
  throw new Error('certificate identity error');
};

describe('attestation', () => {
  it("Sigstore's check takes a bundle its workflow signed, and no other workflow's", async () => {
    const check = sigstoreCheck({ trustedRoot: async () => TRUSTED_ROOT });
    await check(BUNDLE, GH_WORKFLOW);
    await expect(
      check(
        BUNDLE,
        'https://github.com/kupcad/kupcad/.github/workflows/release.yml@refs/tags/v2.103.2',
      ),
    ).rejects.toThrow(
      `certificate identity error - expected https://github.com/kupcad/kupcad/.github/workflows/release.yml@refs/tags/v2.103.2, got ${GH_WORKFLOW}`,
    );
  });

  it("finds a file's attestation by its digest, kept apart or not, and checks it for the tag's workflow", async () => {
    const check = vi.fn(async () => {});
    await verifyAttested(ATTESTED, '0.1.2', { get: github({ [ATTESTED]: KEPT_APART }), check });
    expect(check).toHaveBeenCalledWith(
      BUNDLE,
      'https://github.com/kupcad/kupcad/.github/workflows/release.yml@refs/tags/v0.1.2',
    );
    // A bundle the API gives whole
    await verifyAttested(ATTESTED, '0.1.2', {
      get: github({ [ATTESTED]: [{ bundle: BUNDLE }] }),
      check,
    });
    expect(check).toHaveBeenCalledTimes(2);
  });

  it('refuses a file with none, one for another file, or one that fails the check', async () => {
    const check = passes;
    await expect(verifyAttested(ATTESTED, '0.1.2', { get: github({}), check })).rejects.toThrow(
      new AttestationError("it has no attestation: kupcad's release workflow didn't build it"),
    );
    // Listed under this digest, but its statement names other files
    const other = 'f'.repeat(64);
    await expect(
      verifyAttested(other, '0.1.2', { get: github({ [other]: KEPT_APART }), check }),
    ).rejects.toThrow('it has no attestation of its build by https://github.com/kupcad/kupcad/');
    await expect(
      verifyAttested(ATTESTED, '0.1.2', { get: github({ [ATTESTED]: KEPT_APART }), check: forged }),
    ).rejects.toThrow("its attestation doesn't hold: certificate identity error");
  });

  it('unpacks Snappy as GitHub stores it, and refuses what is cut short, too long or no Snappy', () => {
    expect(new TextDecoder().decode(unsnappy(SNAPPED, 1 << 20)).slice(0, 13)).toBe('{"mediaType":');
    // A literal, then a copy that overlaps what it writes: "ab" then 6 more of it
    expect(
      new TextDecoder().decode(unsnappy(Uint8Array.of(8, 0x04, 0x61, 0x62, 0x09, 2), 64)),
    ).toBe('abababab');
    expect(() => unsnappy(SNAPPED.subarray(0, 100), 1 << 20)).toThrow(AttestationError);
    expect(() => unsnappy(SNAPPED, 100)).toThrow(/unpacks to \d+ bytes, past 100/);
    // A copy from before the start
    expect(() => unsnappy(Uint8Array.of(4, 0x01, 0x05), 64)).toThrow(AttestationError);
  });
});
