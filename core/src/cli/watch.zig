const std = @import("std");
const Watcher = @import("../daemon/watcher.zig").Watcher;
const fs = @import("fs.zig");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;
const SessionManager = @import("../daemon/session_manager.zig").SessionManager;
const debug = @import("../stdlib/debug.zig");
const Outcome = @import("outcome.zig").Outcome;
const log_helpers = @import("../log.zig");
const diagnostic_report = @import("diagnostic_report.zig");
const Args = @import("args.zig").Args;

pub const USAGE =
    \\Usage: kupcad watch <file.kup>
    \\
    \\Builds a script, then rebuilds it whenever it or a module it imports changes.
    \\
;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    const file_path = args_iter.next() orelse {
        log_helpers.printStderr(init.io, "Error: Missing input file path.\n\n" ++ USAGE, .{});
        return .failure;
    };

    // Spin up the cache controller
    var manager = SessionManager.init(allocator, init.io, 1);
    defer manager.deinit();

    // Pin the session: the watcher holds this pointer for the life of the process.
    const lease = try manager.acquireSession(file_path);
    defer manager.release(lease);
    const session = lease.session;
    session.vm.debugger_handler = debug.terminalDebugger(init.io);

    const source = fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE) catch |err| {
        log_helpers.printStderr(init.io, "Error: Could not read '{s}': {s}\n", .{ file_path, @errorName(err) });
        return .failure;
    };
    defer allocator.free(source);

    _ = try session.workspace.addModule(file_path, source);
    try session.workspace.linkDependencies();
    try session.buildReverseGraph();

    // Perform initial cold-boot evaluation
    session.evaluateWorkspace() catch |err| {
        if (err == error.ParseError or err == error.CompileError) if (session.failure) |*failure| {
            const mod = &session.workspace.modules.items[@backingInt(failure.module)];
            var rendered: std.Io.Writer.Allocating = .init(allocator);
            defer rendered.deinit();
            const style = diagnostic_report.Style.detect(init.io, std.Io.File.stderr(), init.environ_map);
            _ = try diagnostic_report.writeErrors(&rendered.writer, allocator, mod.path, mod.source, failure.diagnostics, style);
            log_helpers.printStderr(init.io, "{s}", .{rendered.written()});
            return .failure;
        };
        log_helpers.printStderr(init.io, "Error: Initial build failed: {s}\n", .{@errorName(err)});
        return .failure;
    };

    // Initialize and block on the libxev event loop using the persistent session
    var watcher = try Watcher.init(session, file_path, init.io);
    defer watcher.deinit();

    try watcher.start();
    return .success;
}
