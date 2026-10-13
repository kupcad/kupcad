const std = @import("std");
const testing = std.testing;
const Cafs = @import("cafs.zig").Cafs;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

/// CAFS rooted in a fresh tmp dir, linking into an in-memory project VFS.
const Fixture = struct {
    tmp: testing.TmpDir,
    tmp_path: [:0]u8,
    mem_vfs: MemoryVfs,
    cafs: Cafs,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.tmp_path = try self.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(self.tmp_path);
        self.mem_vfs = MemoryVfs.init(testing.allocator);
        errdefer self.mem_vfs.deinit();
        self.cafs = try Cafs.init(testing.allocator, testing.io, self.tmp_path, self.mem_vfs.vfs());
    }

    fn deinit(self: *Fixture) void {
        self.cafs.deinit();
        self.mem_vfs.deinit();
        testing.allocator.free(self.tmp_path);
        self.tmp.cleanup();
    }

    fn writeBlob(self: *Fixture, hash: []const u8, data: []const u8) !void {
        const path = try self.cafs.blobPath(hash);
        defer testing.allocator.free(path);
        var f = try std.Io.Dir.cwd().createFile(testing.io, path, .{});
        defer f.close(testing.io);
        try f.writeStreamingAll(testing.io, data);
    }
};

test "Cafs: init creates the blob directory under the global dir" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var dir = try fx.tmp.dir.openDir(testing.io, "files", .{});
    dir.close(testing.io);
}

test "Cafs: blobPath generates correct absolute paths" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    const expected = try testing.allocator.print("{s}/files/deadbeef", .{fx.tmp_path});
    defer testing.allocator.free(expected);
    const actual = try fx.cafs.blobPath("deadbeef");
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "Cafs: linkBlob copies when the VFS cannot hard-link" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    try fx.writeBlob("112233445566", "cross device payload");
    try fx.cafs.linkBlob("112233445566", "virtual_file.txt");

    const content = try fx.mem_vfs.vfs().readFile(testing.allocator, "virtual_file.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("cross device payload", content);
}
