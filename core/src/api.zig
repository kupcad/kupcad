const std = @import("std");
const lexer_mod = @import("frontend/kupcad/lexer.zig");
const parser_mod = @import("frontend/kupcad/parser.zig");
const common_token = @import("core/token.zig");
const common_errors = @import("core/errors.zig");
const ast = @import("core/ast.zig");
const Formatter = @import("tools/fmt/formatter.zig").Formatter;
const Linter = @import("tools/lint/linter.zig").Linter;

pub const FormatterConfig = @import("tools/fmt/config.zig").Config;
pub const LineIndex = @import("core/line_index.zig").LineIndex;
pub const LinterConfig = @import("tools/lint/config.zig").Config;
pub const LinterDiagnostic = @import("tools/lint/linter.zig").LinterDiagnostic;
pub const FormatError = error{
    SyntaxError,
    OutOfMemory,
};

/// Represents a fully parsed KupCAD source file.
/// Owns the ArenaAllocator that backs the AST, tokens, comments, and diagnostics.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    tree: ast.Tree,
    tokens: common_token.TokenList(lexer_mod.Tag),
    comments: []const common_token.Comment,
    diagnostics: []const common_errors.Diagnostic,
    line_index: LineIndex,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Document {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        var lexer = lexer_mod.Lexer.init(source, 0);
        const tokens = try lexer.lexAll(arena_alloc);

        var parser = parser_mod.Parser.init(tokens, source, arena_alloc);
        const root_index = parser.parseProgram() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => .none,
        };

        var tree = parser.b.tree;
        tree.root = root_index;

        const line_index = try LineIndex.init(arena_alloc, source);

        return .{
            .arena = arena,
            .tree = tree,
            .tokens = tokens,
            .comments = parser.comments.items,
            .diagnostics = parser.diagnostics.list.items,
            .line_index = line_index,
        };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

/// Formats an already parsed Document. Caller owns the returned slice.
pub fn formatDocument(allocator: std.mem.Allocator, doc: *const Document, config: FormatterConfig) ![]const u8 {
    if (doc.diagnostics.len > 0) return error.SyntaxError;
    if (doc.tree.root == .none) return error.SyntaxError;

    var formatter = Formatter.init(allocator, doc.tokens.starts, &doc.line_index, doc.comments, config);
    defer formatter.deinit();
    try formatter.registerDefaultRules();

    return formatter.format(&doc.tree, doc.tree.root);
}

/// Formats raw KupCAD source code (Convenience wrapper).
pub fn formatCode(allocator: std.mem.Allocator, source: []const u8, config: FormatterConfig) ![]const u8 {
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();
    return formatDocument(allocator, &doc, config);
}

/// Lints an already parsed Document. Caller owns the returned array of diagnostics.
pub fn checkDocument(allocator: std.mem.Allocator, doc: *const Document, config: LinterConfig) ![]LinterDiagnostic {
    var linter = Linter.init(allocator, config);
    defer linter.deinit();
    try linter.registerDefaultRules();

    try linter.check(&doc.tree, doc.tokens.starts, doc.tokens.lengths, doc.tree.root, doc.diagnostics);
    return linter.diagnostics.toOwnedSlice(allocator);
}

/// Lints raw KupCAD source code (Convenience wrapper).
pub fn checkCode(allocator: std.mem.Allocator, source: []const u8, config: LinterConfig) ![]LinterDiagnostic {
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();
    return checkDocument(allocator, &doc, config);
}
