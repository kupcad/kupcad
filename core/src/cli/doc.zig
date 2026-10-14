const std = @import("std");
const api = @import("../api.zig");
const fs = @import("fs.zig");
const log_helpers = @import("../log.zig");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;
const Outcome = @import("outcome.zig").Outcome;
const Args = @import("args.zig").Args;

pub const USAGE =
    \\Usage: kupcad doc <file.kup>
    \\
    \\Prints the script's parameters and docstrings as JSON.
    \\
;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    const file_path = args_iter.next() orelse {
        log_helpers.printStderr(init.io, "Error: Missing input file path.\n\n" ++ USAGE, .{});
        return .failure;
    };

    const source = fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE) catch |err| {
        log_helpers.printStderr(init.io, "Error: Could not read '{s}': {s}\n", .{ file_path, @errorName(err) });
        return .failure;
    };
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
    return .success;
}
