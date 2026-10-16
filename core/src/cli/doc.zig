const std = @import("std");
const api = @import("../api.zig");
const fs = @import("fs.zig");
const log_helpers = @import("../log.zig");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;
pub const Outcome = @import("outcome.zig").Outcome;
const Args = @import("args.zig").Args;
const Reporter = @import("reporter.zig").Reporter;
const diagnostic_report = @import("diagnostic_report.zig");

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
    return run(allocator, file_path, .forProcess(init));
}

/// Prints the schema of the script at `file_path` as JSON. A script with syntax errors
/// gets them reported (as `kupcad check` does) and fails; it used to print the schema of
/// whatever parsed and exit 0.
pub fn run(allocator: std.mem.Allocator, file_path: []const u8, reporter: Reporter) !Outcome {
    const source = fs.readFileLimit(reporter.io, allocator, file_path, MAX_FILE_SIZE) catch |err| {
        reporter.err("Error: Could not read '{s}': {s}\n", .{ file_path, @errorName(err) });
        return .failure;
    };
    defer allocator.free(source);

    var doc = try api.Document.parse(allocator, source);
    defer doc.deinit();
    if (doc.diagnostics.len > 0) {
        var rendered: std.Io.Writer.Allocating = .init(allocator);
        defer rendered.deinit();
        const count = try diagnostic_report.writeErrors(&rendered.writer, allocator, file_path, source, doc.diagnostics, reporter.err_style);
        reporter.err("{s}No schema: {d} syntax error{s} in {s}\n", .{ rendered.written(), count, if (count == 1) "" else "s", file_path });
        return .failure;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const schema = try api.extractSchema(arena.allocator(), &doc, source);
    reporter.out("{f}\n", .{std.json.fmt(schema, .{ .whitespace = .indent_2 })});
    return .success;
}
