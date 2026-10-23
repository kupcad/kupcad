//! Reading JSON a person gives KupCAD: the project's `.kupcad.json`, a `-P` parameter file
//! and the data files `import_json` reads. One reader for them all, so they accept
//! the same JSON (a key written twice is an error, error.DuplicateField) and place a syntax
//! error at the same line and column.

const std = @import("std");

/// Where a parse stopped: 1-based line and column.
pub const Position = struct { line: u64, column: u64 };

/// `text` parsed as a `T` (std.json.Value for any JSON), owned by the result's arena. When it
/// fails, `where` (if given) receives the line and column the parse stopped at.
pub fn parse(comptime T: type, allocator: std.mem.Allocator, text: []const u8, where: ?*Position) !std.json.Parsed(T) {
    var scanner = std.json.Scanner.initCompleteInput(allocator, text);
    defer scanner.deinit();
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);
    return std.json.parseFromTokenSource(T, allocator, &scanner, .{}) catch |err| {
        if (where) |w| w.* = .{ .line = diagnostics.getLine(), .column = diagnostics.getColumn() };
        return err;
    };
}

/// What a `parse` error that isn't about the shape of `T` means, for a person; null for one
/// that is (an unknown field, a wrong type), which the caller words.
pub fn describeSyntaxError(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.SyntaxError, error.UnexpectedEndOfInput => "invalid JSON",
        error.DuplicateField => "a key is written twice",
        else => null,
    };
}
