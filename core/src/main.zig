const std = @import("std");
const build_cmd = @import("cli/build_cmd.zig");
const fmt_cmd = @import("cli/fmt.zig");
const check_cmd = @import("cli/check.zig");
const lsp_cmd = @import("cli/lsp.zig");
const doc_cmd = @import("cli/doc.zig");
const pkg_cmd = @import("cli/pkg_cmd.zig");
const dev_cmd = @import("cli/dev.zig");
const watch_cmd = @import("cli/watch.zig");
const log_helpers = @import("log.zig");

// Export std_options for the compiler
pub const std_options = log_helpers.std_options;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);

    _ = args_iter.skip(); // Skip the executable name itself

    const cmd = args_iter.next() orelse {
        printUsage(init.io);
        return;
    };

    // Route to the appropriate CLI command module
    if (std.mem.eql(u8, cmd, "build")) {
        try build_cmd.execute(init, allocator, &args_iter);
    } else if (std.mem.eql(u8, cmd, "watch")) {
        try watch_cmd.execute(init, allocator, &args_iter);
    } else if (std.mem.eql(u8, cmd, "pkg")) {
        try pkg_cmd.execute(init, allocator, &args_iter);
    } else if (std.mem.eql(u8, cmd, "fmt")) {
        try fmt_cmd.execute(init, allocator, &args_iter);
    } else if (std.mem.eql(u8, cmd, "check")) {
        try check_cmd.execute(init, allocator, &args_iter);
    } else if (std.mem.eql(u8, cmd, "lsp")) {
        try lsp_cmd.execute(init, allocator);
    } else if (std.mem.eql(u8, cmd, "doc")) {
        try doc_cmd.execute(init, allocator, &args_iter);
    } else if (std.mem.eql(u8, cmd, "dev")) {
        try dev_cmd.execute(init, allocator, &args_iter);
    } else {
        log_helpers.printStderr(init.io, "Error: Unknown command '{s}'\n\n", .{cmd});
        printUsage(init.io);
        std.process.exit(1);
    }
}

fn printUsage(io: std.Io) void {
    log_helpers.printStderr(io,
        \\Usage: kupcad <command> [options]
        \\
        \\Commands:
        \\  build  Run a KupCAD script and export its final geometry
        \\  fmt    Format a KupCAD source file
        \\  check  Lint and analyze a KupCAD source file
        \\  lsp    Start the Language Server over stdio
        \\  dev    Developer tools and compiler debugging utilities
        \\  doc    Extract parameter metadata and docstrings as JSON
        \\
    , .{});
}
