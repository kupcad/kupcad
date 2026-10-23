//! import_dxf and import_svg: a drawing's outlines as a Sketch, holes by nesting.

const std = @import("std");
const testing = std.testing;
const support = @import("../test_support.zig");
const path = @import("../core/path.zig");
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const dxf_read = @import("../exporters/2d/dxf_read.zig");
const svg_read = @import("../exporters/2d/svg_read.zig");
const Diagnostic = @import("../exporters/diagnostic.zig").Diagnostic;
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
        .{ .src = comptime rescued("import_dxf(\"gapped.dxf\")"), .expected = .{ .str = "ImportError: could not read DXF file 'gapped.dxf': an outline on layer '0' doesn't close: it runs from [10.001, 10] to [10.000000000000002, 10], 0.0009999999999976694 apart (import_dxf(path, tolerance:) joins ends that far apart, and paths: true reads open lines as Paths)" }, .files = files },
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

/// A 20 mm plate with a 10 mm square hole, a rounded tab beside it, and an open stroke
/// whose ends are 0.001 apart.
const LOGO = "<svg width=\"100mm\" height=\"100mm\" viewBox=\"0 0 100 100\">" ++
    "<path d=\"M0 0H20V20H0Z M5 5V15H15V5Z\"/><rect x=\"30\" y=\"0\" width=\"10\" height=\"10\" rx=\"2\"/>" ++
    "<path d=\"M50 0L60 0L60 10L50.001 0\" fill=\"none\" stroke=\"black\"/></svg>";

test "import_svg: the shapes fill by nesting, in millimetres, y turned over" {
    const files = &.{ support.ScriptFile{ .path = "logo.svg", .data = LOGO }, support.ScriptFile{ .path = "logo.xml", .data = LOGO } };
    try expectScripts(&.{
        // Measured at a resolution that draws the tab's corners as their arcs
        .{ .src = "CAD.config(resolution: {segments: 1024})\nr = (import_svg(\"logo.svg\").area - (300 + 100 - 4 * (4 - Math::PI))).abs < 1e-3", .expected = .{ .boolean = true }, .files = files },
        .{ .src = "import logo from \"./logo.svg\"\nr = [logo.bbox.min[1], logo.bbox.max[0]]", .expected = .{ .nums = &.{ -20, 40 } }, .files = files },
        .{ .src = "import logo from \"./logo.xml\" with { type: :svg }\nr = logo.area > 390", .expected = .{ .boolean = true }, .files = files },
        // The stroke's ends meet within the tolerance asked for: a thin triangle of its own
        .{ .src = "r = import_svg(\"logo.svg\", tolerance: 0.01).area > import_svg(\"logo.svg\").area", .expected = .{ .boolean = true }, .files = files },
    });
}

test "import_svg: what can't be read is an ImportError naming the file" {
    const files = &.{
        support.ScriptFile{ .path = "empty.svg", .data = "<svg><text>hi</text></svg>" },
        support.ScriptFile{ .path = "bad.svg", .data = "<svg><path d=\"M 0 0 L\"/></svg>" },
    };
    try expectScripts(&.{
        .{ .src = comptime rescued("import_svg(\"empty.svg\")"), .expected = .{ .str = "ImportError: SVG file 'empty.svg' has no outline to read" }, .files = files },
        .{ .src = comptime rescued("import_svg(\"bad.svg\")"), .expected = .{ .str = "ImportError: could not read SVG file 'bad.svg': line 1: the path data of a <path> isn't SVG's at character 8: \"\"" }, .files = files },
        .{ .src = comptime rescued("import_svg()"), .expected = .{ .str = "ArgumentError: import_svg expects the path of an SVG file" } },
        .{ .src = comptime rescued("import_svg(\"missing.svg\")"), .expected = .{ .str = "ImportError: could not read SVG file 'missing.svg': FileNotFound" }, .files = files },
        .{ .src = comptime rescued("import_svg(\"empty.svg\", layers: \"a\")"), .expected = .{ .str = "ArgumentError: import_svg does not take a keyword 'layers' (it accepts: tolerance, paths)" }, .files = files },
    });
}

/// A plate to cut out with a score line across it and an arc of one beside it.
const TEMPLATE = "<svg width=\"100mm\" height=\"100mm\" viewBox=\"0 0 100 100\">" ++
    "<rect width=\"40\" height=\"20\" style=\"fill:none;stroke:red\"/>" ++
    "<path d=\"M 20 0 V 20\" fill=\"none\" stroke=\"blue\"/><path d=\"M 5 5 A 5 5 0 0 1 15 5\" fill=\"none\"/></svg>";

test "import_dxf and import_svg: paths: true reads the open lines a Sketch can't hold as Paths" {
    const files = &.{
        support.ScriptFile{ .path = "template.svg", .data = TEMPLATE },
        support.ScriptFile{ .path = "gapped.dxf", .data = GAPPED },
        support.ScriptFile{ .path = "plate.dxf", .data = PLATE },
        support.ScriptFile{ .path = "plate.svg", .data = "<svg><rect width=\"10\" height=\"10\"/></svg>" },
    };
    try expectScripts(&.{
        // The plate's region, and its two score lines beside it, the arc's length exact
        .{ .src = "r = import_svg(\"template.svg\").area", .expected = .{ .num = 800 }, .files = files },
        .{ .src = "s = import_svg(\"template.svg\", paths: true)\nr = s.map { |p| p.length }", .expected = .{ .nums = &.{ 20, 5 * std.math.pi } }, .files = files },
        .{ .src = "r = import_svg(\"template.svg\", paths: true).map { |p| \"#{p.class}\" }.uniq.inspect", .expected = .{ .str = "[\"Path\"]" }, .files = files },
        // Each Path made while the Array of them is: a collection between them frees none
        .{ .src = "s = import_svg(\"template.svg\", paths: true)\nr = s.map { |p| p.length }", .expected = .{ .nums = &.{ 20, 5 * std.math.pi } }, .files = files, .gc_stress = true },
        // The DXF's three lines and half a circle that don't quite meet: one open line
        .{ .src = "s = import_dxf(\"gapped.dxf\", paths: true)\nr = [s.length, s[0].start[0]]", .expected = .{ .nums = &.{ 1, 10.001 } }, .files = files },
        .{ .src = comptime rescued("import_dxf(\"plate.dxf\", paths: true)"), .expected = .{ .str = "ImportError: DXF file 'plate.dxf' has no open path to read" }, .files = files },
        .{ .src = comptime rescued("import_svg(\"plate.svg\", paths: true)"), .expected = .{ .str = "ImportError: SVG file 'plate.svg' has no open path to read" }, .files = files },
    });
}

test "import_dxf and import_svg: a DXF's blocks and an SVG's clones are drawn where they are placed" {
    const bolt = "0\nBLOCK\n2\nhole\n10\n0\n20\n0\n0\nLWPOLYLINE\n70\n1\n10\n0\n20\n0\n10\n2\n20\n0\n10\n2\n20\n2\n10\n0\n20\n2\n0\nENDBLK\n";
    const dxf = comptime "0\nSECTION\n2\nBLOCKS\n" ++ bolt ++ "0\nENDSEC\n0\nSECTION\n2\nENTITIES\n" ++ square("cut", "0", "20", false) ++
        "0\nINSERT\n2\nhole\n10\n4\n20\n4\n70\n3\n44\n5\n0\nENDSEC\n0\nEOF\n";
    const svg = "<svg width=\"100mm\" height=\"100mm\" viewBox=\"0 0 100 100\"><defs><rect id=\"tab\" width=\"2\" height=\"2\"/></defs>" ++
        "<use href=\"#tab\"/><use href=\"#tab\" x=\"10\"/></svg>";
    const files = &.{ support.ScriptFile{ .path = "plate.dxf", .data = dxf }, support.ScriptFile{ .path = "tabs.svg", .data = svg } };
    try expectScripts(&.{
        // Three 2 mm holes, the block copied along a row, inside the 20 mm plate
        .{ .src = "r = import_dxf(\"plate.dxf\").area", .expected = .{ .num = 400 - 3 * 4 }, .files = files },
        .{ .src = "r = import_svg(\"tabs.svg\").area", .expected = .{ .num = 8 }, .files = files },
    });
}

/// The drawing `source`'s model is written as in `format`, with `files` in its file system;
/// owned by testing.allocator.
fn exported(source: []const u8, files: []const support.ScriptFile, format: @import("../exporters/format.zig").ExportFormat) ![]const u8 {
    var vm = try support.initVm();
    defer vm.deinit();
    var vfs = MemoryVfs.init(testing.allocator);
    defer vfs.deinit();
    for (files) |f| try vfs.vfs().writeFile(f.path, f.data);
    vm.vfs = vfs.vfs();
    try testing.expectEqual(.ok, try support.runOn(&vm, source));
    return @import("../exporters/export.zig").exportModelFromVm(testing.allocator, &vm, format, .{});
}

/// The one cubic of `outline`, its ends and controls in order.
fn cubicOf(outline: path.Run) ![4][2]f64 {
    var from = outline.start;
    for (outline.segments) |segment| {
        if (segment.cubic) |c| return .{ from, c.c1, c.c2, segment.to };
        from = segment.to;
    }
    return error.NoCubic;
}

/// `got`'s cubic is `want`'s, either way round (the kernel starts an outline where it will).
fn expectSameCubic(want: path.Run, got: path.Run) !void {
    const w = try cubicOf(want);
    var g = try cubicOf(got);
    if (std.math.hypot(w[0][0] - g[0][0], w[0][1] - g[0][1]) > 1e-6) std.mem.reverse([2]f64, &g);
    for (w, g) |a, b| {
        try testing.expectApproxEqAbs(a[0], b[0], 1e-6);
        try testing.expectApproxEqAbs(a[1], b[1], 1e-6);
    }
}

test "import_dxf and import_svg: a curve read is written back as the same curve" {
    // A bump of one cubic over a line, as an SVG path and as a DXF spline
    const svg = "<svg width=\"100mm\" height=\"100mm\" viewBox=\"0 0 100 100\"><path d=\"M0 50C0 40 10 40 10 50Z\"/></svg>";
    const dxf = file("0\nSPLINE\n71\n3\n40\n0\n40\n0\n40\n0\n40\n0\n40\n1\n40\n1\n40\n1\n40\n1\n10\n0\n20\n0\n10\n0\n20\n10\n10\n10\n20\n10\n10\n10\n20\n0\n" ++
        "0\nLINE\n10\n10\n20\n0\n11\n0\n21\n0\n");
    const files = &.{ support.ScriptFile{ .path = "bump.svg", .data = svg }, support.ScriptFile{ .path = "bump.dxf", .data = dxf } };

    var diag: Diagnostic = .{};
    var svg_in = try svg_read.read(testing.allocator, svg, .{ .tolerance = 1e-6 }, &diag);
    defer svg_in.deinit();
    const svg_out = try exported("import_svg(\"bump.svg\")", files, .svg);
    defer testing.allocator.free(svg_out);
    var svg_back = try svg_read.read(testing.allocator, svg_out, .{ .tolerance = 1e-6 }, &diag);
    defer svg_back.deinit();
    try expectSameCubic(svg_in.outlines[0], svg_back.outlines[0]);

    var dxf_in = try dxf_read.read(testing.allocator, dxf, .{ .tolerance = 1e-6 }, &diag);
    defer dxf_in.deinit();
    const dxf_out = try exported("import_dxf(\"bump.dxf\")", files, .dxf);
    defer testing.allocator.free(dxf_out);
    var dxf_back = try dxf_read.read(testing.allocator, dxf_out, .{ .tolerance = 1e-6 }, &diag);
    defer dxf_back.deinit();
    try expectSameCubic(dxf_in.outlines[0], dxf_back.outlines[0]);
}

test "import_svg: an open path's curve is a Path's cubic, which its methods follow" {
    // A cubic of 10 across bulging 7.5 down the page (up in the drawing), then 10 on
    const svg = "<svg width=\"100mm\" height=\"100mm\" viewBox=\"0 0 100 100\"><path d=\"M0 50C0 40 10 40 10 50L20 50\" fill=\"none\"/></svg>";
    const files = &.{support.ScriptFile{ .path = "curve.svg", .data = svg }};
    try expectScripts(&.{
        // Longer than its chord, shorter than its control polygon
        .{ .src = "p = import_svg(\"curve.svg\", paths: true)[0]\nr = p.length > 20 && p.length < 40", .expected = .{ .boolean = true }, .files = files },
        .{ .src = "r = import_svg(\"curve.svg\", paths: true)[0].bbox.max[1]", .expected = .{ .num = -42.5 }, .files = files },
        // Closed, the cubic's area over its chord (6/10 of 10 by 10, the line back along it adding none)
        .{ .src = "CAD.config(resolution: {segments: 1024})\nr = (import_svg(\"curve.svg\", paths: true)[0].close.area - 60).abs < 1e-3", .expected = .{ .boolean = true }, .files = files },
        .{ .src = "r = import_svg(\"curve.svg\", paths: true)[0].stroke(1).area > 20", .expected = .{ .boolean = true }, .files = files },
        .{ .src = "r = import_svg(\"curve.svg\", paths: true)[0].scale(x: 2, y: 1).bbox.size[0]", .expected = .{ .num = 40 }, .files = files },
        // Swept along its chords, the curve's tube as long as the path, about
        .{ .src = "p = import_svg(\"curve.svg\", paths: true)[0]\nv = square(1, center: true).sweep(p).volume\nr = (v - p.length).abs < 0.05 * p.length", .expected = .{ .boolean = true }, .files = files },
    });
}
