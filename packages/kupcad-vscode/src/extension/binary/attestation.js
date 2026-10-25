// That a release's file is the one this repository's release workflow built from the release's
// tag: its attestation (actions/attest-build-provenance), found in GitHub's API by the file's
// SHA-256, is a SLSA provenance naming that digest, signed (a Sigstore bundle) by
// .github/workflows/release.yml at the tag. checksums.txt comes from the same release, so alone
// it catches a broken download, not a release replaced. The bundle is checked against
// Sigstore's trusted root, which TUF fetches and keeps beside the installs.

import { bundleFromJSON } from '@sigstore/bundle';
import { TrustedRoot } from '@sigstore/protobuf-specs';
import { getTrustedRoot } from '@sigstore/tuf';
import { toSignedEntity, toTrustMaterial, Verifier } from '@sigstore/verify';
import { errorText } from '@kupcad/protocol';

/** The repository's attestations of a file, by its SHA-256 (hex) appended. */
export const ATTESTATIONS_URL = 'https://api.github.com/repos/kupcad/kupcad/attestations/sha256:';
/** What signed a release's files: the release workflow, at the release's tag. */
const WORKFLOW = 'https://github.com/kupcad/kupcad/.github/workflows/release.yml';
/** Who vouched for the workflow: GitHub Actions' OIDC issuer. */
const ISSUER = 'https://token.actions.githubusercontent.com';
const IN_TOTO = 'application/vnd.in-toto+json';
const PROVENANCE = 'https://slsa.dev/provenance/v1';
/** The largest bundle read: one is a few kilobytes. */
const MAX_BUNDLE_BYTES = 1024 * 1024;

/** Why a file's attestation doesn't hold. */
export class AttestationError extends Error {
  /** @param {string} message */
  constructor(message) {
    super(message);
    this.name = 'AttestationError';
  }
}

/**
 * Checks a Sigstore bundle: signed by `identity` (a certificate's subject alternative name)
 * through GitHub Actions; throws when it isn't.
 * @typedef {(bundle: unknown, identity: string) => Promise<void>} BundleCheck
 */

/**
 * Checks that the file of SHA-256 `digest` (hex) is attested as built by the release workflow
 * at `v<version>`.
 * @param {string} digest
 * @param {string} version
 * @param {{ get: typeof fetch, check: BundleCheck }} options
 * @throws {AttestationError}
 */
export async function verifyAttested(digest, version, { get, check }) {
  const listed = await read(get, `${ATTESTATIONS_URL}${digest}`, 'its attestations');
  if (listed.status === 404) {
    throw new AttestationError("it has no attestation: kupcad's release workflow didn't build it");
  }
  const { attestations } = JSON.parse(new TextDecoder().decode(listed.bytes));
  const identity = `${WORKFLOW}@refs/tags/v${version}`;
  /** @type {string | null} */
  let why = null;
  for (const attestation of Array.isArray(attestations) ? attestations : []) {
    const bundle = attestation?.bundle ?? (await bundleAt(get, attestation?.bundle_url));
    if (!names(bundle, digest)) continue;
    try {
      await check(bundle, identity);
      return;
    } catch (error) {
      why = errorText(error);
    }
  }
  throw new AttestationError(
    why
      ? `its attestation doesn't hold: ${why}`
      : `it has no attestation of its build by ${identity}`,
  );
}

/**
 * The bundle at `url`, which GitHub keeps compressed (Snappy); null without one.
 * @param {typeof fetch} get
 * @param {unknown} url
 */
async function bundleAt(get, url) {
  if (typeof url !== 'string' || !url.startsWith('https://')) return null;
  const { bytes } = await read(get, url, 'its attestation');
  return JSON.parse(new TextDecoder().decode(unsnappy(bytes, MAX_BUNDLE_BYTES)));
}

/**
 * What `url` answers, read whole; a 404 is told, any other failure thrown.
 * @param {typeof fetch} get
 * @param {string} url
 * @param {string} what for the message
 */
async function read(get, url, what) {
  /** @type {Response} */
  let response;
  try {
    response = await get(url, { headers: { accept: 'application/vnd.github+json' } });
  } catch (error) {
    throw new AttestationError(`${what} couldn't be read: ${errorText(error)}`);
  }
  if (!response.ok && response.status !== 404) {
    throw new AttestationError(`${what} couldn't be read: GitHub answered ${response.status}`);
  }
  return { status: response.status, bytes: new Uint8Array(await response.arrayBuffer()) };
}

/**
 * Whether `bundle` holds a SLSA provenance (in-toto, in a DSSE envelope) naming `digest`: what
 * the signature then vouches for.
 * @param {any} bundle
 * @param {string} digest
 */
function names(bundle, digest) {
  const envelope = bundle?.dsseEnvelope;
  if (envelope?.payloadType !== IN_TOTO || typeof envelope.payload !== 'string') return false;
  try {
    const statement = JSON.parse(Buffer.from(envelope.payload, 'base64').toString('utf8'));
    return (
      statement?.predicateType === PROVENANCE &&
      Array.isArray(statement.subject) &&
      statement.subject.some((/** @type {any} */ s) => s?.digest?.sha256 === digest)
    );
  } catch {
    return false;
  }
}

/**
 * Sigstore's check of a bundle: its certificate chains to Sigstore's (public good) authority,
 * its signature is in the transparency log, and the certificate is `identity`'s through GitHub
 * Actions. The trusted root is read once, through TUF, kept in `cachePath`; or given, as JSON.
 * @param {{ cachePath?: string, trustedRoot?: () => Promise<unknown> }} options
 * @returns {BundleCheck}
 */
export function sigstoreCheck({
  cachePath,
  trustedRoot = () => getTrustedRoot({ cachePath }).then((root) => TrustedRoot.toJSON(root)),
}) {
  /** @type {Promise<Verifier> | null} */
  let verifier = null;
  return async (bundle, identity) => {
    verifier ??= trustedRoot().then(
      (root) => new Verifier(toTrustMaterial(TrustedRoot.fromJSON(root))),
    );
    const entity = toSignedEntity(bundleFromJSON(bundle));
    (await verifier).verify(entity, {
      subjectAlternativeName: identity,
      extensions: { issuer: ISSUER },
    });
  };
}

/**
 * The bytes Snappy compressed into `input` (its block format, as GitHub stores a bundle): a
 * varint of their length, then literals and copies of what came before. At most `max` bytes.
 * @param {Uint8Array} input
 * @param {number} max
 * @returns {Uint8Array}
 */
export function unsnappy(input, max) {
  let at = 0;
  let length = 0;
  for (let shift = 0; ; shift += 7) {
    if (at >= input.length || shift > 28) throw new AttestationError('a bundle is no Snappy data');
    const byte = input[at++];
    length += (byte & 0x7f) * 2 ** shift;
    if (byte < 0x80) break;
  }
  if (length > max) throw new AttestationError(`a bundle unpacks to ${length} bytes, past ${max}`);
  const out = new Uint8Array(length);
  let written = 0;
  const fail = () => new AttestationError('a bundle is no Snappy data');
  /** @param {number} n */
  const littleEndian = (n) => {
    if (at + n > input.length) throw fail();
    let value = 0;
    for (let i = 0; i < n; i++) value += input[at + i] * 2 ** (8 * i);
    at += n;
    return value;
  };
  while (at < input.length) {
    const tag = input[at++];
    if ((tag & 3) === 0) {
      // A literal: its length in the tag, or in the 1 to 4 bytes after it
      let size = tag >> 2;
      size = size < 60 ? size + 1 : littleEndian(size - 59) + 1;
      if (at + size > input.length || written + size > length) throw fail();
      out.set(input.subarray(at, at + size), written);
      at += size;
      written += size;
      continue;
    }
    // A copy of `size` bytes from `offset` back
    let size;
    let offset;
    if ((tag & 3) === 1) {
      size = ((tag >> 2) & 7) + 4;
      offset = ((tag >> 5) << 8) | littleEndian(1);
    } else {
      size = (tag >> 2) + 1;
      offset = littleEndian((tag & 3) === 2 ? 2 : 4);
    }
    if (offset === 0 || offset > written || written + size > length) throw fail();
    // Byte by byte: a copy may overlap what it writes (a run)
    for (let i = 0; i < size; i++) out[written + i] = out[written - offset + i];
    written += size;
  }
  if (written !== length) throw fail();
  return out;
}
