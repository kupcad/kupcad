const std = @import("std");
const api = @import("../api.zig");
const walker = @import("walker.zig");

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    var setup = try @import("options.zig").CommandSetup.init(allocator, init.io, args_iter, "doc");
    defer setup.deinit(allocator);

    try walker.walkPaths(init.io, allocator, setup.options.paths.items, null, processFile);
}

fn processFile(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, context: ?*anyopaque) anyerror!void {
    _ = context;

    var doc = api.Document.parse(allocator, source) catch |err| {
        std.debug.print("Parse failed for '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer doc.deinit();

    const params = api.extractParameters(allocator, &doc) catch |err| {
        std.debug.print("Parameter extraction failed for '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer allocator.free(params);

    const stdout = std.Io.File.stdout();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print("{f}", .{std.json.fmt(params, .{ .whitespace = .indent_2 })});
    try out.writer.writeByte('\n');
    try stdout.writeStreamingAll(io, out.written());
}
