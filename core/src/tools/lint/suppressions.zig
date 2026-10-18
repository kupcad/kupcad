//! Inline suppressions: comments that hide lint findings.
//!
//!     # kupcad:disable-next-line unused-variable, self-subtraction -- why
//!     x = 1 # kupcad:disable-line unused-variable
//!     # kupcad:disable param-order          (the whole file)
//!
//! They name the rules they hide, and only lint findings can be hidden: a syntax or
//! compile error has no rule. A directive that hides nothing, or names a rule or a
//! directive that doesn't exist, is reported itself (as ESLint does), so stale ones don't
//! pile up.

const std = @import("std");
const token = @import("../../core/token.zig");
const LineIndex = @import("../../core/line_index.zig").LineIndex;
const linter = @import("linter.zig");
const Config = @import("config.zig").Config;
const Level = @import("config.zig").Level;

/// What findings about suppressions are reported under (they can't be suppressed).
pub const RULE = "suppression";

const PREFIX = "kupcad:";

const Scope = enum {
    next_line,
    line,
    file,

    fn fromName(name: []const u8) ?Scope {
        if (std.mem.eql(u8, name, "disable-next-line")) return .next_line;
        if (std.mem.eql(u8, name, "disable-line")) return .line;
        if (std.mem.eql(u8, name, "disable")) return .file;
        return null;
    }

    fn directive(self: Scope) []const u8 {
        return switch (self) {
            .next_line => "disable-next-line",
            .line => "disable-line",
            .file => "disable",
        };
    }
};

/// One rule a directive hides.
const Entry = struct {
    scope: Scope,
    rule: []const u8,
    /// The 0-based line it hides (unused for `.file`).
    line: u32,
    /// The directive comment, where problems with it are reported.
    loc: token.Location,
    used: bool = false,
};

/// Drops the lint findings in `diagnostics` that a directive in `comments` hides, then
/// appends a finding for each directive that is wrong or hid nothing. Findings own their
/// messages (allocated with `allocator`).
pub fn apply(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(linter.LinterDiagnostic),
    comments: []const token.Comment,
    line_index: *const LineIndex,
    config: Config,
) !void {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer entries.deinit(allocator);
    var problems: std.ArrayListUnmanaged(linter.LinterDiagnostic) = .empty;
    defer {
        for (problems.items) |p| p.deinit(allocator);
        problems.deinit(allocator);
    }
    for (comments) |comment| try parseComment(allocator, comment, line_index, &entries, &problems);

    // Hide what the directives name, keeping everything else in order.
    var kept: usize = 0;
    for (diagnostics.items) |d| {
        if (hide(entries.items, d, line_index)) {
            d.deinit(allocator);
            continue;
        }
        diagnostics.items[kept] = d;
        kept += 1;
    }
    diagnostics.items.len = kept;

    for (entries.items) |e| {
        // A rule the config turns off can't report, so its directive has nothing to hide.
        if (e.used or levelOf(config, e.rule) == .off) continue;
        try addProblem(allocator, &problems, e.loc, "kupcad:{s} {s} hides nothing here; remove it", .{ e.scope.directive(), e.rule });
    }
    try diagnostics.appendSlice(allocator, problems.items);
    problems.clearRetainingCapacity(); // moved into `diagnostics`
}

fn hide(entries: []Entry, d: linter.LinterDiagnostic, line_index: *const LineIndex) bool {
    const rule = d.ruleId() orelse return false; // syntax and compile errors are never hidden
    const line = line_index.getLine(d.loc.offset);
    var hidden = false;
    for (entries) |*e| {
        if (!std.mem.eql(u8, e.rule, rule)) continue;
        if (e.scope == .file or e.line == line) {
            e.used = true;
            hidden = true;
        }
    }
    return hidden;
}

fn parseComment(
    allocator: std.mem.Allocator,
    comment: token.Comment,
    line_index: *const LineIndex,
    entries: *std.ArrayListUnmanaged(Entry),
    problems: *std.ArrayListUnmanaged(linter.LinterDiagnostic),
) !void {
    var text = std.mem.trim(u8, comment.lexeme, " \t\r");
    if (std.mem.startsWith(u8, text, "#")) text = std.mem.trimStart(u8, text[1..], " \t");
    if (!std.mem.startsWith(u8, text, PREFIX)) return;
    text = text[PREFIX.len..];
    // Anything after " -- " says why, for the reader.
    if (std.mem.indexOf(u8, text, " --")) |reason| text = text[0..reason];

    const name_end = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
    const name = text[0..name_end];
    const scope = Scope.fromName(name) orelse {
        return addProblem(allocator, problems, comment.loc, "unknown directive 'kupcad:{s}' (use disable-next-line, disable-line or disable)", .{name});
    };
    const line = line_index.getLine(comment.loc.offset);
    var ids = std.mem.tokenizeAny(u8, text[name_end..], ", \t");
    var named: usize = 0;
    while (ids.next()) |rule| {
        named += 1;
        if (linter.RuleSet.describe(rule) == null) {
            try addProblem(allocator, problems, comment.loc, "kupcad:{s} names no rule '{s}' (`kupcad check --help` lists them)", .{ name, rule });
            continue;
        }
        try entries.append(allocator, .{
            .scope = scope,
            .rule = rule,
            .line = if (scope == .next_line) line + 1 else line,
            .loc = comment.loc,
        });
    }
    if (named == 0) try addProblem(allocator, problems, comment.loc, "kupcad:{s} must name the rules it hides", .{name});
}

fn levelOf(config: Config, rule: []const u8) Level {
    inline for (comptime std.meta.fieldNames(Config)) |id| {
        if (std.mem.eql(u8, id, rule)) return @field(config, id);
    }
    return .off;
}

fn addProblem(allocator: std.mem.Allocator, problems: *std.ArrayListUnmanaged(linter.LinterDiagnostic), loc: token.Location, comptime fmt: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    errdefer allocator.free(message);
    try problems.append(allocator, .{ .loc = loc, .severity = .warning, .message = message, .origin = .{ .rule = RULE } });
}
