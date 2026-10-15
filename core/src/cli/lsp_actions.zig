//! The editor's quick fixes (textDocument/codeAction), kept apart from the LSP types so
//! they can be tested: for each lint finding on the lines asked about, its fix (if it has
//! one) and an action that hides the finding with a suppression comment.

const std = @import("std");
const api = @import("../api.zig");

pub const Position = struct { line: u32, character: u32 };
pub const TextEdit = struct { start: Position, end: Position, text: []const u8 };

pub const Action = struct {
    title: []const u8,
    /// The fix keeps the model the same (what `check --fix` applies): editors run it on
    /// "fix all" and put it first.
    preferred: bool,
    edits: []const TextEdit,
};

/// Columns as the client counts them: UTF-8 bytes or UTF-16 code units (the LSP default).
pub const Encoding = enum { utf8, utf16 };

/// The actions for findings starting on lines `first_line` to `last_line` (0-based) of
/// `source`. Everything is allocated in `arena`.
pub fn actionsFor(arena: std.mem.Allocator, io: std.Io, source: []const u8, first_line: u32, last_line: u32, encoding: Encoding) ![]Action {
    const diags = try api.checkCode(arena, io, source, .{});
    const line_index = try api.LineIndex.init(arena, source);
    var actions: std.ArrayListUnmanaged(Action) = .empty;
    for (diags) |d| {
        const rule = d.rule orelse continue; // a syntax or compile error has no fix or suppression
        const line = line_index.getLine(d.loc.offset);
        if (line < first_line or line > last_line) continue;

        if (d.fix) |fix| {
            const edits = try arena.alloc(TextEdit, fix.edits.len);
            for (fix.edits, edits) |e, *out| out.* = .{
                .start = position(&line_index, e.offset, encoding),
                .end = position(&line_index, e.offset + e.length, encoding),
                .text = e.replacement,
            };
            try actions.append(arena, .{ .title = fix.title, .preferred = fix.safe, .edits = edits });
        }
        try actions.append(arena, try disableAction(arena, source, &line_index, line, rule));
    }
    return actions.toOwnedSlice(arena);
}

/// Inserts `# kupcad:disable-next-line <rule>` above the line, indented like it.
fn disableAction(arena: std.mem.Allocator, source: []const u8, line_index: *const api.LineIndex, line: u32, rule: []const u8) !Action {
    const start = line_index.line_starts[line];
    var indent_end = start;
    while (indent_end < source.len and (source[indent_end] == ' ' or source[indent_end] == '\t')) indent_end += 1;
    const at: Position = .{ .line = line, .character = 0 };
    const edits = try arena.alloc(TextEdit, 1);
    edits[0] = .{ .start = at, .end = at, .text = try std.fmt.allocPrint(arena, "{s}# kupcad:disable-next-line {s}\n", .{ source[start..indent_end], rule }) };
    return .{ .title = try std.fmt.allocPrint(arena, "Disable {s} for this line", .{rule}), .preferred = false, .edits = edits };
}

fn position(line_index: *const api.LineIndex, offset: u32, encoding: Encoding) Position {
    return .{
        .line = line_index.getLine(offset),
        .character = switch (encoding) {
            .utf8 => line_index.getUtf8Column(offset),
            .utf16 => line_index.getUtf16Column(offset),
        },
    };
}
