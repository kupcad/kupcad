//! Determinism: a model built twice gives the same bytes, and so does a build with the
//! kernel's parallel algorithms held to one thread. A file that changed between runs of the
//! same script (a hash map's order, a parallel reduction's) would break caching, diffs of
//! exported files and the examples' snapshot.

const std = @import("std");
const testing = std.testing;
const api = @import("api.zig");
const manifold = @import("bindings/manifold.zig");
const support = @import("test_support.zig");
const examples = @import("examples");

/// Large enough for Manifold's algorithms to run in parallel: a fine sphere with a ring of
/// holes, unions of many parts, and a part split by materials.
const HEAVY_MODEL =
    \\body = sphere(20, segments: 128) - cylinder(r: 2, h: 60, center: true, segments: 64).translate(x: 12).repeat_polar(12)
    \\ribs = union((0...8).map { |i| cube(40, 1, 2, center: true).rotate(z: i * 22.5) })
    \\[body + ribs.material(color: "#FF0000"), body.translate(x: 50)]
;
/// An exact model, for STEP's writer: the hull of a plate and a column (the B-Rep engine
/// can't combine solids yet).
const EXACT_MODEL =
    \\CAD.config(engine: :brep)
    \\batch_hull([cube(30, 30, 4, center: true), cube(10, 10, 20, center: true)])
;

/// A script and the formats it is exported to, or null for the one its model is written
/// in (test_support.modelFormat): one run, each format written from it (the run is what
/// costs; each format used to run the script again).
const Case = struct { source: []const u8, formats: ?[]const api.ExportFormat = null };
/// A file a build wrote, and its format.
const File = struct { format: api.ExportFormat, bytes: []const u8 };

test "determinism: a build gives the same bytes every time, on one thread or many" {
    // The models are heavy and built thrice: an allocator that checks frees and counts
    // leaks without unwinding the stack each time (the testing allocator's ten seconds)
    var checked: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{ .stack_trace_frames = 0 });
    defer testing.expectEqual(@as(usize, 0), checked.deinit()) catch @panic("the determinism builds leaked");
    const allocator = checked.allocator();
    var cases: std.ArrayList(Case) = .empty;
    defer cases.deinit(testing.allocator);
    try cases.append(testing.allocator, .{ .source = HEAVY_MODEL, .formats = &.{ .glb, .obj, .svg, .dxf } });
    try cases.append(testing.allocator, .{ .source = EXACT_MODEL, .formats = &.{.step} });
    inline for (examples.names) |name| {
        try cases.append(testing.allocator, .{ .source = @embedFile("example/" ++ name) });
    }

    for (cases.items) |case| {
        errdefer std.debug.print("script:\n{s}\n", .{case.source});
        const first = try build(allocator, case);
        defer freeAll(allocator, first);
        const second = try build(allocator, case);
        defer freeAll(allocator, second);
        manifold.setMaxThreads(1);
        defer manifold.setMaxThreads(null);
        const serial = try build(allocator, case);
        defer freeAll(allocator, serial);
        for (first, second, serial) |a, b, c| {
            errdefer std.debug.print("format {s}\n", .{@tagName(a.format)});
            try testing.expectEqualSlices(u8, a.bytes, b.bytes);
            try testing.expectEqualSlices(u8, a.bytes, c.bytes);
        }
    }
}

/// Runs the script on a VM whose output is dropped (the examples print, and the test
/// runner's stdout is its protocol) and exports its model in each of the case's formats, as
/// `kupcad build` would.
fn build(allocator: std.mem.Allocator, case: Case) ![]const File {
    var vm = try support.initVmWith(allocator);
    defer vm.deinit();
    try testing.expectEqual(.ok, try support.runWith(allocator, &vm, case.source));
    var own: [1]api.ExportFormat = undefined;
    const formats = case.formats orelse formats: {
        own[0] = try support.modelFormat(allocator, &vm);
        break :formats &own;
    };
    const files = try allocator.alloc(File, formats.len);
    var written: usize = 0;
    errdefer {
        for (files[0..written]) |file| allocator.free(file.bytes);
        allocator.free(files);
    }
    for (formats, files) |format, *file| {
        file.* = .{ .format = format, .bytes = try api.exportModelFromVm(allocator, &vm, format, .{}) };
        written += 1;
    }
    return files;
}

fn freeAll(allocator: std.mem.Allocator, files: []const File) void {
    for (files) |file| allocator.free(file.bytes);
    allocator.free(files);
}
