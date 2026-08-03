const std = @import("std");
const lexer_mod = @import("frontend/kupcad/lexer.zig");
const parser_mod = @import("frontend/kupcad/parser.zig");
const Formatter = @import("tools/formatter.zig").Formatter;
const Linter = @import("tools/linter.zig").Linter;
pub const LinterDiagnostic = @import("tools/linter.zig").LinterDiagnostic;

/// Formats KupCAD source code. Caller owns the returned slice.
pub fn formatCode(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    // 1. Create an ArenaAllocator to automatically clean up AST nodes
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var lexer = lexer_mod.Lexer.init(source, 0);
    // 2. Feed the arena allocator to the parser
    var parser = parser_mod.Parser.init(&lexer, arena.allocator());
    defer parser.deinit();

    const tree = try parser.parseProgram();

    // 3. Feed the original allocator to the Formatter so the returned string survives
    var formatter = Formatter.init(allocator, parser.comments.items);
    defer formatter.deinit();
    return formatter.format(tree);
}

/// Lints KupCAD source code. Caller owns the returned array of diagnostics.
pub fn checkCode(allocator: std.mem.Allocator, source: []const u8) ![]LinterDiagnostic {
    var linter = Linter.init(allocator);
    defer linter.deinit();
    try linter.check(source);
    return linter.diagnostics.toOwnedSlice(allocator);
}
