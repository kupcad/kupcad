//! Package manager resource limits.
//!
//! Every byte the package manager reads from the network or from a downloaded
//! archive is attacker-controlled, so all reads are bounded to keep a hostile
//! registry/mirror (or a gzip bomb) from exhausting memory or disk.

/// Max compressed bytes accepted for a single package archive download.
pub const MAX_ARCHIVE_DOWNLOAD_BYTES: usize = 256 * 1024 * 1024;

/// Max total decompressed bytes extracted from one archive (gzip-bomb guard).
pub const MAX_EXTRACTED_TOTAL_BYTES: u64 = 1024 * 1024 * 1024;

/// Max number of regular files accepted from one archive (inode-exhaustion guard).
pub const MAX_EXTRACTED_FILE_COUNT: usize = 50_000;

/// Max size of a JSON API response (commit lookup). Real responses are a few KiB.
pub const MAX_API_RESPONSE_BYTES: usize = 4 * 1024 * 1024;

/// Most pages of tags a version range is matched against (1000 tags on GitHub and GitLab).
pub const MAX_TAG_PAGES: usize = 10;

/// Max size of a package manifest (kupcad.json) or lockfile parsed from disk/CAFS.
pub const MAX_MANIFEST_BYTES: usize = 4 * 1024 * 1024;

/// Max size of a single CAFS blob copied through the non-hardlink fallback path.
pub const MAX_BLOB_COPY_BYTES: usize = MAX_EXTRACTED_TOTAL_BYTES;

/// Dependency alias: used verbatim as a symlink name under .kupcad/pkg/.
pub const MAX_ALIAS_LEN: usize = 64;

/// Git ref (branch/tag/SHA) length cap; git itself caps refnames well below this.
pub const MAX_REF_LEN: usize = 255;

/// user / repo path segment length cap (GitHub caps repo names at 100).
pub const MAX_SEGMENT_LEN: usize = 100;

/// DNS hostname length cap (RFC 1035).
pub const MAX_HOST_LEN: usize = 253;

/// Max length of a resolved commit id (SHA-1 = 40 hex, SHA-256 = 64 hex).
pub const MAX_COMMIT_LEN: usize = 64;
