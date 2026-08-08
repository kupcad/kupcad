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
/// Owns the ArenaAllocator that backs the AST, comments, and diagnostics.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    tree: ast.Tree,
    comments: []const common_token.Comment,
    diagnostics: []const common_errors.Diagnostic,
    line_index: LineIndex,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Document {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        var lexer = lexer_mod.Lexer.init(source, 0);

        // Execute Ahead-Of-Time SoA Lexing
        const tokens = try lexer.lexAll(arena_alloc);

        // Pass tokens and source directly to the Parser
        var parser = parser_mod.Parser.init(tokens, source, arena_alloc);

        const root_index = parser.parseProgram() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => .none,
        };

        // Extract the populated tree from the builder and set the root
        var tree = parser.b.tree;
        tree.root = root_index;

        // Initialize the LineIndex using the Arena Allocator
        const line_index = try LineIndex.init(arena_alloc, source);

        return .{
            .arena = arena,
            .tree = tree,
            .comments = parser.comments.items,
            .diagnostics = parser.diagnostics.list.items,
            .line_index = line_index,
        };
    }

    pub fn deinit(self: *Document) void {
        // Because the Tree's MultiArrayList/ArrayListUnmanaged uses the arena allocator,
        // calling arena.deinit() safely frees all AST nodes and strings at once.
        self.arena.deinit();
    }
};

/// Formats an already parsed Document. Caller owns the returned slice.
pub fn formatDocument(allocator: std.mem.Allocator, doc: *const Document, config: FormatterConfig) ![]const u8 {
    // Abort formatting if any syntax errors occurred during parsing!
    if (doc.diagnostics.len > 0) return error.SyntaxError;
    if (doc.tree.root == .none) return error.SyntaxError;

    // Feed the original allocator to the Formatter and apply the passed Config
    var formatter = Formatter.init(allocator, doc.comments, config);
    defer formatter.deinit();

    try formatter.registerDefaultRules();

    // Pass the tree and the root index instead of a pointer
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

    // Pass the tree and the root index instead of a pointer
    try linter.check(&doc.tree, doc.tree.root, doc.diagnostics);

    return linter.diagnostics.toOwnedSlice(allocator);
}

/// Lints raw KupCAD source code (Convenience wrapper).
pub fn checkCode(allocator: std.mem.Allocator, source: []const u8, config: LinterConfig) ![]LinterDiagnostic {
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();
    return checkDocument(allocator, &doc, config);
}
