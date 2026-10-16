//! Machine-readable `kupcad check` output: JSON for scripts, SARIF 2.1.0 for code-scanning
//! services (GitHub shows SARIF results on a pull request's lines).

const std = @import("std");
const api = @import("../api.zig");
const RuleSet = @import("../tools/lint/linter.zig").RuleSet;
const suppressions = @import("../tools/lint/suppressions.zig");

const SARIF_SCHEMA = "https://json.schemastore.org/sarif-2.1.0.json";
const INFORMATION_URI = "https://github.com/kupcad/kupcad";
/// The SARIF rule a syntax or compile error is reported under (a finding without a rule
/// isn't accepted by code scanning).
const ERROR_RULE_ID = "syntax-or-compile-error";
const ERROR_RULE_DESCRIPTION = "The script doesn't parse or compile; it can't run until this is fixed.";
const SUPPRESSION_RULE_DESCRIPTION = "A kupcad:disable comment that suppresses nothing or names an unknown rule.";

pub const Format = enum {
    text,
    json,
    sarif,
};

/// A place in a file: 1-based line, and 1-based column in UTF-8 bytes (as `check` prints
/// it) and in UTF-16 code units (SARIF's default).
const Position = struct {
    line: u32,
    column: u32,
    utf16_column: u32,

    fn at(line_index: *const api.LineIndex, offset: u32) Position {
        const pos = line_index.humanPosition(offset);
        return .{ .line = pos.line, .column = pos.column, .utf16_column = line_index.getUtf16Column(offset) + 1 };
    }
};

const Edit = struct { start: Position, end: Position, text: []const u8 };

const Finding = struct {
    path: []const u8,
    start: Position,
    end: Position,
    severity: []const u8,
    rule: ?[]const u8,
    message: []const u8,
    fix_title: ?[]const u8 = null,
    fix_safe: bool = false,
    fix_edits: []const Edit = &.{},
};

/// The findings of a run, kept until it ends and written as one document.
pub const Collector = struct {
    arena: std.heap.ArenaAllocator,
    findings: std.ArrayListUnmanaged(Finding) = .empty,

    pub fn init(allocator: std.mem.Allocator) Collector {
        return .{ .arena = .init(allocator) };
    }

    pub fn deinit(self: *Collector) void {
        self.arena.deinit();
    }

    /// Copies what it keeps, so `diags` and `source` can be freed after.
    pub fn add(self: *Collector, path: []const u8, source: []const u8, diags: []const api.LinterDiagnostic) !void {
        const a = self.arena.allocator();
        const line_index = try api.LineIndex.init(a, source);
        const kept_path = try a.dupe(u8, path);
        for (diags) |d| {
            var finding: Finding = .{
                .path = kept_path,
                .start = .at(&line_index, d.loc.offset),
                .end = .at(&line_index, d.loc.offset + d.loc.length),
                .severity = @tagName(d.severity),
                .rule = d.rule,
                .message = try a.dupe(u8, d.message),
            };
            if (d.fix) |fix| {
                const edits = try a.alloc(Edit, fix.edits.len);
                for (fix.edits, edits) |e, *out| out.* = .{
                    .start = .at(&line_index, e.offset),
                    .end = .at(&line_index, e.offset + e.length),
                    .text = try a.dupe(u8, e.replacement),
                };
                finding.fix_title = try a.dupe(u8, fix.title);
                finding.fix_safe = fix.safe;
                finding.fix_edits = edits;
            }
            try self.findings.append(a, finding);
        }
    }

    /// `{ "files", "errors", "warnings", "infos", "findings": [...] }`, each finding with
    /// its `path`, `line`, `column`, `endLine`, `endColumn` (1-based, columns in UTF-8
    /// bytes), `severity`, `rule` (null for a syntax or compile error), `message` and `fix`.
    pub fn writeJson(self: *const Collector, w: *std.Io.Writer, counts: Counts) !void {
        const a = @constCast(&self.arena).allocator();
        const JsonEdit = struct { line: u32, column: u32, endLine: u32, endColumn: u32, text: []const u8 };
        const JsonFix = struct { title: []const u8, safe: bool, edits: []const JsonEdit };
        const JsonFinding = struct {
            path: []const u8,
            line: u32,
            column: u32,
            endLine: u32,
            endColumn: u32,
            severity: []const u8,
            rule: ?[]const u8,
            message: []const u8,
            fix: ?JsonFix,
        };
        const out = try a.alloc(JsonFinding, self.findings.items.len);
        for (self.findings.items, out) |f, *j| {
            var fix: ?JsonFix = null;
            if (f.fix_title) |title| {
                const edits = try a.alloc(JsonEdit, f.fix_edits.len);
                for (f.fix_edits, edits) |e, *je| je.* = .{ .line = e.start.line, .column = e.start.column, .endLine = e.end.line, .endColumn = e.end.column, .text = e.text };
                fix = .{ .title = title, .safe = f.fix_safe, .edits = edits };
            }
            j.* = .{ .path = f.path, .line = f.start.line, .column = f.start.column, .endLine = f.end.line, .endColumn = f.end.column, .severity = f.severity, .rule = f.rule, .message = f.message, .fix = fix };
        }
        try std.json.Stringify.value(.{
            .files = counts.files,
            .errors = counts.errors,
            .warnings = counts.warnings,
            .infos = counts.infos,
            .findings = out,
        }, .{ .whitespace = .indent_2 }, w);
        try w.writeAll("\n");
    }

    /// One SARIF run listing every rule a result can name (the lint rules, the suppression
    /// check, and one for syntax and compile errors), with a result per finding. Paths are
    /// percent-encoded URIs. Levels map as SARIF's do: info is "note". (Code scanning
    /// rejected the file: raw paths, suppression results naming an undeclared rule, and
    /// error results with no rule at all.)
    pub fn writeSarif(self: *const Collector, w: *std.Io.Writer) !void {
        const a = @constCast(&self.arena).allocator();
        const Text = struct { text: []const u8 };
        const Region = struct { startLine: u32, startColumn: u32, endLine: u32, endColumn: u32 };
        const Location = struct { physicalLocation: struct { artifactLocation: struct { uri: []const u8 }, region: Region } };
        const Result = struct { ruleId: []const u8, level: []const u8, message: Text, locations: []const Location };
        const Rule = struct { id: []const u8, shortDescription: Text };

        const rules = try a.alloc(Rule, RuleSet.ids.len + 2);
        inline for (RuleSet.ids, 0..) |id, i| rules[i] = .{ .id = id, .shortDescription = .{ .text = @FieldType(RuleSet, id).description } };
        rules[RuleSet.ids.len] = .{ .id = suppressions.RULE, .shortDescription = .{ .text = SUPPRESSION_RULE_DESCRIPTION } };
        rules[RuleSet.ids.len + 1] = .{ .id = ERROR_RULE_ID, .shortDescription = .{ .text = ERROR_RULE_DESCRIPTION } };

        const results = try a.alloc(Result, self.findings.items.len);
        for (self.findings.items, results) |f, *r| {
            const locations = try a.alloc(Location, 1);
            locations[0] = .{ .physicalLocation = .{
                .artifactLocation = .{ .uri = try pathUri(a, f.path) },
                .region = .{ .startLine = f.start.line, .startColumn = f.start.utf16_column, .endLine = f.end.line, .endColumn = f.end.utf16_column },
            } };
            const level = if (std.mem.eql(u8, f.severity, "info")) "note" else f.severity;
            r.* = .{ .ruleId = f.rule orelse ERROR_RULE_ID, .level = level, .message = .{ .text = f.message }, .locations = locations };
        }
        try std.json.Stringify.value(.{
            .version = "2.1.0",
            .@"$schema" = SARIF_SCHEMA,
            .runs = .{.{
                .tool = .{ .driver = .{ .name = "kupcad", .informationUri = INFORMATION_URI, .rules = rules } },
                .results = results,
            }},
        }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false }, w);
        try w.writeAll("\n");
    }
};

pub const Counts = struct { files: usize, errors: usize, warnings: usize, infos: usize };

/// A file path as a SARIF artifact URI: forward slashes, with every byte outside RFC
/// 3986's unreserved set (and `/`) percent-encoded.
fn pathUri(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (path) |c| {
        const separator = c == '/' or c == '\\';
        const unreserved = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
        if (separator) {
            try out.append(allocator, '/');
        } else if (unreserved) {
            try out.append(allocator, c);
        } else {
            var hex: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&hex, "%{X:0>2}", .{c}) catch unreachable;
            try out.appendSlice(allocator, &hex);
        }
    }
    return out.toOwnedSlice(allocator);
}
