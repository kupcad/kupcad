//! `Document`: one parsed source file, with its tokens, comments, diagnostics, line index and,
//! from `parse`, the resolver's symbols and the parent map; all owned by one arena.
//! `parseRaw` stops after the parser.

const std = @import("std");
const lexer_mod = @import("../frontend/lexer.zig");
const parser_mod = @import("../frontend/parser.zig");
const common_token = @import("token.zig");
const common_errors = @import("errors.zig");
const ast = @import("ast.zig");
const resolver = @import("resolver.zig");
const parent_map = @import("parent_map.zig");
const limits = @import("limits.zig");

pub const LineIndex = @import("line_index.zig").LineIndex;

/// Represents a fully parsed KupCAD source file.
/// Owns the ArenaAllocator that backs the AST, tokens, comments, and diagnostics.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    /// The text it was parsed from, borrowed: the caller keeps it alive (tokens, comments
    /// and diagnostics point into it).
    source: []const u8,
    tree: ast.Tree,
    tokens: common_token.TokenList(lexer_mod.Tag),
    comments: []const common_token.Comment,
    diagnostics: []const common_errors.Diagnostic,
    line_index: LineIndex,
    symbols: []resolver.ResolvedSymbol,
    parents: []ast.NodeIndex,
    closure_captures: std.AutoHashMapUnmanaged(ast.NodeIndex, []const resolver.UpvalueCapture),

    fn parseInternal(allocator: std.mem.Allocator, source: []const u8, resolve_semantics: bool) !Document {
        // The CLI caps file size before reading, but LSP/WASM hand us buffers directly
        if (source.len > limits.MAX_SOURCE_BYTES) return error.SourceTooLarge;

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        // Everything after the lexer takes the source for UTF-8 (string ranges and text()
        // did byte arithmetic on it and tripped on a stray 0xFF), so a source that isn't
        // is one diagnostic and no program.
        const invalid_byte = firstInvalidUtf8(source);
        const lexed = if (invalid_byte == null) source else source[0..0];

        var lexer = lexer_mod.Lexer.init(lexed, 0);
        const tokens = try lexer.lexAll(arena_alloc);

        var parser = try parser_mod.Parser.init(tokens, lexed, arena_alloc);
        const root_index = parser.parseProgram() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => .none,
        };
        if (invalid_byte) |offset| {
            parser.diagnostics.add(.{ .offset = @intCast(offset), .length = 1, .file_id = 0 }, .@"invalid-utf8", "the source isn't valid UTF-8 (byte 0x{X:0>2})", .{source[offset]});
        }

        var tree = parser.b.tree;
        tree.root = root_index;

        const line_index = try LineIndex.init(arena_alloc, source);

        var symbols: []resolver.ResolvedSymbol = &[_]resolver.ResolvedSymbol{};
        var closure_captures: std.AutoHashMapUnmanaged(ast.NodeIndex, []const resolver.UpvalueCapture) = .empty;
        var parents: []ast.NodeIndex = &[_]ast.NodeIndex{};

        if (resolve_semantics) {
            var res = try resolver.Resolver.init(arena_alloc, &tree, tokens.starts, tokens.lengths, &parser.diagnostics);
            try res.resolve(root_index);
            symbols = res.symbols;
            closure_captures = res.closure_captures;

            var pmap = try parent_map.ParentMap.init(arena_alloc, &tree);
            try pmap.build(&tree, root_index);
            parents = pmap.parents;
        }
        // A diagnostic lost to out-of-memory would let broken source pass as valid.
        if (parser.diagnostics.dropped) return error.OutOfMemory;

        return .{
            .arena = arena,
            .source = source,
            .tree = tree,
            .tokens = tokens,
            .comments = parser.comments.items,
            .diagnostics = parser.diagnostics.list.items,
            .line_index = line_index,
            .symbols = symbols,
            .closure_captures = closure_captures,
            .parents = parents,
        };
    }

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Document {
        return parseInternal(allocator, source, true);
    }

    /// The offset of the first byte that isn't part of a well-formed UTF-8 sequence, if any.
    fn firstInvalidUtf8(source: []const u8) ?usize {
        var i: usize = 0;
        while (i < source.len) {
            const len = std.unicode.utf8ByteSequenceLength(source[i]) catch return i;
            if (i + len > source.len) return i;
            if (!std.unicode.utf8ValidateSlice(source[i..][0..len])) return i;
            i += len;
        }
        return null;
    }

    /// Only runs the Lexer and Parser. Does NOT run semantic resolution.
    /// This allows the Workspace to build the module graph before resolving symbols.
    pub fn parseRaw(allocator: std.mem.Allocator, source: []const u8) !Document {
        return parseInternal(allocator, source, false);
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};
