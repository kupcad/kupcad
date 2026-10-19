//! Input validation for untrusted package metadata.
//!
//! Aliases, refs, hosts and ids come from kupcad.json / kupcad.lock files that may
//! originate from a downloaded (attacker-controlled) package. They end up in
//! filesystem paths (symlink names, store folders) and in request URLs, so they
//! are restricted to conservative charsets instead of being escaped ad hoc.

const std = @import("std");
const limits = @import("limits.zig");

pub const ValidationError = error{
    InvalidAlias,
    InvalidRef,
    InvalidPathSegment,
    InvalidHost,
    InvalidCommitSha,
};

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-';
}

/// Alias rule: [A-Za-z0-9_.-]{1,MAX_ALIAS_LEN}, no leading '.' or '-'.
/// A leading dot would let an alias shadow `.store` or be `..`; a leading dash
/// could be read as a CLI flag by tools that consume the workspace.
pub fn validateAlias(alias: []const u8) ValidationError!void {
    if (alias.len == 0 or alias.len > limits.MAX_ALIAS_LEN) return error.InvalidAlias;
    if (alias[0] == '.' or alias[0] == '-') return error.InvalidAlias;
    for (alias) |c| if (!isNameChar(c)) return error.InvalidAlias;
}

/// A single safe path component: [A-Za-z0-9_.-]+, never "." or "..".
/// Used for user/repo names, package ids and resolved commits that are joined into paths.
pub fn validatePathSegment(segment: []const u8) ValidationError!void {
    if (segment.len == 0 or segment.len > limits.MAX_HOST_LEN + 2 * limits.MAX_SEGMENT_LEN + 2) return error.InvalidPathSegment;
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidPathSegment;
    for (segment) |c| if (!isNameChar(c)) return error.InvalidPathSegment;
}

/// user / repo names inside a package URL.
pub fn validateRepoSegment(segment: []const u8) ValidationError!void {
    if (segment.len > limits.MAX_SEGMENT_LEN) return error.InvalidPathSegment;
    try validatePathSegment(segment);
}

/// Git ref (branch / tag / SHA). Restricting the charset (no ':', '?', '#', '%',
/// whitespace) prevents a ref from being reinterpreted as a URL or smuggling
/// query/path components into API requests.
pub fn validateRef(ref: []const u8) ValidationError!void {
    if (ref.len == 0 or ref.len > limits.MAX_REF_LEN) return error.InvalidRef;
    if (ref[0] == '/' or ref[0] == '-' or ref[0] == '.') return error.InvalidRef;
    if (ref[ref.len - 1] == '/') return error.InvalidRef;
    if (std.mem.find(u8, ref, "..") != null) return error.InvalidRef;
    if (std.mem.find(u8, ref, "//") != null) return error.InvalidRef;
    for (ref) |c| {
        if (!(isNameChar(c) or c == '/' or c == '+')) return error.InvalidRef;
    }
}

/// A version range after `@` (`^1.2`, `>=2.0.0`): an operator, then a version of digits and
/// dots, with an optional `v`. It is parsed, never put in a URL, but it is kept in
/// kupcad.lock and shown, so it gets a charset too.
pub fn validateRange(range: []const u8) ValidationError!void {
    if (range.len == 0 or range.len > limits.MAX_REF_LEN) return error.InvalidRef;
    for (range) |c| {
        if (!(std.ascii.isDigit(c) or std.mem.findScalar(u8, ".v^~>=", c) != null)) return error.InvalidRef;
    }
}

/// DNS hostname: [A-Za-z0-9.-], no ports, no userinfo, no IPv6 brackets.
pub fn validateHost(host: []const u8) ValidationError!void {
    if (host.len == 0 or host.len > limits.MAX_HOST_LEN) return error.InvalidHost;
    if (host[0] == '.' or host[0] == '-' or host[host.len - 1] == '.') return error.InvalidHost;
    if (std.mem.find(u8, host, "..") != null) return error.InvalidHost;
    for (host) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-')) return error.InvalidHost;
    }
}

/// Hosts a *transitive* dependency may never point at. A downloaded package must
/// not be able to make the installer issue requests to loopback / IP-literal
/// endpoints (SSRF against local services). Real registries have a dotted name
/// whose TLD starts with a letter; this rejects `localhost`, `127.0.0.1`,
/// `2130706433`, `0x7f000001`, single-label intranet names, etc.
/// (DNS names that *resolve* to private IPs are not caught here.)
pub fn isPublicRegistryHost(host: []const u8) bool {
    validateHost(host) catch return false;
    const last_dot = std.mem.findScalarLast(u8, host, '.') orelse return false;
    const tld = host[last_dot + 1 ..];
    if (tld.len == 0 or !std.ascii.isAlphabetic(tld[0])) return false;
    if (std.ascii.eqlIgnoreCase(tld, "localhost")) return false;
    return true;
}

/// Commit id returned by a provider API: 40 (SHA-1) or 64 (SHA-256) hex chars.
pub fn validateCommitSha(sha: []const u8) ValidationError!void {
    if (sha.len != 40 and sha.len != limits.MAX_COMMIT_LEN) return error.InvalidCommitSha;
    for (sha) |c| if (!std.ascii.isHex(c)) return error.InvalidCommitSha;
}
