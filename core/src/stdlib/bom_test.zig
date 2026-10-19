//! The parts list (bom.zig): Solids grouped into parts by shape under their placement, with
//! the names `named` gives and the masses `material(density:)` makes.

const std = @import("std");
const testing = std.testing;
const support = @import("../test_support.zig");

/// Each part of `model`'s list as "name xCOUNT", joined with "; ".
fn listing(comptime model: []const u8) []const u8 {
    return model ++ "\nr = model.bom.map { |p| \"#{p[:name]} x#{p[:count]}\" }.join(\"; \")";
}

const MOUNT =
    \\bolt = cylinder(r: 1.5, h: 20).named("M3 bolt")
    \\plate = cube(x: 40, y: 30, z: 3).named("plate")
    \\bolts = [[5, 5], [35, 5], [5, 25], [35, 25]].map { |p| bolt.translate(p[0], p[1], 0) }
    \\model = assemble(name: "Mount", parts: [plate] + bolts + [bolt.rotate(90, 0, 0)])
;

test "bom: copies placed by translate and rotate are one part, counted" {
    try support.expectScripts(&.{
        .{ .src = listing(MOUNT), .expected = .{ .str = "plate x1; M3 bolt x5" } },
        // Unnamed parts are grouped by shape too
        .{ .src = listing("model = assemble(name: \"m\", parts: [cube(2), cube(2).translate(5, 0, 0), cube(3)])"), .expected = .{ .str = "nil x2; nil x1" } },
    });
}

test "bom: a mirrored or scaled copy is a part of its own, with the name it was made with" {
    try support.expectScripts(&.{
        .{ .src = listing("left = cube(x: 10, y: 5, z: 5).named(\"bracket\")\nmodel = assemble(name: \"m\", parts: [left, left.mirror(1, 0, 0), left.scale(2), left.mirror(1, 0, 0).named(\"bracket R\")])"), .expected = .{ .str = "bracket x1; bracket x1; bracket x1; bracket R x1" } },
        // A union of copies is one fused Solid
        .{ .src = "r = (cube(1) + cube(1).translate(2, 0, 0)).bom.size", .expected = .{ .num = 1 } },
    });
}

test "bom: the outermost name and material are the part's, and a different one is another part" {
    try support.expectScripts(&.{
        .{ .src = "r = cube(1).named(\"a\").named(\"b\").bom[0][:name]", .expected = .{ .str = "b" } },
        .{ .src = "r = cube(1).named(\"a\").translate(1, 0, 0).bom[0][:name]", .expected = .{ .str = "a" } },
        .{ .src = listing("c = cube(2).named(\"block\")\nmodel = assemble(name: \"m\", parts: [c.material(color: \"#FF0000\"), c.material(color: \"#0000FF\"), c.material(color: \"#FF0000\")])"), .expected = .{ .str = "block x2; block x1" } },
    });
}

test "bom: a part's volume and size are its shape's, its mass the volume times its density" {
    try support.expectScripts(&.{
        .{ .src = "p = cube(x: 10, y: 20, z: 5).rotate(0, 0, 90).bom[0]\nr = p[:size] + [p[:volume]]", .expected = .{ .nums = &.{ 10, 20, 5, 1000 } } },
        // 1000 mm³ of 7.85 g/cm³
        .{ .src = "p = cube(10).material(density: 7.85).bom[0]\nr = [p[:density], p[:mass]]", .expected = .{ .nums = &.{ 7.85, 7.85 } } },
        .{ .src = "p = cube(10).bom[0]\nr = p[:density] == nil && p[:mass] == nil", .expected = .{ .boolean = true } },
        // A name and a material change nothing a viewport shows
        .{ .src = "r = cube(2).named(\"x\").material(density: 1).volume", .expected = .{ .num = 8 } },
    });
}

test "bom: every value it makes stays rooted while the parts are measured" {
    try support.expectScripts(&.{.{ .src = listing(MOUNT), .expected = .{ .str = "plate x1; M3 bolt x5" }, .gc_stress = true }});
}

test "bom: what it can't take is an error saying why" {
    try support.expectScripts(&.{
        .{ .src = support.rescued("cube(1).named(\"  \")"), .expected = .{ .str = "ValueError: named expects a name, got \"  \"" } },
        .{ .src = support.rescued("square(1).named(\"x\")"), .expected = .{ .str = "NoMethodError: undefined method 'named' for CrossSection" } },
        .{ .src = support.rescued("cube(1).material(density: 0)"), .expected = .{ .str = "ValueError: material expects density (g/cm³) to be a finite number greater than zero, got 0" } },
        .{ .src = support.rescued("CAD.with_config(engine: :brep) { cube(1).bom }"), .expected = .{ .str = "NotImplementedError: the brep engine can't measure volume yet; build this part with engine: :manifold" } },
    });
}
