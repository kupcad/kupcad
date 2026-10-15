//! Renders source diagnostics for the CLI: `file:line:col: E: message`, then the source
//! line and a caret underline. Shared by `kupcad check`, `build` and `watch`, so a syntax
//! error reads the same whichever command finds it.

const std = @import("std");
const LineIndex = @import("../core/line_index.zig").LineIndex;
const Diagnostic = @import("../core/errors.zig").Diagnostic;
pub const Severity = @import("../tools/lint/linter.zig").LinterSeverity;

/// The colours CLI text is written in: ANSI escape codes on a terminal, nothing when the
/// stream is redirected or NO_COLOR is set (https://no-color.org), so logs and pipes get
/// plain text.
pub const Style = struct {
    cyan: []const u8 = "",
    yellow: []const u8 = "",
    red: []const u8 = "",
    green: []const u8 = "",
    reset: []const u8 = "",

    pub const plain: Style = .{};
    pub const ansi: Style = .{ .cyan = "\x1b[36m", .yellow = "\x1b[33m", .red = "\x1b[31m", .green = "\x1b[32m", .reset = "\x1b[0m" };

    /// The style for text written to `file`. CLICOLOR_FORCE keeps colours when redirected.
    pub fn detect(io: std.Io, file: std.Io.File, env: *const std.process.Environ.Map) Style {
        const mode = std.Io.Terminal.Mode.detect(io, file, isSet(env, "NO_COLOR"), isSet(env, "CLICOLOR_FORCE")) catch return plain;
        return if (mode == .escape_codes) ansi else plain;
    }

    pub fn severity(self: Style, s: Severity) []const u8 {
        return switch (s) {
            .@"error" => self.red,
            .warning => self.yellow,
            .info => self.cyan,
        };
    }

    /// Set and non-empty, as the NO_COLOR convention defines it.
    fn isSet(env: *const std.process.Environ.Map, name: []const u8) bool {
        const v = env.get(name) orelse return false;
        return v.len > 0;
    }
};

pub const Report = struct {
    file_path: []const u8,
    source: []const u8,
    line_index: *const LineIndex,
    offset: u32,
    length: u32,
    severity: Severity,
    message: []const u8,
    /// The lint rule that reported it, shown after the message (`[unused-variable]`).
    rule: ?[]const u8 = null,
};

pub fn write(w: *std.Io.Writer, r: Report, style: Style) std.Io.Writer.Error!void {
    const line = r.line_index.getLine(r.offset) + 1;
    const col = r.line_index.getUtf8Column(r.offset) + 1;
    const sev_color = style.severity(r.severity);

    try w.print("{s}{s}:{d}:{d}:{s} {s}{s}:{s} {s}", .{ style.cyan, r.file_path, line, col, style.reset, sev_color, r.severity.toChar(), style.reset, r.message });
    if (r.rule) |rule| try w.print(" [{s}]", .{rule});
    try w.writeAll("\n");
    try w.print("{s}\n", .{r.line_index.lineText(r.source, line - 1)});
    try w.splatByteAll(' ', col - 1);
    try w.writeAll(sev_color);
    try w.splatByteAll('^', if (r.length > 0) r.length else 1);
    try w.print("{s}\n\n", .{style.reset});
}

/// Writes `diagnostics` (syntax, resolver or compile errors in `source`) as errors and
/// returns how many there were.
pub fn writeErrors(w: *std.Io.Writer, allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, diagnostics: []const Diagnostic, style: Style) !usize {
    const line_index = try LineIndex.init(allocator, source);
    defer line_index.deinit(allocator);
    for (diagnostics) |d| {
        try write(w, .{
            .file_path = file_path,
            .source = source,
            .line_index = &line_index,
            .offset = d.loc.offset,
            .length = d.loc.length,
            .severity = .@"error",
            .message = d.message,
        }, style);
    }
    return diagnostics.len;
}
