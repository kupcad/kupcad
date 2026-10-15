const std = @import("std");
const provider = @import("provider.zig");
const cafs_mod = @import("../cafs.zig");
const Cafs = cafs_mod.Cafs;
const http_client = @import("../http_client.zig");
const limits = @import("../limits.zig");
const validate = @import("../validate.zig");
const GithubProvider = @import("github.zig").GithubProvider;
const GitlabProvider = @import("gitlab.zig").GitlabProvider;
const GiteaProvider = @import("gitea.zig").GiteaProvider;

/// Read buffer for the size-limited archive stream.
const ARCHIVE_READ_BUFFER_LEN = 64 * 1024;

pub const Fetcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,

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
        return switch (pkg.provider) {
            .github => GithubProvider.formatApiUrl(allocator, pkg),
            .gitlab => GitlabProvider.formatApiUrl(allocator, pkg),
            .gitea => GiteaProvider.formatApiUrl(allocator, pkg),
            .http, .local => error.NotApplicable,
        };
    }

    pub fn fetchCommitSha(self: *Fetcher, pkg: provider.ParsedPackage) ![]const u8 {
        const url_str = try commitApiUrl(self.allocator, pkg);
        defer self.allocator.free(url_str);

        const get = try self.allocator.create(http_client.Get);
        defer self.allocator.destroy(get);
        var response = try get.send(&self.client, url_str);
        defer get.deinit();
        try checkStatus(response.head.status);

        // Bounded: a hostile host could otherwise stream an endless body into memory.
        const body_bytes = response.reader(&.{}).allocRemaining(self.allocator, .limited(limits.MAX_API_RESPONSE_BYTES)) catch |err| switch (err) {
            error.StreamTooLong => return error.ApiResponseTooLarge,
            else => return err,
        };
        defer self.allocator.free(body_bytes);

        return parseCommitShaResponse(self.allocator, body_bytes);
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
        const get = try self.allocator.create(http_client.Get);
        defer self.allocator.destroy(get);
        var response = try get.send(&self.client, url_str);
        defer get.deinit();
        try checkStatus(response.head.status);

        return extractLimited(self.allocator, response.reader(&.{}), cafs, layout);
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
