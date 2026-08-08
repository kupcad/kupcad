const std = @import("std");
const api = @import("../api.zig");
const ProjectConfig = @import("config.zig").ProjectConfig;
const FmtConfig = @import("../tools/fmt/config.zig").Config;
const CommandOptions = @import("options.zig").CommandOptions;
const walker = @import("walker.zig");

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    var setup = try @import("options.zig").CommandSetup.init(allocator, init.io, args_iter, "fmt");
    defer setup.deinit(allocator);

    try walker.walkPaths(init.io, allocator, setup.options.paths.items, @constCast(&setup.config.fmt), processFile);
}

fn processFile(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, context: ?*anyopaque) anyerror!void {
    _ = io;
    const fmt_config = @as(*FmtConfig, @ptrCast(@alignCast(context.?))).*;

    const formatted = api.formatCode(allocator, source, fmt_config) catch |err| {
        std.debug.print("Format failed for '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer allocator.free(formatted);

    std.debug.print("{s}", .{formatted});
}
