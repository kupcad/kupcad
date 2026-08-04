const std = @import("std");
const lexer_mod = @import("frontend/kupcad/lexer.zig");
const parser_mod = @import("frontend/kupcad/parser.zig");
const Formatter = @import("tools/fmt/formatter.zig").Formatter;
pub const FormatterConfig = @import("tools/fmt/config.zig").Config;
const Linter = @import("tools/lint/linter.zig").Linter;
pub const LinterConfig = @import("tools/lint/config.zig").Config;
pub const LinterDiagnostic = @import("tools/lint/linter.zig").LinterDiagnostic;

pub const FormatError = error{
    SyntaxError,
    OutOfMemory,
};

/// Formats KupCAD source code. Caller owns the returned slice.
pub fn formatCode(allocator: std.mem.Allocator, source: []const u8, config: FormatterConfig) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, arena.allocator());
    defer parser.deinit();

    const tree = try parser.parseProgram();

    // Abort formatting if any syntax errors occurred during parsing!
    if (parser.diagnostics.list.items.len > 0) {
        return error.SyntaxError;
    }

    // Feed the original allocator to the Formatter and apply the passed Config
    var formatter = Formatter.init(allocator, parser.comments.items, config);
    defer formatter.deinit();

    try formatter.registerDefaultRules();

    return formatter.format(tree);
}

/// Lints KupCAD source code. Caller owns the returned array of diagnostics.
pub fn checkCode(allocator: std.mem.Allocator, source: []const u8, config: LinterConfig) ![]LinterDiagnostic {
    var linter = Linter.init(allocator, config);
    defer linter.deinit();

    try linter.registerDefaultRules();
    try linter.check(source);

    return linter.diagnostics.toOwnedSlice(allocator);
}
