//! import_stl and import_obj: a mesh file's Solid.

const std = @import("std");
const support = @import("../test_support.zig");
const expectScripts = support.expectScripts;
const rescued = support.rescued;

/// A cube of `size` from (`x`, 0, 0) as an OBJ object named `name`: its corners in
/// obj_read_test's order, its faces naming them back from the last vertex, so cubes can
/// follow one another in a file.
fn cube(comptime name: []const u8, comptime x: f64, comptime size: f64) []const u8 {
    const x1 = x + size;
    const corners = std.fmt.comptimePrint("v {d} 0 0\nv {d} 0 0\nv {d} {d} 0\nv {d} {d} 0\nv {d} 0 {d}\nv {d} 0 {d}\nv {d} {d} {d}\nv {d} {d} {d}\n", .{ x, x1, x1, size, x, size, x, size, x1, size, x1, size, size, x, size, size });
    return "o " ++ name ++ "\n" ++ corners ++ "f -8 -5 -6 -7\nf -4 -3 -2 -1\nf -8 -7 -3 -4\nf -6 -5 -1 -2\nf -5 -8 -4 -1\nf -7 -6 -2 -3\n";
}

test "import_obj: an OBJ file's faces are a Solid, each object a mesh, united" {
    const files = &.{
        support.ScriptFile{ .path = "cube.obj", .data = comptime cube("box", 0, 2) },
        // Two cubes of 2 that overlap by 1 along x: 8 + 8 - 4
        support.ScriptFile{ .path = "pair.obj", .data = comptime cube("a", 0, 2) ++ cube("b", 1, 2) },
        support.ScriptFile{ .path = "part.mesh", .data = comptime cube("box", 0, 2) },
        support.ScriptFile{ .path = "bad.obj", .data = "v 0 0 0\nf 1 2 3\n" },
    };
    try expectScripts(&.{
        .{ .src = "r = import_obj(\"cube.obj\").volume", .expected = .{ .num = 8 }, .files = files },
        .{ .src = "r = import_obj(\"pair.obj\").volume", .expected = .{ .num = 12 }, .files = files },
        .{ .src = "import box from \"./cube.obj\"\nr = box.bbox.size", .expected = .{ .nums = &.{ 2, 2, 2 } }, .files = files },
        .{ .src = "import box from \"./part.mesh\" with { type: \"obj\" }\nr = box.volume", .expected = .{ .num = 8 }, .files = files },
        .{ .src = comptime rescued("import_obj(\"bad.obj\")"), .expected = .{ .str = "ImportError: could not read OBJ file 'bad.obj': line 2: a face names vertex 2, and the file has 1" }, .files = files },
        // What export_obj writes reads back as the same solid (each face with its normal; the
        // writer keeps a float's digits)
        .{ .src = "p = cube(10) - cylinder(r: 2, h: 30, center: true, segments: 16)\np.export_obj(\"p.obj\")\nr = (import_obj(\"p.obj\").volume - p.volume).abs < 1e-3", .expected = .{ .boolean = true }, .files = files },
        .{ .src = comptime rescued("import_obj(\"missing.obj\")"), .expected = .{ .str = "ImportError: could not read OBJ file 'missing.obj': FileNotFound" }, .files = files },
    });
}

test "import_3mf: what a 3MF package's build places is a Solid, each copy where it is placed" {
    const zip = @import("../exporters/zip.zig");
    const cube_model = "<model unit=\"centimeter\"><resources><object id=\"1\"><mesh><vertices>" ++
        "<vertex x=\"0\" y=\"0\" z=\"0\"/><vertex x=\"1\" y=\"0\" z=\"0\"/><vertex x=\"1\" y=\"1\" z=\"0\"/><vertex x=\"0\" y=\"1\" z=\"0\"/>" ++
        "<vertex x=\"0\" y=\"0\" z=\"1\"/><vertex x=\"1\" y=\"0\" z=\"1\"/><vertex x=\"1\" y=\"1\" z=\"1\"/><vertex x=\"0\" y=\"1\" z=\"1\"/></vertices><triangles>" ++
        "<triangle v1=\"0\" v2=\"3\" v3=\"2\"/><triangle v1=\"0\" v2=\"2\" v3=\"1\"/><triangle v1=\"4\" v2=\"5\" v3=\"6\"/><triangle v1=\"4\" v2=\"6\" v3=\"7\"/>" ++
        "<triangle v1=\"0\" v2=\"1\" v3=\"5\"/><triangle v1=\"0\" v2=\"5\" v3=\"4\"/><triangle v1=\"2\" v2=\"3\" v3=\"7\"/><triangle v1=\"2\" v2=\"7\" v3=\"6\"/>" ++
        "<triangle v1=\"3\" v2=\"0\" v3=\"4\"/><triangle v1=\"3\" v2=\"4\" v3=\"7\"/><triangle v1=\"1\" v2=\"2\" v3=\"6\"/><triangle v1=\"1\" v2=\"6\" v3=\"5\"/>" ++
        "</triangles></mesh></object></resources><build><item objectid=\"1\"/><item objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 3 0 0\"/></build></model>";
    const package = try zip.write(std.testing.allocator, &.{.{ .name = "3D/3dmodel.model", .data = cube_model }});
    defer std.testing.allocator.free(package);
    const files = &.{ support.ScriptFile{ .path = "cubes.3mf", .data = package }, support.ScriptFile{ .path = "junk.3mf", .data = "not a zip" } };
    try expectScripts(&.{
        // Two cubes of 1 cm, 3 cm apart
        .{ .src = "r = import_3mf(\"cubes.3mf\").volume", .expected = .{ .num = 2000 }, .files = files },
        .{ .src = "import cubes from \"./cubes.3mf\"\nr = cubes.bbox.size", .expected = .{ .nums = &.{ 40, 10, 10 } }, .files = files },
        // What export_3mf writes, each part once and each copy an item, reads back as it was
        .{ .src = "b = cylinder(r: 2, h: 5, segments: 12)\nassemble(name: \"set\", parts: [b, b.translate(x: 10), cube(3).translate(y: 8)]).export_3mf(\"p.3mf\")\nr = (import_3mf(\"p.3mf\").volume - (b + b.translate(x: 10) + cube(3).translate(y: 8)).volume).abs < 1e-3", .expected = .{ .boolean = true }, .files = files },
        .{ .src = comptime rescued("import_3mf(\"junk.3mf\")"), .expected = .{ .str = "ImportError: could not read 3MF file 'junk.3mf': it isn't a zip archive, which a 3MF package is" }, .files = files },
    });
}
