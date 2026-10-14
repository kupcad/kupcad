//! Where a command reports: the process streams, or a test's buffer. Commands write
//! through it instead of printing directly, so their output can be checked in tests.

const std = @import("std");
const log_helpers = @import("../log.zig");
const Style = @import("diagnostic_report.zig").Style;

pub const Reporter = struct {
    io: std.Io,
    /// Set by tests: everything goes here, in order, uncoloured unless a style says otherwise.
    capture: ?*std.Io.Writer = null,
    /// The colours for what `out` and `err` write, each chosen for its own stream.
    out_style: Style = .plain,
    err_style: Style = .plain,

    /// The process streams, each coloured only if it is a terminal.
    pub fn forProcess(init: std.process.Init) Reporter {
        return .{
            .io = init.io,
            .out_style = Style.detect(init.io, std.Io.File.stdout(), init.environ_map),
            .err_style = Style.detect(init.io, std.Io.File.stderr(), init.environ_map),
        };
    }

    pub fn err(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.capture) |w| w.print(fmt, args) catch {} else log_helpers.printStderr(self.io, fmt, args);
    }

    pub fn out(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.capture) |w| w.print(fmt, args) catch {} else log_helpers.printStdout(self.io, fmt, args);
    }
};
