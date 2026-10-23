const std = @import("std");
const testing = std.testing;
const lint_testing = @import("../testing.zig");

/// The one suggestion the single finding of `rule_id` in `source` makes, applied.
fn suggested(comptime rule_id: []const u8, source: []const u8) !?[]u8 {
    var engine = try lint_testing.lint(testing.allocator, source, lint_testing.only(rule_id));
    defer engine.deinit();
    try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
    const fix = engine.diagnostics.items[0].fix orelse return null;
    try testing.expect(!fix.safe); // a guess at the intent: offered, never applied by --fix
    try testing.expectEqual(@as(usize, 1), fix.edits.len);
    const e = fix.edits[0];
    return try std.mem.concat(testing.allocator, u8, &.{ source[0..e.offset], e.replacement, source[e.offset + e.length ..] });
}

test "Lint: unknown-keyword suggests the nearest keyword, when one is clearly nearest" {
    const fixed = (try suggested("unknown-keyword", "cube(sise: 3)")).?;
    defer testing.allocator.free(fixed);
    try testing.expectEqualStrings("cube(size: 3)", fixed);
    try testing.expectEqual(@as(?[]u8, null), try suggested("unknown-keyword", "sphere(r: 2, colour: 1)"));
}

test "Lint: shape-mismatch names the kind a method or operator belongs to" {
    const cases = [_]struct { source: []const u8, message: ?[]const u8 }{
        .{ .source = "p = line([0, 0], [1, 0])\np.extrude(1)", .message = "extrude isn't a Path's method: a Path is open and encloses nothing: close it (.close) into a Sketch or give it a width (.stroke(w)) first" },
        .{ .source = "s = square(1)\ns.genus", .message = "genus isn't a Sketch's method (a Solid's), so this fails when the script runs" },
        .{ .source = "c = cube(1)\nc.extrude(1)", .message = "extrude isn't a Solid's method (a Sketch's), so this fails when the script runs" },
        .{ .source = "c = cube(1)\nc.close", .message = "close isn't a Solid's method (a Path's), so this fails when the script runs" },
        // A file's import is what its built-in gives: a drawing's a Sketch, unless paths:
        // true asks for its open lines (an Array); a mesh's a Solid
        .{ .source = "logo = import_svg(\"logo.svg\")\nlogo.volume", .message = "volume isn't a Sketch's method (a Solid's), so this fails when the script runs" },
        .{ .source = "import logo from \"./logo.svg\"\nlogo.genus", .message = "genus isn't a Sketch's method (a Solid's), so this fails when the script runs" },
        .{ .source = "import bolt from \"./bolt.stl\"\nbolt.extrude(1)", .message = "extrude isn't a Solid's method (a Sketch's), so this fails when the script runs" },
        .{ .source = "plate = import_dxf(\"plate.dxf\", paths: false)\nplate.volume", .message = "volume isn't a Sketch's method (a Solid's), so this fails when the script runs" },
        .{ .source = "lines = import_svg(\"logo.svg\", paths: true)\nlines.volume", .message = null },
        .{ .source = "open = true\nlines = import_dxf(\"plate.dxf\", paths: open)\nlines.volume", .message = null },
        .{ .source = "p = line([0, 0], [1, 0])\nsquare(1) - p", .message = "'-' can't combine a Path and a Sketch: a Path is open and encloses nothing: close it (.close) into a Sketch or give it a width (.stroke(w)) first" },
        .{ .source = "p = line([0, 0], [1, 0])\np & p", .message = "'&' can't combine two Paths: '+' joins them where one ends and the next starts" },
        // A join, a Path's own methods, and a method on an object of the script's own
        .{ .source = "p = line([0, 0], [1, 0])\np + p.translate(x: 1)\np.close.extrude(1)\np.stroke(1)", .message = null },
        .{ .source = "class Hook\n  def extrude(h)\n    h\n  end\nend\nHook.new.extrude(1)", .message = null },
    };
    for (cases) |case| {
        errdefer std.debug.print("source: {s}\n", .{case.source});
        var engine = try lint_testing.lint(testing.allocator, case.source, lint_testing.only("shape-mismatch"));
        defer engine.deinit();
        if (case.message) |message| {
            try testing.expectEqual(@as(usize, 1), engine.diagnostics.items.len);
            try testing.expectEqualStrings(message, engine.diagnostics.items[0].message);
        } else try testing.expectEqual(@as(usize, 0), engine.diagnostics.items.len);
    }
}

test "Lint: segments-as-sides suggests sides:, except with round_r: or chamfer:" {
    const fixed = (try suggested("segments-as-sides", "cylinder(d: 8, h: 5, segments: 6)")).?;
    defer testing.allocator.free(fixed);
    try testing.expectEqualStrings("cylinder(d: 8, h: 5, sides: 6)", fixed);
    try testing.expectEqual(@as(?[]u8, null), try suggested("segments-as-sides", "cylinder(r: 5, h: 9, segments: 6, chamfer: 1)"));
}
