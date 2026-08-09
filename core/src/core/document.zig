const std = @import("std");
const lexer_mod = @import("../frontend/kupcad/lexer.zig");
const parser_mod = @import("../frontend/kupcad/parser.zig");
const common_token = @import("token.zig");
const common_errors = @import("errors.zig");
const ast = @import("ast.zig");
const resolver = @import("resolver.zig");
const parent_map = @import("parent_map.zig");

pub const LineIndex = @import("line_index.zig").LineIndex;

/// Represents a fully parsed KupCAD source file.
/// Owns the ArenaAllocator that backs the AST, tokens, comments, and diagnostics.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    tree: ast.Tree,
    tokens: common_token.TokenList(lexer_mod.Tag),
    comments: []const common_token.Comment,
    diagnostics: []const common_errors.Diagnostic,
    line_index: LineIndex,
    symbols: []resolver.ResolvedSymbol,
    parents: []ast.NodeIndex,
    closure_captures: std.AutoHashMapUnmanaged(ast.NodeIndex, []const resolver.UpvalueCapture),

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Document {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        var lexer = lexer_mod.Lexer.init(source, 0);
        const tokens = try lexer.lexAll(arena_alloc);

        var parser = try parser_mod.Parser.init(tokens, source, arena_alloc);
        const root_index = parser.parseProgram() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => .none,
        };

        var tree = parser.b.tree;
        tree.root = root_index;

        const line_index = try LineIndex.init(arena_alloc, source);

        var res = try resolver.Resolver.init(arena_alloc, &tree, tokens.starts, tokens.lengths, &parser.diagnostics);
        try res.resolve(root_index);

        var pmap = try parent_map.ParentMap.init(arena_alloc, &tree);
        try pmap.build(&tree, root_index);

        return .{
            .arena = arena,
            .tree = tree,
            .tokens = tokens,
            .comments = parser.comments.items,
            .diagnostics = parser.diagnostics.list.items,
            .line_index = line_index,
            .symbols = res.symbols,
            .closure_captures = res.closure_captures,
            .parents = pmap.parents,
        };
    }

    /// Only runs the Lexer and Parser. Does NOT run semantic resolution.
    /// This allows the Workspace to build the module graph before resolving symbols.
    pub fn parseRaw(allocator: std.mem.Allocator, source: []const u8) !Document {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        var lexer = lexer_mod.Lexer.init(source, 0);
        const tokens = try lexer.lexAll(arena_alloc);

        var parser = try parser_mod.Parser.init(tokens, source, arena_alloc);
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
            .symbols = &[_]resolver.ResolvedSymbol{},
            .closure_captures = .empty,
            .parents = &[_]ast.NodeIndex{},
        };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};
