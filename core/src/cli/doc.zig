const std = @import("std");
const api = @import("../api.zig");
const fs = @import("fs.zig");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const file_path = args_iter.next() orelse {
        std.debug.print("Error: Missing input file path.\n", .{});
        return;
    };

    const source = try fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE);
    defer allocator.free(source);

    var doc = try api.Document.parse(allocator, source);
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const schema = try api.extractSchema(arena.allocator(), &doc, source);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{f}\n", .{std.json.fmt(schema, .{ .whitespace = .indent_2 })});

    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(init.io, out.written());
}
