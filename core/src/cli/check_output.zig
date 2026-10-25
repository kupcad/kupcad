//! Machine-readable `kupcad check` output: JSON for scripts, SARIF 2.1.0 for code-scanning
//! services (GitHub shows SARIF results on a pull request's lines).

const std = @import("std");
const api = @import("../api.zig");
const RuleSet = @import("../tools/lint/linter.zig").RuleSet;
const suppressions = @import("../tools/lint/suppressions.zig");
const ErrorCode = @import("../core/errors.zig").Code;
const lint_finding = @import("../tools/lint/finding.zig");

const SARIF_SCHEMA = "https://json.schemastore.org/sarif-2.1.0.json";
const INFORMATION_URI = "https://github.com/kupcad/kupcad";
const SUPPRESSION_RULE_DESCRIPTION = "A kupcad:disable comment that suppresses nothing or names an unknown rule.";

pub const Format = enum {
    text,
    json,
    sarif,
};

/// A finding in its file: the shape every host gets (tools/lint/finding.zig), with the
/// file's path before it.
const Finding = struct {
    path: []const u8,
    finding: lint_finding.Finding,

    pub fn jsonStringify(self: Finding, jw: *std.json.Stringify) !void {
        try jw.beginObject();
        try jw.objectField("path");
        try jw.write(self.path);
        try self.finding.writeFields(jw);
        try jw.endObject();
    }
};

/// The findings of a run, kept until it ends and written as one document.
pub const Collector = struct {
    arena: std.heap.ArenaAllocator,
    findings: std.ArrayList(Finding) = .empty,

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
        for (diags) |d| try self.findings.append(a, .{ .path = kept_path, .finding = try .place(a, &line_index, d) });
    }

    /// `{ "files", "errors", "warnings", "infos", "findings": [...] }`, each finding with
    /// its `path` and then tools/lint/finding.zig's fields.
    pub fn writeJson(self: *const Collector, w: *std.Io.Writer, counts: Counts) !void {
        try std.json.Stringify.value(.{
            .files = counts.files,
            .errors = counts.errors,
            .warnings = counts.warnings,
            .infos = counts.infos,
            .findings = self.findings.items,
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

        // Code scanning accepts a finding only under a listed rule: the lint rules, then the
        // error codes
        const codes = std.enums.values(ErrorCode);
        const rules = try a.alloc(Rule, RuleSet.ids.len + 1 + codes.len);
        inline for (RuleSet.ids, 0..) |id, i| rules[i] = .{ .id = id, .shortDescription = .{ .text = @FieldType(RuleSet, id).description } };
        rules[RuleSet.ids.len] = .{ .id = suppressions.RULE, .shortDescription = .{ .text = SUPPRESSION_RULE_DESCRIPTION } };
        for (codes, rules[RuleSet.ids.len + 1 ..]) |code, *rule| rule.* = .{ .id = code.name(), .shortDescription = .{ .text = code.description() } };

        const results = try a.alloc(Result, self.findings.items.len);
        for (self.findings.items, results) |placed, *r| {
            const f = placed.finding;
            const locations = try a.alloc(Location, 1);
            locations[0] = .{ .physicalLocation = .{
                .artifactLocation = .{ .uri = try pathUri(a, placed.path) },
                .region = .{ .startLine = f.start.line, .startColumn = f.start.utf16_column, .endLine = f.end.line, .endColumn = f.end.utf16_column },
            } };
            const level = if (std.mem.eql(u8, f.severity, "info")) "note" else f.severity;
            r.* = .{ .ruleId = f.code, .level = level, .message = .{ .text = f.message }, .locations = locations };
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
    const forward = try allocator.dupe(u8, path);
    defer allocator.free(forward);
    std.mem.replaceScalar(u8, forward, '\\', '/');
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.Uri.Component.percentEncode(&out.writer, forward, isUriPathChar);
    return out.toOwnedSlice();
}

fn isUriPathChar(c: u8) bool {
    return c == '/' or std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}
