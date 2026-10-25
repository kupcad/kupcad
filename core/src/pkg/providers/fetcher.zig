//! `Fetcher`: what the package manager asks of a package host: a ref's commit, the highest
//! tag that satisfies a version range (`resolveRange`), and the package's archive,
//! downloaded into the content-addressed store or opened from a local `file:` path.

const std = @import("std");
const provider = @import("provider.zig");
const cafs_mod = @import("../cafs.zig");
const Cafs = cafs_mod.Cafs;
const http_client = @import("../http_client.zig");
const limits = @import("../limits.zig");
const validate = @import("../validate.zig");
const semver = @import("../semver.zig");
const git_host = @import("git_host.zig");

/// Read buffer for the size-limited archive stream.
const ARCHIVE_READ_BUFFER_LEN = 64 * 1024;

pub const Fetcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    /// How long a request may receive nothing before it is abandoned (`http_client.watched`).
    stall: std.Io.Duration = http_client.STALL_TIMEOUT,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Fetcher {
        const client = std.http.Client{ .allocator = allocator, .io = io };
        return .{
            .allocator = allocator,
            .io = io,
            .client = client,
        };
    }

    pub fn deinit(self: *Fetcher) void {
        self.client.deinit();
    }

    /// Builds the commit-lookup API URL for git hosts. http/local packages have no
    /// commit API (error.NotApplicable) — the ref must never be treated as a URL.
    pub fn commitApiUrl(allocator: std.mem.Allocator, pkg: provider.ParsedPackage) ![]const u8 {
        const host = git_host.of(pkg.provider) orelse return error.NotApplicable;
        return host.commit_url(allocator, pkg);
    }

    pub fn fetchCommitSha(self: *Fetcher, pkg: provider.ParsedPackage) ![]const u8 {
        const url_str = try commitApiUrl(self.allocator, pkg);
        defer self.allocator.free(url_str);
        const body_bytes = try self.fetchApiBody(url_str);
        defer self.allocator.free(body_bytes);
        return parseCommitShaResponse(self.allocator, body_bytes);
    }

    /// The highest tag that satisfies the package's version range, from the host's tag
    /// list (at most MAX_TAG_PAGES pages). error.NoMatchingVersion if none does.
    pub fn resolveRange(self: *Fetcher, pkg: provider.ParsedPackage) !Release {
        const constraint = pkg.constraint.?;
        var best: ?Release = null;
        errdefer if (best) |*b| b.deinit(self.allocator);
        var page: usize = 1;
        while (page <= limits.MAX_TAG_PAGES) : (page += 1) {
            const url_str = try tagsApiUrl(self.allocator, pkg, page);
            defer self.allocator.free(url_str);
            const body_bytes = try self.fetchApiBody(url_str);
            defer self.allocator.free(body_bytes);
            // A page that isn't full is the last one.
            if (try pickRelease(self.allocator, body_bytes, constraint, &best) < tagsPageSize(pkg.provider)) break;
        }
        return best orelse error.NoMatchingVersion;
    }

    /// The tag list URL for git hosts (error.NotApplicable otherwise).
    pub fn tagsApiUrl(allocator: std.mem.Allocator, pkg: provider.ParsedPackage, page: usize) ![]const u8 {
        const host = git_host.of(pkg.provider) orelse return error.NotApplicable;
        return host.tags_url(allocator, pkg, page);
    }

    /// Only asked of a git host: resolveRange reaches here after tagsApiUrl took the package.
    fn tagsPageSize(provider_type: provider.ProviderType) usize {
        return git_host.of(provider_type).?.tags_page_size;
    }

    /// GETs a provider API URL and returns its (bounded) body; caller frees.
    fn fetchApiBody(self: *Fetcher, url_str: []const u8) ![]u8 {
        return http_client.watched(self.io, self.stall, readApiBody, .{ self, url_str });
    }

    fn readApiBody(self: *Fetcher, url_str: []const u8, received: *http_client.Received) ![]u8 {
        const get = try self.allocator.create(http_client.Get);
        defer self.allocator.destroy(get);
        var response = try get.send(&self.client, url_str);
        defer get.deinit();
        try checkStatus(response.head.status);

        var body: http_client.Counted = .init(response.reader(&.{}), received);
        // Bounded: a hostile host could otherwise stream an endless body into memory.
        return body.interface.allocRemaining(self.allocator, .limited(limits.MAX_API_RESPONSE_BYTES)) catch |err| switch (err) {
            error.StreamTooLong => error.ApiResponseTooLarge,
            else => err,
        };
    }

    /// Scans one page of a tag list (`[{"name": ..., "commit": {"sha" | "id": ...}}]`),
    /// keeping in `best` the highest tag whose version satisfies `constraint`; tags that
    /// aren't versions (`nightly`, `v2.0.0-rc1`) are skipped. Returns how many tags the page
    /// had. The body is the host's, so its shape and commits are validated, not trusted.
    pub fn pickRelease(allocator: std.mem.Allocator, body: []const u8, constraint: semver.Constraint, best: *?Release) !usize {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidApiResponse;
        defer parsed.deinit();
        if (parsed.value != .array) return error.InvalidApiResponse;
        const tags = parsed.value.array.items;
        for (tags) |tag| {
            if (tag != .object) return error.InvalidApiResponse;
            const name = tag.object.get("name") orelse return error.InvalidApiResponse;
            const commit = tag.object.get("commit") orelse return error.InvalidApiResponse;
            if (name != .string or commit != .object) return error.InvalidApiResponse;
            const sha = commit.object.get("sha") orelse commit.object.get("id") orelse return error.InvalidApiResponse;
            if (sha != .string) return error.InvalidApiResponse;
            validate.validateCommitSha(sha.string) catch return error.InvalidApiResponse;

            const version = semver.Version.parse(name.string) catch continue;
            if (!constraint.satisfies(version)) continue;
            if (best.*) |b| if (version.compare(b.version) != .gt) continue;

            const tag_name = try allocator.dupe(u8, name.string);
            errdefer allocator.free(tag_name);
            const commit_sha = try allocator.dupe(u8, sha.string);
            if (best.*) |*b| b.deinit(allocator);
            best.* = .{ .version = version, .tag = tag_name, .commit = commit_sha };
        }
        return tags.len;
    }

    /// Extracts the commit id from a provider API response. Accepts an object with
    /// `sha` (GitHub/Gitea) or `id` (GitLab), or an array whose first element is such
    /// an object. Shape and value are validated instead of trusted, since the body is
    /// attacker-controlled and the result is used in paths and URLs.
    pub fn parseCommitShaResponse(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidApiResponse;
        defer parsed.deinit();

        var value = parsed.value;
        if (value == .array) {
            if (value.array.items.len == 0) return error.InvalidApiResponse;
            value = value.array.items[0];
        }
        if (value != .object) return error.InvalidApiResponse;

        const sha_val = value.object.get("sha") orelse value.object.get("id") orelse return error.InvalidApiResponse;
        if (sha_val != .string) return error.InvalidApiResponse;
        validate.validateCommitSha(sha_val.string) catch return error.InvalidApiResponse;

        return allocator.dupe(u8, sha_val.string);
    }

    pub fn downloadArchive(self: *Fetcher, url_str: []const u8, cafs: *Cafs, layout: cafs_mod.ArchiveLayout) !cafs_mod.Archive {
        return http_client.watched(self.io, self.stall, readArchive, .{ self, url_str, cafs, layout });
    }

    fn readArchive(self: *Fetcher, url_str: []const u8, cafs: *Cafs, layout: cafs_mod.ArchiveLayout, received: *http_client.Received) !cafs_mod.Archive {
        const get = try self.allocator.create(http_client.Get);
        defer self.allocator.destroy(get);
        var response = try get.send(&self.client, url_str);
        defer get.deinit();
        try checkStatus(response.head.status);

        var body: http_client.Counted = .init(response.reader(&.{}), received);
        return extractLimited(self.allocator, &body.interface, cafs, layout);
    }

    /// Extracts a `file:` archive from the local filesystem (top-level deps only).
    pub fn openLocalArchive(self: *Fetcher, abs_path: []const u8, cafs: *Cafs) !cafs_mod.Archive {
        var file = try std.Io.Dir.cwd().openFile(self.io, abs_path, .{});
        defer file.close(self.io);
        var buf: [8192]u8 = undefined;
        var file_reader = file.reader(self.io, &buf);
        return extractLimited(self.allocator, &file_reader.interface, cafs, .flat);
    }
};

/// The tag a version range resolved to.
pub const Release = struct {
    version: semver.Version,
    /// The tag's name as the host has it (`v1.4.2`), owned.
    tag: []const u8,
    /// The tag's commit, owned.
    commit: []const u8,

    pub fn deinit(self: *Release, allocator: std.mem.Allocator) void {
        allocator.free(self.tag);
        allocator.free(self.commit);
    }
};

fn checkStatus(status: std.http.Status) !void {
    if (status == .forbidden or status == .too_many_requests) return error.RateLimitExceeded;
    if (status.class() != .success) return error.HttpError;
}

/// Caps the number of *compressed* bytes read before handing the stream to the
/// extractor (which separately caps decompressed bytes).
fn extractLimited(allocator: std.mem.Allocator, reader: *std.Io.Reader, cafs: *Cafs, layout: cafs_mod.ArchiveLayout) !cafs_mod.Archive {
    const buf = try allocator.alloc(u8, ARCHIVE_READ_BUFFER_LEN);
    defer allocator.free(buf);
    var limited: std.Io.Reader.Limited = .init(reader, .limited(limits.MAX_ARCHIVE_DOWNLOAD_BYTES), buf);
    return cafs.extractTarball(&limited.interface, layout) catch |err| {
        if (limited.remaining == .nothing) return error.ArchiveTooLarge;
        return err;
    };
}
