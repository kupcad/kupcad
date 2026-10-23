//! What an import reads (import_kind.zig): by its `with { type: }`, else by its path's
//! extension; and what the parser says of a `with { }` or a file import it can't take.

const std = @import("std");
const testing = std.testing;
const import_kind = @import("import_kind.zig");
const Kind = import_kind.Kind;
const Document = @import("../frontend/document.zig").Document;
const support = @import("../test_support.zig");

const ASCII_STL =
    \\solid part
    \\  facet normal 0 0 1
    \\    outer loop
    \\      vertex 0 0 0
    \\      vertex 10 0 0
    \\      vertex 0 10 0
    \\    endloop
    \\  endfacet
    \\endsolid part
    \\
;

test "import kind: a path's extension, in any case, makes it a file's; any other is a module" {
    const cases = [_]struct { []const u8, Kind }{
        .{ "./logo.stl", .stl },
        .{ "./LOGO.STL", .stl },
        .{ "assets/bearing.Step", .step },
        .{ "assets/bearing.stp", .step },
        .{ "./machine.json", .json },
        .{ "./fonts/Inter-Bold.ttf", .font },
        .{ "Brand.OTF", .font },
        .{ "./plate.dxf", .dxf },
        .{ "cuts/PLATE.DXF", .dxf },
        .{ "./logo.svg", .svg },
        .{ "./hardware.kup", .module },
        .{ "hardware", .module },
        .{ "./data.json.kup", .module },
    };
    for (cases) |case| {
        errdefer std.debug.print("path: {s}\n", .{case[0]});
        try testing.expectEqual(case[1], import_kind.ofPath(case[0]));
    }
}

test "import kind: each type name is its kind's, and the error lists them all" {
    for (std.enums.values(Kind)) |kind| try testing.expectEqual(kind, Kind.fromTypeName(kind.typeName()).?);
    try testing.expect(Kind.fromTypeName("yaml") == null);
    try testing.expect(Kind.fromTypeName("JSON") == null);
    try testing.expectEqualStrings("\"kup\", \"stl\", \"step\", \"json\", \"font\", \"dxf\" or \"svg\"", import_kind.TYPE_NAMES);
}

/// The kind the first import of `source` reads, which must parse without errors.
fn kindOf(source: []const u8) !Kind {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);
    for (doc.tree.nodes.items) |*node| {
        if (node.tag == .import_stmt) return import_kind.ofImport(&doc.tree, doc.tree.importStmt(node));
    }
    return error.NoImport;
}

test "import kind: `with { type: }` names what an import reads, over its extension" {
    const cases = [_]struct { []const u8, Kind }{
        .{ "import m from \"./machine.dat\" with { type: \"json\" }", .json },
        .{ "import m from \"./machine.dat\" with { type: :json }", .json },
        .{ "import m from \"./machine.dat\" with { \"type\" => \"json\" }", .json },
        .{ "import part from \"./scan.bin\" with { type: \"stl\" }", .stl },
        .{ "import { x } from \"./lib.json\" with { type: \"kup\" }", .module },
        // An empty `with { }` says nothing: the extension decides
        .{ "import part from \"./logo.stl\" with {}", .stl },
        .{ "import m from \"./machine.json\"\n  with { type: \"json\" }", .json },
    };
    for (cases) |case| {
        errdefer std.debug.print("source: {s}\n", .{case[0]});
        try testing.expectEqual(case[1], try kindOf(case[0]));
    }
}

test "import kind: a `with { }` it can't take, or a file import naming several variables, is a syntax error" {
    const cases = [_]struct { source: []const u8, message: []const u8 }{
        .{ .source = "import m from \"./m.json\" with { version: 2 }", .message = "An import's `with { }` takes only `type`, not `version`" },
        .{ .source = "import m from \"./m.json\" with { **opts }", .message = "An import's `with { }` takes only `type`" },
        .{ .source = "import m from \"./m.dat\" with { type: \"json\", type: :stl }", .message = "An import's `type` is given twice" },
        .{ .source = "import m from \"./m.dat\" with { type: kind }", .message = "An import's `type` is a string or a symbol, as in `type: \"json\"`" },
        .{ .source = "import m from \"./m.yml\" with { type: \"yaml\" }", .message = "An import's `type` is \"kup\", \"stl\", \"step\", \"json\", \"font\", \"dxf\" or \"svg\", not \"yaml\"" },
        .{ .source = "export { a } from \"./a.kup\" with { version: 2 }", .message = "An import's `with { }` takes only `type`, not `version`" },
        // A mesh has no names in it for braces to take
        .{ .source = "import { teeth } from \"./gear.stl\"", .message = "A file of type \"stl\" gives one value, with no names in it: name it without braces, as in `import part from \"./part.stl\"`" },
        .{ .source = "export { bearing } from \"./608.step\"", .message = "A file of type \"step\" gives one value, with no names in it: name it without braces, as in `import part from \"./part.step\"`" },
        .{ .source = "import { a } from \"./scan.bin\" with { type: \"stl\" }", .message = "A file of type \"stl\" gives one value, with no names in it: name it without braces, as in `import part from \"./part.stl\"`" },
        // Nor a font; its example is a font's file, though its type is "font"
        .{ .source = "import { bold } from \"./Inter.otf\"", .message = "A file of type \"font\" gives one value, with no names in it: name it without braces, as in `import part from \"./part.ttf\"`" },
        .{ .source = "import a, b from \"./m.dat\" with { type: \"stl\" }", .message = "A file (type \"stl\") gives one value; name one variable for it" },
        .{ .source = "export a, b from \"./m.json\"", .message = "A file (type \"json\") gives one value; name one variable for it" },
    };
    for (cases) |case| {
        errdefer std.debug.print("source: {s}\n", .{case.source});
        var doc = try Document.parse(testing.allocator, case.source);
        defer doc.deinit();
        try testing.expectEqual(@as(usize, 1), doc.diagnostics.len);
        try testing.expectEqualStrings(case.message, doc.diagnostics[0].message);
    }
}

test "import kind: a run reads the file as its type says, whatever the file is called" {
    const files = [_]support.ScriptFile{
        .{ .path = "machine.dat", .data = "{\"teeth\": 12}" },
        .{ .path = "MACHINE.JSON", .data = "{\"teeth\": 20}" },
        .{ .path = "scan.bin", .data = ASCII_STL },
        .{ .path = "lib.json", .data = "x = 5\nexport x\n" },
    };
    try support.expectScripts(&.{
        .{ .src = "import m from \"./machine.dat\" with { type: \"json\" }\nr = m[:teeth]", .expected = .{ .num = 12 }, .files = &files },
        .{ .src = "import m from \"./MACHINE.JSON\"\nr = m[:teeth]", .expected = .{ .num = 20 }, .files = &files },
        .{ .src = "import part from \"./scan.bin\" with { type: :stl }\nr = part.class == Geometry", .expected = .{ .boolean = true }, .files = &files },
        .{ .src = "import { x } from \"./lib.json\" with { type: \"kup\" }\nr = x", .expected = .{ .num = 5 }, .files = &files },
    });
}
