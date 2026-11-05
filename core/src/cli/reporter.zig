//! Where a command reports: the process streams, or a test's buffer. Commands write
//! through it instead of printing directly, so their output can be checked in tests.

const std = @import("std");
const log_helpers = @import("../log.zig");
const Style = @import("diagnostic_report.zig").Style;
const json_text = @import("../core/json_text.zig");

/// `one` for a count of 1, else `many`: "1 error", "2 errors" (summaries said "1 errors"
/// and "1 file(s)").
pub fn plural(n: usize, comptime one: []const u8, comptime many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

/// How a command tells a host why it failed (`--errors`): in words alone, or with one JSON
/// line last, which the host reads instead of its words (the desktop app and the VS Code
/// extension parsed the words, and a wording changed under them).
pub const ErrorsFormat = enum { text, json };

/// Why a command failed, for a host: what kind of failure (`settings`, `read`, `syntax`,
/// `compile`, `runtime`, `export`, `write`), its message as the words say it, and where.
pub const Failure = struct {
    kind: []const u8,
    message: []const u8,
    file: ?[]const u8 = null,
    line: ?u32 = null,
    column: ?u32 = null,
};

pub const Reporter = struct {
    io: std.Io,
    /// Set by tests: everything goes here, in order, uncoloured unless a style says otherwise.
    capture: ?*std.Io.Writer = null,
    /// The colours for what `out` and `err` write, each chosen for its own stream.
    out_style: Style = .plain,
    err_style: Style = .plain,
    /// How `fail` tells a host, besides the words `err` wrote.
    errors: ErrorsFormat = .text,

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

    /// Tells a host why the command failed, after the words `err` wrote about it: one line of
    /// JSON on stderr, `{"error": {...}}`, when `errors` is json; nothing otherwise.
    pub fn fail(self: Reporter, failure: Failure) void {
        if (self.errors != .json) return;
        self.err("{f}\n", .{json_text.fmt(.{ .@"error" = failure }, .{})});
    }
};
