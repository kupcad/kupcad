//! Every allocation of a build, a format, a check, a run under GC stress and a DAG
//! evaluation, failed in turn (test_support.expectAllocationFailuresHandled): each must
//! free what it allocated and either fail or give what an unfailed run gives.

const std = @import("std");
const testing = std.testing;
const api = @import("api.zig");
const support = @import("test_support.zig");
const registry = @import("stdlib/registry.zig");
const VM = @import("vm/vm.zig").VM;

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
    try support.expectAllocationFailuresHandled(@as([]const u8, "def f(a, b)\n  [a,b].map { |x| x*2 }\nend\nr = {k: f(1, 2), \"s\" => 'q'}\n"), format);
}

test "allocation failures: build every format" {
    const parts = "[cube(2).material(color: \"#FF0000\"), sphere(1, segments: 8).translate(x: 4), (cube(2) - cylinder(r: 0.5, h: 5)).translate(y: 4)]";
    // STEP is exact geometry, which the B-Rep engine builds: a hull of flat solids.
    const exact_part = "CAD.config(engine: :brep)\nbatch_hull([cube(6, 6, 1, center: true), cube(2, 2, 4, center: true)])";
    for ([_]BuildCase{
        .{ .source = parts, .format = .glb },
        .{ .source = parts, .format = .gltf, .draco = true },
        .{ .source = exact_part, .format = .step },
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
    // Unused variables (with fixes), an unknown keyword, a negative size and dead code.
    const source =
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
