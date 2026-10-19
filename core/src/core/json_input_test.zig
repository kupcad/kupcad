//! The JSON reader (json_input.zig): a syntax error placed at its line and column, and a
//! key written twice refused.

const std = @import("std");
const json_input = @import("json_input.zig");
const Position = json_input.Position;
const parse = json_input.parse;
const describeSyntaxError = json_input.describeSyntaxError;

test "json_input: a syntax error is placed at its line and column" {
    var where: Position = undefined;
    try std.testing.expectError(error.SyntaxError, parse(std.json.Value, std.testing.allocator, "{\n  \"a\": 1,\n  \"b\" 2\n}", &where));
    try std.testing.expectEqual(Position{ .line = 3, .column = 7 }, where);
    try std.testing.expectEqualStrings("invalid JSON", describeSyntaxError(error.SyntaxError).?);
}

test "json_input: a key written twice is an error, not the last one winning" {
    try std.testing.expectError(error.DuplicateField, parse(std.json.Value, std.testing.allocator, "{\"a\": 1, \"a\": 2}", null));
}
