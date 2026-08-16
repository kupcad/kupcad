const std = @import("std");
const build_cmd = @import("cli/build_cmd.zig");
const fmt_cmd = @import("cli/fmt.zig");
const check_cmd = @import("cli/check.zig");
const lsp_cmd = @import("cli/lsp.zig");
const dev_cmd = @import("cli/dev.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);

    _ = args_iter.skip(); // Skip the executable name itself

    const cmd = args_iter.next() orelse {
        printUsage();
        return;
    };

    // Route to the appropriate CLI command module
    if (std.mem.eql(u8, cmd, "build")) {
        try build_cmd.execute(init, allocator, &args_iter);
    } else if (std.mem.eql(u8, cmd, "fmt")) {
        try fmt_cmd.execute(init, allocator, &args_iter);
    } else if (std.mem.eql(u8, cmd, "check")) {
        try check_cmd.execute(init, allocator, &args_iter);
    } else if (std.mem.eql(u8, cmd, "lsp")) {
        try lsp_cmd.execute(init, allocator);
    } else if (std.mem.eql(u8, cmd, "dev")) {
        try dev_cmd.execute(init, allocator, &args_iter);
    } else {
        std.debug.print("Error: Unknown command '{s}'\n\n", .{cmd});
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage: kupcad <command> [options]
        \\
        \\Commands:
        \\  build  Run a KupCAD script and export its final geometry
        \\  fmt    Format a KupCAD source file
        \\  check  Lint and analyze a KupCAD source file
        \\  lsp    Start the Language Server over stdio
        \\  dev    Developer tools and compiler debugging utilities
    , .{});
}
