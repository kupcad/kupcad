const std = @import("std");
const provider = @import("provider.zig");
const Cafs = @import("../cafs.zig").Cafs;

pub const Fetcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Fetcher {
        return .{
            .allocator = allocator,
            .io = io,
            .client = .{
                .allocator = allocator,
                .io = io,
            },
        };
    }

    pub fn deinit(self: *Fetcher) void {
        self.client.deinit();
    }

    pub fn fetchCommitSha(self: *Fetcher, pkg: provider.ParsedPackage) ![]const u8 {
        var url_buf: [512]u8 = undefined;
        const url_str = if (std.mem.eql(u8, pkg.domain, "github.com"))
            try std.fmt.bufPrint(&url_buf, "https://api.github.com/repos/{s}/{s}/commits/{s}", .{ pkg.user, pkg.repo, pkg.ref })
        else
            pkg.ref;

        const uri = try std.Uri.parse(url_str);
        var req = try self.client.request(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "User-Agent", .value = "KupCAD/1.0" },
            },
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        if (response.head.status != .ok) return error.HttpError;

        const body_bytes = try response.reader(&.{}).allocRemaining(self.allocator, .unlimited);
        defer self.allocator.free(body_bytes);

        if (std.mem.eql(u8, pkg.domain, "github.com")) {
            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body_bytes, .{});
            defer parsed.deinit();
            if (parsed.value.object.get("sha")) |sha_val| {
                return try self.allocator.dupe(u8, sha_val.string);
            }
        }

        return try self.allocator.dupe(u8, pkg.ref);
    }

    pub fn downloadArchive(self: *Fetcher, url_str: []const u8, cafs: *Cafs) !std.StringHashMap([]const u8) {
        const uri = try std.Uri.parse(url_str);
        var req = try self.client.request(.GET, uri, .{
            .extra_headers = &.{
                .{ .name = "User-Agent", .value = "KupCAD/1.0" },
            },
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buf: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);
        if (response.head.status != .ok) return error.HttpError;

        const response_reader = response.reader(&.{});
        return try cafs.extractTarball(response_reader);
    }
};
