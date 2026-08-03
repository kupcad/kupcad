const std = @import("std");
const ast = @import("../core/ast.zig");
const token = @import("../core/token.zig");
const lexer_mod = @import("../frontend/kupcad/lexer.zig");
const parser_mod = @import("../frontend/kupcad/parser.zig");

pub const DiagnosticSeverity = enum { @"error", warning, info };

pub const LinterDiagnostic = struct {
    loc: token.Location,
    message: []const u8,
    severity: DiagnosticSeverity,
};

pub const Linter = struct {
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayListUnmanaged(LinterDiagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) Linter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Linter) void {
        self.diagnostics.deinit(self.allocator);
    }

    pub fn check(self: *Linter, source: []const u8) !void {
        var lexer = lexer_mod.Lexer.init(source, 0);
        var parser = parser_mod.Parser.init(&lexer, self.allocator);
        defer parser.deinit();

        // Properly yield null on syntax errors, but bubble up OutOfMemory
        const tree: ?*ast.Node = parser.parseProgram() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };

        // Collect Syntax Errors
        for (parser.diagnostics.list.items) |diag| {
            try self.diagnostics.append(self.allocator, .{
                .loc = diag.loc,
                .message = try self.allocator.dupe(u8, diag.message),
                .severity = .@"error",
            });
        }

        // [Future] Run Semantic Analysis / Symbol Table checks here if tree != null
        _ = tree;
    }
};
