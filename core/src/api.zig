const std = @import("std");
const lexer_mod = @import("frontend/kupcad/lexer.zig");
const parser_mod = @import("frontend/kupcad/parser.zig");
const Formatter = @import("tools/fmt/formatter.zig").Formatter;
const FormatterConfig = @import("tools/fmt/config.zig").Config;
const Linter = @import("tools/lint/linter.zig").Linter;
const LinterConfig = @import("tools/lint/config.zig").Config;
pub const LinterDiagnostic = @import("tools/lint/linter.zig").LinterDiagnostic;

pub fn formatCode(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lexer = lexer_mod.Lexer.init(source, 0);
    var parser = parser_mod.Parser.init(&lexer, arena.allocator());
    defer parser.deinit();

    const tree = try parser.parseProgram();

    var formatter = Formatter.init(allocator, parser.comments.items, FormatterConfig{});
    defer formatter.deinit();
    try formatter.registerDefaultRules();

    return formatter.format(tree);
}

pub fn checkCode(allocator: std.mem.Allocator, source: []const u8) ![]LinterDiagnostic {
    var linter = Linter.init(allocator, LinterConfig{});
    defer linter.deinit();
    try linter.registerDefaultRules();

    try linter.check(source);

    return linter.diagnostics.toOwnedSlice(allocator);
}
