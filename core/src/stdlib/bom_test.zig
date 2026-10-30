//! The parts list (bom.zig): Solids grouped into parts by shape under their placement, with
//! the names `named` gives and the masses `material(density:)` makes.

const std = @import("std");
const testing = std.testing;
const support = @import("../test_support.zig");

const MOUNT =
    \\bolt = cylinder(r: 1.5, h: 20).named("M3 bolt")
    \\plate = cube(x: 40, y: 30, z: 3).named("plate")
    \\bolts = [[5, 5], [35, 5], [5, 25], [35, 25]].map { |p| bolt.translate(p[0], p[1], 0) }
    \\model = assemble(name: "Mount", parts: [plate] + bolts + [bolt.rotate(90, 0, 0)])
;

/// Each part of `model`'s list as "name xCOUNT", joined with "; ".
fn listing(comptime model: []const u8) []const u8 {
    return model ++ "\nr = model.bom.map { |p| \"#{p[:name]} x#{p[:count]}\" }.join(\"; \")";
}

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

test "bom: a sketch carries its name and material through its moves, for a drawing" {
    // `named` and `material` were a Solid's alone, so a 2D export had nothing to call or
    // colour a sketch by.
    const source =
        \\hole = circle(r: 1).material(color: "#FF0000", alpha: 0.5).named("hole").translate(x: 2).rotate(45)
        \\renamed = hole.named("slot")
        \\grown = hole.offset(1)
        \\plain = square(1)
        \\solid = hole.extrude(1)
    ;
    var vm = try support.initVm();
    defer vm.deinit();
    try std.testing.expectEqual(.ok, try support.runOn(&vm, source));
    const parts = @import("../exporters/parts.zig");
    const hole = parts.sketchLabel(&vm, vm.globals.get("hole").?);
    try testing.expectEqualStrings("hole", hole.name.?);
    try testing.expectEqual([3]u8{ 0xFF, 0, 0 }, hole.material.?.rgb);
    try testing.expectEqual(@as(f64, 0.5), hole.material.?.alpha);
    // The outermost name wins; another shape (an offset) has no label; a plain sketch none
    try testing.expectEqualStrings("slot", parts.sketchLabel(&vm, vm.globals.get("renamed").?).name.?);
    try testing.expectEqual(@as(?[]const u8, null), parts.sketchLabel(&vm, vm.globals.get("grown").?).name);
    try testing.expectEqual(@as(?[]const u8, null), parts.sketchLabel(&vm, vm.globals.get("plain").?).name);
    // A sketch's label isn't the Solid extruded from it
    try support.expectScripts(&.{
        .{ .src = source ++ "\nr = solid.bom[0][:name]", .expected = .nil },
        .{ .src = source ++ "\nr = \"#{hole.class} #{renamed.class} #{solid.volume > 2}\"", .expected = .{ .str = "Sketch Sketch true" } },
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

test "bom: a highlighted part is still its part: its copies, its density and its mass" {
    // The highlight's material took the part's place: its mass was an error, and a
    // highlighted copy was a part of its own
    try support.expectScripts(&.{
        .{ .src = listing("bolt = cylinder(r: 1, h: 5).named(\"bolt\").material(density: 7.85)\nmodel = assemble(name: \"m\", parts: [bolt, bolt.translate(x: 5).highlight])"), .expected = .{ .str = "bolt x2" } },
        .{ .src = "r = cube(10).material(density: 7.85).highlight.mass", .expected = .{ .num = 7.85 } },
    });
}

test "bom: a highlight keeps the part's material, its colour for an export, with the role" {
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try support.runOn(&vm, "lit = cube(1).material(color: \"#FF0000\").highlight"));
    const parts = @import("../exporters/parts.zig");
    const made_of = parts.materialOf(&vm, vm.globals.get("lit").?).?;
    try testing.expectEqual([3]u8{ 0xFF, 0, 0 }, made_of.rgb);
    try testing.expectEqual(.highlight, made_of.role);
}

test "bom: every value it makes stays rooted while the parts are measured" {
    try support.expectScripts(&.{.{ .src = listing(MOUNT), .expected = .{ .str = "plate x1; M3 bolt x5" }, .gc_stress = true }});
}

test "bom: what it can't take is an error saying why" {
    try support.expectScripts(&.{
        .{ .src = support.rescued("cube(1).named(\"  \")"), .expected = .{ .str = "ValueError: named expects a name, got \"  \"" } },
        .{ .src = support.rescued("square(1).bom"), .expected = .{ .str = "NoMethodError: undefined method 'bom' for Sketch" } },
        .{ .src = support.rescued("cube(1).material(density: 0)"), .expected = .{ .str = "ValueError: material expects density (g/cm³) to be a finite number greater than zero, got 0" } },
        .{ .src = support.rescued("CAD.with_config(engine: :brep) { cube(1).bom }"), .expected = .{ .str = "NotImplementedError: the brep engine can't measure volume yet; build this part with engine: :manifold" } },
    });
}
