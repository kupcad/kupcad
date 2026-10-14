//! Renders source diagnostics for the CLI: `file:line:col: E: message`, then the source
//! line and a caret underline. Shared by `kupcad check` and `kupcad build`, so a syntax
//! error reads the same whichever command finds it.

const std = @import("std");
const LineIndex = @import("../core/line_index.zig").LineIndex;
pub const Severity = @import("../tools/lint/linter.zig").LinterSeverity;

pub const Color = struct {
    pub const cyan = "\x1b[36m";
    pub const yellow = "\x1b[33m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const reset = "\x1b[0m";
};

pub const Report = struct {
    file_path: []const u8,
    source: []const u8,
    line_index: *const LineIndex,
    offset: u32,
    length: u32,
    severity: Severity,
    message: []const u8,
};

pub fn write(w: *std.Io.Writer, r: Report) std.Io.Writer.Error!void {
    const line = r.line_index.getLine(r.offset) + 1;
    const col = r.line_index.getUtf8Column(r.offset) + 1;
    const sev_color = r.severity.toColor();

    try w.print("{s}{s}:{d}:{d}:{s} {s}{s}:{s} {s}\n", .{ Color.cyan, r.file_path, line, col, Color.reset, sev_color, r.severity.toChar(), Color.reset, r.message });
    try w.print("{s}\n", .{sourceLine(r.source, line)});
    try w.splatByteAll(' ', col - 1);
    try w.writeAll(sev_color);
    try w.splatByteAll('^', if (r.length > 0) r.length else 1);
    try w.print("{s}\n\n", .{Color.reset});
}

/// The 1-based `target_line` of `source`, without its line ending ("" past the end).
pub fn sourceLine(source: []const u8, target_line: u32) []const u8 {
    var line_num: u32 = 1;
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| : (line_num += 1) {
        if (line_num == target_line) return std.mem.trimEnd(u8, line, "\r");
    }
    return "";
}
