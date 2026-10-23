//! import_dxf: a DXF file's outlines as a Sketch, holes by nesting.

const support = @import("../test_support.zig");
const expectScripts = support.expectScripts;
const rescued = support.rescued;

/// A DXF file of `entities`.
fn file(comptime entities: []const u8) []const u8 {
    return "0\nSECTION\n2\nENTITIES\n" ++ entities ++ "0\nENDSEC\n0\nEOF\n";
}

/// A closed LWPOLYLINE on `layer` through the corners of the square from `lo` to `hi`,
/// clockwise when `cw`.
fn square(comptime layer: []const u8, comptime lo: []const u8, comptime hi: []const u8, comptime cw: bool) []const u8 {
    const corners = if (cw)
        "10\n" ++ lo ++ "\n20\n" ++ lo ++ "\n10\n" ++ lo ++ "\n20\n" ++ hi ++ "\n10\n" ++ hi ++ "\n20\n" ++ hi ++ "\n10\n" ++ hi ++ "\n20\n" ++ lo ++ "\n"
    else
        "10\n" ++ lo ++ "\n20\n" ++ lo ++ "\n10\n" ++ hi ++ "\n20\n" ++ lo ++ "\n10\n" ++ hi ++ "\n20\n" ++ hi ++ "\n10\n" ++ lo ++ "\n20\n" ++ hi ++ "\n";
    return "0\nLWPOLYLINE\n8\n" ++ layer ++ "\n90\n4\n70\n1\n" ++ corners;
}

/// A 20 mm plate (drawn clockwise) with a 10 mm hole, a 4 mm island in the hole, and a
/// 2 mm square of its own beside it on the layer "tabs".
const PLATE = file(square("cut", "0", "20", true) ++ square("cut", "5", "15", false) ++ square("cut", "8", "12", false) ++ square("tabs", "30", "32", false));

/// Two lines and a half circle 0.001 apart where they should meet.
const GAPPED = file("0\nLINE\n10\n0\n20\n0\n11\n10\n21\n0\n" ++ "0\nARC\n10\n10\n20\n5\n40\n5\n50\n270\n51\n90\n" ++ "0\nLINE\n10\n10.001\n20\n10\n11\n0\n21\n10\n" ++ "0\nLINE\n10\n0\n20\n10\n11\n0\n21\n0\n");

test "import_dxf: the outlines fill by nesting, a hole's island filled again, either way round" {
    const files = &.{ support.ScriptFile{ .path = "plate.dxf", .data = PLATE }, support.ScriptFile{ .path = "plate.txt", .data = PLATE } };
    try expectScripts(&.{
        .{ .src = "r = import_dxf(\"plate.dxf\").area", .expected = .{ .num = 400 - 100 + 16 + 4 }, .files = files },
        .{ .src = "import plate from \"./plate.dxf\"\nr = plate.bbox.size", .expected = .{ .nums = &.{ 32, 32, 0 } }, .files = files },
        .{ .src = "import plate from \"./plate.txt\" with { type: \"dxf\" }\nr = plate.area", .expected = .{ .num = 320 }, .files = files },
        .{ .src = "r = import_dxf(\"plate.dxf\", layers: \"tabs\").area", .expected = .{ .num = 4 }, .files = files },
        .{ .src = "r = import_dxf(\"plate.dxf\", layers: [\"cut\", :tabs]).area", .expected = .{ .num = 320 }, .files = files },
        .{ .src = "r = \"#{import_dxf(\"plate.dxf\").class}\"", .expected = .{ .str = "CrossSection" }, .files = files },
    });
}

test "import_dxf: ends further apart than the tolerance don't meet, closer ones do" {
    const files = &.{support.ScriptFile{ .path = "gapped.dxf", .data = GAPPED }};
    try expectScripts(&.{
        .{ .src = comptime rescued("import_dxf(\"gapped.dxf\")"), .expected = .{ .str = "ImportError: could not read DXF file 'gapped.dxf': an outline on layer '0' doesn't close: it runs from [10.001, 10] to [10.000000000000002, 10], 0.0009999999999976694 apart (import_dxf(path, tolerance:) joins ends that far apart)" }, .files = files },
        .{ .src = "v = import_dxf(\"gapped.dxf\", tolerance: 0.01).area\nr = v > 100 && v < 100 + 12.5 * Math::PI", .expected = .{ .boolean = true }, .files = files },
    });
}

test "import_dxf: what can't be read is an ImportError naming the file" {
    const files = &.{
        support.ScriptFile{ .path = "plate.dxf", .data = PLATE },
        support.ScriptFile{ .path = "notes.dxf", .data = file("0\nTEXT\n8\n0\n10\n0\n20\n0\n40\n2\n1\nhi\n") },
        support.ScriptFile{ .path = "bad.dxf", .data = "0\nSECTION\nx\n" },
    };
    try expectScripts(&.{
        .{ .src = comptime rescued("import_dxf(\"plate.dxf\", layers: \"holes\")"), .expected = .{ .str = "ImportError: DXF file 'plate.dxf' has no outline on a layer 'holes' (its layers: 'cut', 'tabs')" }, .files = files },
        .{ .src = comptime rescued("import_dxf(\"notes.dxf\")"), .expected = .{ .str = "ImportError: DXF file 'notes.dxf' has no outline to read" }, .files = files },
        .{ .src = comptime rescued("import_dxf(\"bad.dxf\")"), .expected = .{ .str = "ImportError: could not read DXF file 'bad.dxf': line 3: 'x' isn't a group code (an ASCII DXF file alternates codes and values)" }, .files = files },
        .{ .src = comptime rescued("import_dxf(\"missing.dxf\")"), .expected = .{ .str = "ImportError: could not read DXF file 'missing.dxf': FileNotFound" }, .files = files },
        .{ .src = comptime rescued("import_dxf()"), .expected = .{ .str = "ArgumentError: import_dxf expects the path of a DXF file" } },
        .{ .src = comptime rescued("import_dxf(\"plate.dxf\", tolerance: 0)"), .expected = .{ .str = "ValueError: import_dxf expects tolerance to be a finite number greater than zero, got 0" }, .files = files },
        .{ .src = comptime rescued("import_dxf(\"plate.dxf\", layers: [1])"), .expected = .{ .str = "TypeError: import_dxf expects a String or Symbol for a layer of layers, got Number" }, .files = files },
    });
}
