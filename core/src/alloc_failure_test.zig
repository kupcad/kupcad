//! Every allocation of a build (in each export format), a format, a check, a run under GC
//! stress, a DAG evaluation, a parts list, each importer's reading and the package manager's
//! files, failed in turn (test_support.expectAllocationFailuresHandled): each must free what it
//! allocated and either fail or give what an unfailed run gives.

const std = @import("std");
const testing = std.testing;
const api = @import("api.zig");
const support = @import("test_support.zig");
const registry = @import("stdlib/registry.zig");
const VM = @import("vm/vm.zig").VM;
const obj_read = @import("exporters/3d/obj_read.zig");
const stl = @import("exporters/3d/stl.zig");
const threemf_read = @import("exporters/3d/threemf_read.zig");
const svg_read = @import("exporters/2d/svg_read.zig");
const dxf_read = @import("exporters/2d/dxf_read.zig");
const json_input = @import("core/json_input.zig");
const MemoryVfs = @import("vfs/memory.zig").MemoryVfs;
const Lockfile = @import("pkg/lockfile.zig").Lockfile;
const Manifest = @import("pkg/manifest.zig").Manifest;

const BuildCase = struct {
    source: []const u8,
    format: api.ExportFormat,
    draco: bool = false,
};

fn build(case: BuildCase, allocator: std.mem.Allocator) anyerror![]const u8 {
    var diagnostic: api.BuildDiagnostic = .{};
    defer diagnostic.deinit(allocator);
    return api.buildModel(allocator, testing.io, case.source, .{ .format = case.format, .draco = case.draco, .diagnostic = &diagnostic });
}

test "allocation failures: build" {
    try support.expectAllocationFailuresHandled(BuildCase{ .source = "cube(2) + sphere(1, segments: 8)", .format = .stl }, build);
}

fn format(source: []const u8, allocator: std.mem.Allocator) anyerror![]const u8 {
    return api.formatCode(allocator, source, .{});
}

test "allocation failures: format" {
    // With comments, which the formatter keeps (document_test.zig fails the one keeping them)
    try support.expectAllocationFailuresHandled(@as([]const u8, "# note\ndef f(a, b)\n  [a,b].map { |x| x*2 } # twice\nend\nr = {k: f(1, 2), \"s\" => 'q'}\n"), format);
}

test "allocation failures: build every format" {
    const parts = "[cube(2).material(color: \"#FF0000\"), sphere(1, segments: 8).translate(x: 4), (cube(2) - cylinder(r: 0.5, h: 5)).translate(y: 4)]";
    // STEP is exact geometry, which the B-Rep engine builds: a hull of flat solids.
    const exact_part = "CAD.config(engine: :brep)\nbatch_hull([cube(6, 6, 1, center: true), cube(2, 2, 4, center: true)])";
    // A drawing of Sketches, for the 2D formats
    const sketches = "[square(4).named(\"plate\"), circle(2, segments: 12).translate(x: 6), square(3) - circle(1, segments: 8)]";
    for ([_]BuildCase{
        .{ .source = parts, .format = .glb },
        .{ .source = parts, .format = .gltf, .draco = true },
        .{ .source = exact_part, .format = .step },
        .{ .source = parts, .format = .obj },
        .{ .source = parts, .format = .@"3mf" },
        .{ .source = sketches, .format = .svg },
        .{ .source = sketches, .format = .dxf },
    }) |case| {
        errdefer std.debug.print("format: {s}\n", .{@tagName(case.format)});
        try support.expectAllocationFailuresHandled(case, build);
    }
}

fn check(source: []const u8, allocator: std.mem.Allocator) anyerror![]const u8 {
    const diagnostics = try api.checkCode(allocator, testing.io, source, .{});
    defer api.freeDiagnostics(allocator, diagnostics);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (diagnostics) |d| try out.writer.print("{d}:{d} {s} {s} fix={}\n", .{ d.loc.offset, d.loc.length, d.code(), d.message, d.fix != null });
    return out.toOwnedSlice();
}

test "allocation failures: check" {
    // Unused variables (with fixes), an unknown keyword, a negative size, dead code and a
    // syntax error, whose message the linter copies (the copy leaked when keeping it failed).
    const source =
        \\x = )
        \\unused = 5
        \\def f(a)
        \\  return a
        \\  puts(a)
        \\end
        \\cube(sise: 3)
        \\cube(-2)
    ;
    try support.expectAllocationFailuresHandled(@as([]const u8, source), check);
}

const RunCase = struct {
    source: []const u8,
    gc_stress: bool = false,
};

/// Runs the script on a VM of its own and gives back `r`, inspected.
fn runScript(case: RunCase, allocator: std.mem.Allocator) anyerror![]const u8 {
    var vm = try VM.init(allocator, testing.io);
    defer vm.deinit();
    vm.mute_errors = true;
    try registry.registerStandardLibrary(&vm);
    vm.host.print_handler = null;
    vm.gc.stress = case.gc_stress;
    if (try support.runWith(allocator, &vm, case.source) != .ok) return error.RuntimeError;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try (vm.globals.get("r") orelse return error.MissingGlobal).stringify(true, &out.writer);
    return out.toOwnedSlice();
}

test "allocation failures: a run that collects at every allocation" {
    // Strings (each native that makes one from bytes it built), arrays, maps, closures and
    // instances, each allocation a collection.
    const source =
        \\class P
        \\  def initialize(x)
        \\    @x = x
        \\  end
        \\  def x
        \\    @x
        \\  end
        \\end
        \\add = ->(a, b) { a + b }
        \\items = (1..6).map { |i| P.new(i) }
        \\m = { "sum" => items.map { |p| p.x }.reduce(0) { |s, v| add.call(s, v) } }
        \\r = ("Total #{m["sum"]}: " + items.map { |p| p.x.to_s }.join(",")).upcase.replace("TOTAL", "Sum").downcase
    ;
    try support.expectAllocationFailuresHandled(RunCase{ .source = source, .gc_stress = true }, runScript);
}

test "allocation failures: building and evaluating a DAG" {
    // Booleans, transforms and a pattern, evaluated by measuring the result.
    const source =
        \\body = cube(4) + sphere(1.5, segments: 8).translate(x: 2, y: 2, z: 4)
        \\holes = cylinder(r: 0.5, h: 10, segments: 8).repeat_linear(3, [1, 0, 0])
        \\part = (body - holes.translate(x: 1, y: 2, z: -1)).rotate(z: 30).scale(2)
        \\r = [part.volume.round(3), part.bbox.size.map { |v| v.round(3) }]
    ;
    try support.expectAllocationFailuresHandled(RunCase{ .source = source }, runScript);
}

test "allocation failures: a parts list" {
    // Copies counted by name, materials and masses: what `kupcad build --bom` writes
    const source =
        \\bolt = cylinder(r: 1, h: 5, segments: 8).named("bolt").material(color: "#999999", density: 7.8)
        \\kit = assemble(name: "kit", parts: [bolt, bolt.translate(x: 3), cube(2).named("plate")])
        \\r = kit.bom
    ;
    try support.expectAllocationFailuresHandled(RunCase{ .source = source }, runScript);
}

const ImportCase = struct {
    format: enum { obj, stl, @"3mf", svg, dxf, json },
    bytes: []const u8,
};

/// What `case.bytes` read as: each mesh's or outline's size, or the JSON written again.
fn readImport(case: ImportCase, allocator: std.mem.Allocator) anyerror![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    switch (case.format) {
        .obj => {
            var diag: obj_read.Diagnostic = .{};
            var model = try obj_read.read(allocator, case.bytes, &diag);
            defer model.deinit();
            for (model.objects) |o| try w.print("{s}: {d} points, {d} faces\n", .{ o.name, o.mesh.points.len, o.mesh.faces.len });
        },
        .stl => {
            var diag: stl.Diagnostic = .{};
            const mesh = try stl.parseStlBuffer(allocator, case.bytes, &diag);
            defer mesh.deinit(allocator);
            try w.print("{d} points, {d} faces\n", .{ mesh.points.len, mesh.faces.len });
        },
        .@"3mf" => {
            var diag: threemf_read.Diagnostic = .{};
            var model = try threemf_read.read(allocator, case.bytes, .{}, &diag);
            defer model.deinit();
            for (model.meshes) |m| try w.print("{d} points, {d} faces\n", .{ m.points.len, m.faces.len });
        },
        .svg => {
            var diag: svg_read.Diagnostic = .{};
            var drawing = try svg_read.read(allocator, case.bytes, .{ .tolerance = 1e-6 }, &diag);
            defer drawing.deinit();
            for (drawing.outlines) |o| try w.print("outline of {d}\n", .{o.segments.len});
            for (drawing.open_paths) |o| try w.print("open path of {d}\n", .{o.segments.len});
        },
        .dxf => {
            var diag: dxf_read.Diagnostic = .{};
            var drawing = try dxf_read.read(allocator, case.bytes, .{ .tolerance = 1e-6 }, &diag);
            defer drawing.deinit();
            for (drawing.outlines) |o| try w.print("outline of {d}\n", .{o.segments.len});
        },
        .json => {
            const parsed = try json_input.parse(std.json.Value, allocator, case.bytes, null);
            defer parsed.deinit();
            try std.json.Stringify.value(parsed.value, .{}, w);
        },
    }
    return out.toOwnedSlice();
}

test "allocation failures: reading each format a script imports" {
    // The 3MF a build writes: two objects, one placed twice
    var diagnostic: api.BuildDiagnostic = .{};
    defer diagnostic.deinit(testing.allocator);
    const package = try api.buildModel(testing.allocator, testing.io, "b = cube(1).named(\"b\")\nassemble(name: \"k\", parts: [b, b.translate(x: 2), sphere(1, segments: 8).named(\"s\")])", .{ .format = .@"3mf", .diagnostic = &diagnostic });
    defer testing.allocator.free(package);
    const tetrahedron = "solid t\n" ++
        "facet normal 0 0 -1\nouter loop\nvertex 0 0 0\nvertex 0 1 0\nvertex 1 0 0\nendloop\nendfacet\n" ++
        "facet normal 0 -1 0\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 0 1\nendloop\nendfacet\n" ++
        "facet normal -1 0 0\nouter loop\nvertex 0 0 0\nvertex 0 0 1\nvertex 0 1 0\nendloop\nendfacet\n" ++
        "facet normal 1 1 1\nouter loop\nvertex 1 0 0\nvertex 0 1 0\nvertex 0 0 1\nendloop\nendfacet\nendsolid t\n";
    for ([_]ImportCase{
        .{ .format = .obj, .bytes = "o a\nv 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\no b\nv 0 0 1\nv 1 0 1\nv 0 1 1\nf -3 -2 -1\n" },
        .{ .format = .stl, .bytes = tetrahedron },
        .{ .format = .@"3mf", .bytes = package },
        .{ .format = .svg, .bytes = "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"10\" height=\"5\"/><circle cx=\"20\" cy=\"5\" r=\"3\"/><path d=\"M0 20 L10 20 Q15 25 10 30 Z M0 40 L5 45\" fill=\"none\"/></svg>" },
        .{ .format = .dxf, .bytes = "0\nSECTION\n2\nENTITIES\n0\nLWPOLYLINE\n8\n0\n90\n4\n70\n1\n10\n0\n20\n0\n42\n0.5\n10\n10\n20\n0\n10\n10\n20\n5\n10\n0\n20\n5\n0\nCIRCLE\n8\n0\n10\n20\n20\n0\n40\n2\n0\nENDSEC\n0\nEOF\n" },
        .{ .format = .json, .bytes = "{\"w\": 5, \"parts\": [{\"name\": \"a\", \"size\": [1, 2.5, 3]}, null, true], \"note\": \"x\\u00e9\"}" },
    }) |case| {
        errdefer std.debug.print("format: {s}\n", .{@tagName(case.format)});
        try support.expectAllocationFailuresHandled(case, readImport);
    }
}

/// The package manager's files read and the lockfile written again, on a file system of its own.
fn packageFiles(_: void, allocator: std.mem.Allocator) anyerror![]const u8 {
    var disk = MemoryVfs.init(allocator);
    defer disk.deinit();
    const fs = disk.vfs();
    try fs.writeFile("kupcad.json",
        \\{"name": "bracket", "version": "1.2.0", "dependencies": {"hardware": "github.com/kupcad/hardware", "std": "github.com/kupcad/std#v1"}}
    );
    try fs.writeFile("kupcad.lock",
        \\{"version": "1.0.0", "packages": {"github.com-kupcad-std": {"resolved": "0123456789abcdef0123456789abcdef01234567", "ref": "v1", "integrity": "sha256-AAAA", "dependencies": {"geom": "github.com/kupcad/geom"}}, "github.com-kupcad-geom": {"resolved": "", "ref": "main", "integrity": ""}}}
    );
    var manifest = try Manifest.load(allocator, fs);
    defer manifest.deinit();
    var lockfile = try Lockfile.load(allocator, fs);
    defer lockfile.deinit();
    try lockfile.save(fs);
    const saved = try fs.readFile(allocator, "kupcad.lock");
    defer allocator.free(saved);
    return std.fmt.allocPrint(allocator, "{s} {s}, {d} dependencies\n{s}", .{ manifest.name, manifest.version, manifest.dependencies.count(), saved });
}

test "allocation failures: the package manager's manifest and lockfile" {
    try support.expectAllocationFailuresHandled({}, packageFiles);
}
