const std = @import("std");
const testing = std.testing;
const docstring = @import("docstring.zig");

/// The docstring `raw` starts with, which must have one: its tag and its text.
fn expectDocstring(raw: []const u8, tag: []const u8, content: []const u8) !void {
    const found = (try docstring.parse(testing.allocator, raw)).?;
    defer testing.allocator.free(found.content);
    try testing.expectEqualStrings(tag, found.tag);
    try testing.expectEqualStrings(content, found.content);
}

test "Docstring: a tag with its text on one line" {
    try expectDocstring("# @label Bracket Width", "label", "Bracket Width");
}

test "Docstring: lines indented two spaces past the '#' continue the tag" {
    try expectDocstring(
        \\# @tooltip The overall span of the bracket.
        \\#   Keep under 50mm for standard printers.
        \\#   Very important note.
    , "tooltip", "The overall span of the bracket.\nKeep under 50mm for standard printers.\nVery important note.");
}

test "Docstring: a line not indented ends the tag, and what follows it is not read" {
    try expectDocstring(
        \\# @label Bracket Width
        \\#   This is a continuation.
        \\# This is NOT a continuation.
        \\#   This should also be ignored because the chain was broken.
    , "label", "Bracket Width\nThis is a continuation.");
}

test "Docstring: one rule for continuation lines, whatever the tag line's spacing" {
    // The lexer took a line indented past the tag line's for a continuation, and the
    // docstring parser one indented two spaces: with `#@title X`, `# second line` was the
    // lexer's and not the parser's, and the formatter deleted it.
    try expectDocstring("#@title X\n# second line", "title", "X");
    try expectDocstring("#@title X\n#   second line", "title", "X\nsecond line");
}

test "Docstring: an indented line starting a tag is a tag of its own" {
    try expectDocstring("# @title X\n#   @author Y", "title", "X");
    try expectDocstring("#   @author Y", "author", "Y");
}

test "Docstring: a blank line or code ends the tag" {
    try expectDocstring("# @title X\n\n#   not this", "title", "X");
    try expectDocstring("# @title X\nwidth = 1\n#   not this", "title", "X");
}

test "Docstring: deeper indentation inside a continuation stays" {
    try expectDocstring(
        \\# @tooltip Some info:
        \\#   * Item 1
        \\#     * Sub item
    , "tooltip", "Some info:\n* Item 1\n  * Sub item");
}

test "Docstring: a tag with no text" {
    try expectDocstring("# @version", "version", "");
}

test "Docstring: a comment with no tag has none" {
    try testing.expectEqual(null, try docstring.parse(testing.allocator, "# Just a regular comment about the next line"));
    try testing.expectEqual(null, try docstring.parse(testing.allocator, "width = 1 # @title not a comment line"));
}

test "Docstring: tabs and carriage returns" {
    // Windows line ends, and a tab counted as three columns of indentation: the three
    // columns a continuation's indentation takes are dropped, the two left over stay
    try expectDocstring("# \t  @description \t  This is deeply indented. \r\n# \t  Line 2. \r", "description", "This is deeply indented.\n  Line 2.");
}

test "Docstring: out of memory frees what it built" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const found = (try docstring.parse(allocator, "# @title A\n#   long title")).?;
            allocator.free(found.content);
        }
    }.run, .{});
}
