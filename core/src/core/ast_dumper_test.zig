const std = @import("std");
const testing = std.testing;
const api = @import("../api.zig");
const ast_dumper = @import("ast_dumper.zig");

test "AST Dumper: produces correct tree format and semantic metadata" {
    const source =
        \\# @param width [Length] Overall box width
        \\#   multiline comment
        \\width = 50
        \\Box.new(x: width)
        \\  .chamfer(2)
        \\  .translate(z: 10)
        \\
        \\def create_part(h: 20)
        \\  cube(h)
        \\end
    ;

    var doc = try api.Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try ast_dumper.dump(testing.allocator, &doc, &out);

    const expected =
        \\└── block
        \\    ├── param_doc
        \\    ├── assignment 'width'
        \\    │   └── number 50
        \\    ├── method_call 'translate'
        \\    │   ├── method_call 'chamfer'
        \\    │   │   ├── method_call 'new'
        \\    │   │   │   ├── identifier 'Box' (symbol: global slot 0)
        \\    │   │   │   └── identifier 'width' (symbol: local slot 0)
        \\    │   │   └── number 2
        \\    │   └── number 10
        \\    └── def_stmt 'create_part' [captures: 0]
        \\        └── block
        \\            └── method_call 'cube'
        \\                └── identifier 'h' (symbol: local slot 0)
        \\
    ;

    try testing.expectEqualStrings(expected, out.written());
}
