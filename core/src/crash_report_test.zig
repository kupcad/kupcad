const std = @import("std");
const testing = std.testing;
const crash_report = @import("crash_report.zig");

test "crash report: the header names the version, platform, command and cause, nothing else" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try crash_report.formatHeader(&w, .{ .signal = .{ .name = "SEGV", .address = 0x10 } }, "build");
    const text = w.buffered();
    try testing.expect(std.mem.startsWith(u8, text, "KupCAD crash report\nversion: " ++ @import("build_info").version ++ "\n"));
    try testing.expect(std.mem.indexOf(u8, text, "\ncommand: build\n") != null);
    try testing.expect(std.mem.endsWith(u8, text, "signal: SIGSEGV at address 0x10\n"));

    w = .fixed(&buf);
    try crash_report.formatHeader(&w, .{ .signal = .{ .name = "ABRT", .address = null } }, "");
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\ncommand: (none)\n") != null);
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "signal: SIGABRT\n"));

    w = .fixed(&buf);
    try crash_report.formatHeader(&w, .{ .panic = "index out of bounds" }, "lsp");
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "panic: index out of bounds\n"));
}
