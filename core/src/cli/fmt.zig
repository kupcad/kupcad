const std = @import("std");
const api = @import("../api.zig");
const FmtConfig = @import("../tools/fmt/config.zig").Config;
const log_helpers = @import("../log.zig");
const walker = @import("walker.zig");
const Outcome = @import("outcome.zig").Outcome;

const FmtRun = struct {
    config: FmtConfig,
    failed: usize = 0,
};

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !Outcome {
    // CommandSetup has already reported what was wrong with the arguments or config.
    var setup = @import("options.zig").CommandSetup.init(allocator, init.io, args_iter, "fmt") catch return .failure;
    defer setup.deinit(allocator);

    var run: FmtRun = .{ .config = setup.config.fmt };
    run.failed += try walker.walkPaths(init.io, allocator, setup.options.paths.items, &run, processFile);
    return if (run.failed > 0) .failure else .success;
}

fn processFile(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, context: ?*anyopaque) anyerror!void {
    const run: *FmtRun = @ptrCast(@alignCast(context.?));

    const formatted = api.formatCode(allocator, source, run.config) catch |err| {
        log_helpers.printStderr(io, "Format failed for '{s}': {}\n", .{ file_path, err });
        run.failed += 1;
        return;
    };
    defer allocator.free(formatted);

    log_helpers.printStdout(io, "{s}", .{formatted});
}
