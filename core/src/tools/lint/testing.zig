//! The lint tests' harness: lints a source with the rules a config turns on.

const std = @import("std");
const linter_mod = @import("linter.zig");
const Config = @import("config.zig").Config;
const parser_mod = @import("../../frontend/parser.zig");
const lexer_mod = @import("../../frontend/lexer.zig");

/// The engine after linting `source`; its diagnostics are the findings. Caller deinits.
pub fn lint(allocator: std.mem.Allocator, source: []const u8, config: Config) !linter_mod.Linter {
    var engine = linter_mod.Linter.init(allocator, config);
    errdefer engine.deinit();
    try engine.registerDefaultRules();

    // Tokens and AST are scratch; only the engine (and its diagnostics) is returned.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lexer = lexer_mod.Lexer.init(source, 0);
    const tokens = try lexer.lexAll(arena.allocator());
    var parser = try parser_mod.Parser.init(tokens, source, arena.allocator());
    const root = try parser.parseProgram();
    try engine.check(&parser.b.tree, source, tokens.starts, tokens.lengths, root, parser.diagnostics.list.items);
    return engine;
}

/// A config with every rule off but `rule_id`.
pub fn only(comptime rule_id: []const u8) Config {
    var config: Config = .{};
    inline for (comptime @typeInfo(Config).@"struct".field_names) |id| @field(config, id) = .off;
    @field(config, rule_id) = .warning;
    return config;
}
