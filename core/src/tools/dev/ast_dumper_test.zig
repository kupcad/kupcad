const std = @import("std");
const testing = std.testing;
const Document = @import("../../frontend/document.zig").Document;
const ast_dumper = @import("ast_dumper.zig");

fn expectDump(source: []const u8, expected: []const u8) !void {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try ast_dumper.dump(&doc, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

test "AST Dumper: a node per line, indented by depth, with its payload and kind" {
    try expectDump(
        \\# @label Bracket Width
        \\#   multiline comment
        \\width = 50
        \\Box.new(x: width)
        \\  .chamfer(2)
        \\  .translate(z: 10)
        \\
        \\def create_part(h: 20)
        \\  cube(h)
        \\end
    ,
        \\block
        \\  assignment 'width'
        \\    number 50
        \\  method_call 'translate'
        \\    method_call 'chamfer'
        \\      method_call 'new'
        \\        identifier 'Box' (symbol: global)
        \\        identifier 'width' (symbol: local)
        \\      number 2
        \\    number 10
        \\  def_stmt 'create_part' |h:|
        \\    number 20
        \\    block
        \\      method_call 'cube'
        \\        identifier 'h' (symbol: local)
        \\
    );
}

test "AST Dumper: every subtree, as the walk visits it" {
    // A lambda's body, a map's entries, and what classes, cases, loops, begins, indexing and
    // ternaries hold were left out.
    try expectDump(
        \\f = -> { puts 1 }
        \\m = { a: cube(1) }
        \\[[1, 2]].each { |(p, q), *r| p }
        \\x = m[:a] ? 1 : 2
    ,
        \\block
        \\  assignment 'f'
        \\    lambda_expr
        \\      block
        \\        method_call 'puts'
        \\          number 1
        \\  assignment 'm'
        \\    hash_literal
        \\      symbol 'a'
        \\      method_call 'cube'
        \\        number 1
        \\  method_call 'each'
        \\    array_literal
        \\      array_literal
        \\        number 1
        \\        number 2
        \\    block |(p, q), *r|
        \\      identifier 'p' (symbol: local)
        \\  assignment 'x'
        \\    ternary_op
        \\      index_access
        \\        identifier 'm' (symbol: local)
        \\        symbol 'a'
        \\      number 1
        \\      number 2
        \\
    );
}
