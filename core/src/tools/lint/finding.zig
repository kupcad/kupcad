//! A finding of `kupcad check` placed in its source, in the one shape every host is given:
//! `check --format json` writes it with its file's `path`, the browser's `check_code_wasm`
//! without. Its JSON (`writeFields`) holds `line`, `column`, `endLine` and `endColumn`
//! (1-based, columns in UTF-8 bytes, as `check` prints them), `offset` and `length` (bytes
//! of the source, for an editor that counts from the start), `severity`, `rule` (null for a
//! syntax or compile error), `code`, `message`, and `fix`: its `title`, whether it is `safe`,
//! and its `edits`, each placed the same way and with its `text`; null without one.

const std = @import("std");
const LineIndex = @import("../../core/line_index.zig").LineIndex;
const LinterDiagnostic = @import("linter.zig").LinterDiagnostic;

/// A place in a source: its 1-based line, its 1-based column in UTF-8 bytes and in UTF-16
/// code units (SARIF's), and its byte offset.
pub const Position = struct {
    line: u32,
    column: u32,
    utf16_column: u32,
    offset: u32,

    pub fn at(line_index: *const LineIndex, offset: u32) Position {
        const pos = line_index.humanPosition(offset);
        return .{ .line = pos.line, .column = pos.column, .utf16_column = line_index.getUtf16Column(offset) + 1, .offset = offset };
    }
};

pub const Edit = struct { start: Position, end: Position, text: []const u8 };

pub const Fix = struct { title: []const u8, safe: bool, edits: []const Edit };

pub const Finding = struct {
    start: Position,
    end: Position,
    severity: []const u8,
    rule: ?[]const u8,
    code: []const u8,
    message: []const u8,
    fix: ?Fix,

    /// `diag` placed in the source `line_index` indexes, what it says copied into
    /// `allocator` (an arena: a finding is freed with the rest).
    pub fn place(allocator: std.mem.Allocator, line_index: *const LineIndex, diag: LinterDiagnostic) !Finding {
        var fix: ?Fix = null;
        if (diag.fix) |f| {
            const edits = try allocator.alloc(Edit, f.edits.len);
            for (f.edits, edits) |e, *out| out.* = .{
                .start = .at(line_index, e.offset),
                .end = .at(line_index, e.offset + e.length),
                .text = try allocator.dupe(u8, e.replacement),
            };
            fix = .{ .title = try allocator.dupe(u8, f.title), .safe = f.safe, .edits = edits };
        }
        return .{
            .start = .at(line_index, diag.loc.offset),
            .end = .at(line_index, diag.loc.offset + diag.loc.length),
            .severity = diag.severity.toString(),
            .rule = diag.ruleId(),
            .code = diag.code(),
            .message = try allocator.dupe(u8, diag.message),
            .fix = fix,
        };
    }

    /// The finding as a JSON object of its own.
    pub fn jsonStringify(self: Finding, jw: *std.json.Stringify) !void {
        try jw.beginObject();
        try self.writeFields(jw);
        try jw.endObject();
    }

    /// Its fields, into the JSON object `jw` has begun (one with a `path` before them).
    pub fn writeFields(self: Finding, jw: *std.json.Stringify) !void {
        try writeRange(jw, self.start, self.end);
        try field(jw, "severity", self.severity);
        try field(jw, "rule", self.rule);
        try field(jw, "code", self.code);
        try field(jw, "message", self.message);
        try jw.objectField("fix");
        const fix = self.fix orelse return jw.write(null);
        try jw.beginObject();
        try field(jw, "title", fix.title);
        try field(jw, "safe", fix.safe);
        try jw.objectField("edits");
        try jw.beginArray();
        for (fix.edits) |e| {
            try jw.beginObject();
            try writeRange(jw, e.start, e.end);
            try field(jw, "text", e.text);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
    }
};

/// `line`, `column`, `endLine`, `endColumn`, `offset` and `length` of the range from `start` to `end`.
fn writeRange(jw: *std.json.Stringify, start: Position, end: Position) !void {
    try field(jw, "line", start.line);
    try field(jw, "column", start.column);
    try field(jw, "endLine", end.line);
    try field(jw, "endColumn", end.column);
    try field(jw, "offset", start.offset);
    try field(jw, "length", end.offset - start.offset);
}

fn field(jw: *std.json.Stringify, name: []const u8, v: anytype) !void {
    try jw.objectField(name);
    try jw.write(v);
}
