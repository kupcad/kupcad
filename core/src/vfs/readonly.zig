//! `ReadOnlyVfs`: a VFS that reads through up to two layers and discards every write, for
//! the VMs the language server runs (cli/lsp.zig).

const std = @import("std");
const Vfs = @import("vfs.zig").Vfs;

const log = std.log.scoped(.vfs_readonly);

/// Read-only, layered VFS. Used for every VM the LSP runs (cli/lsp.zig).
/// The LSP evaluates untrusted documents just by opening them, so scripts must not be able to
/// write to disk (export_stl/gltf/step, makePath, links). Writes are silently discarded so
/// previews of scripts that export still render; reads go to the open editor buffers first and
/// then (optionally) to a jailed, read-only view of the workspace for imports.
pub const ReadOnlyVfs = struct {
    layers: [2]?Vfs = .{ null, null },
    discarded_writes: usize = 0,

    pub fn init(primary: ?Vfs, fallback: ?Vfs) ReadOnlyVfs {
        return .{ .layers = .{ primary, fallback } };
    }

    pub fn vfs(self: *ReadOnlyVfs) Vfs {
        return .{
            .ptr = self,
            .vtable = &.{
                .makePath = makePath,
                .readFile = readFile,
                .writeFile = writeFile,
                .symLink = symLink,
            },
        };
    }

    fn readFile(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
        const self: *ReadOnlyVfs = @ptrCast(@alignCast(ptr));
        var last_err: anyerror = error.FileNotFound;
        for (self.layers) |maybe_layer| {
            const layer = maybe_layer orelse continue;
            return layer.readFile(allocator, path) catch |err| {
                last_err = err;
                continue;
            };
        }
        return last_err;
    }

    fn discard(ptr: *anyopaque, path: []const u8) void {
        const self: *ReadOnlyVfs = @ptrCast(@alignCast(ptr));
        self.discarded_writes += 1;
        log.debug("LSP sandbox: discarded write to '{s}'", .{path});
    }

    fn makePath(ptr: *anyopaque, path: []const u8) anyerror!void {
        discard(ptr, path);
    }

    fn writeFile(ptr: *anyopaque, path: []const u8, data: []const u8) anyerror!void {
        _ = data;
        discard(ptr, path);
    }

    fn symLink(ptr: *anyopaque, target_path: []const u8, link_path: []const u8) anyerror!void {
        _ = target_path;
        discard(ptr, link_path);
    }
};
