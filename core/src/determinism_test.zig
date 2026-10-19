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

const Case = struct { source: []const u8, format: api.ExportFormat };

test "determinism: a build gives the same bytes every time, on one thread or many" {
    var cases: std.ArrayList(Case) = .empty;
    defer cases.deinit(testing.allocator);
    try cases.append(testing.allocator, .{ .source = HEAVY_MODEL, .format = .glb });
    inline for (examples.names) |name| {
        const source = @embedFile("example/" ++ name);
        // An exact model exports STEP, as `kupcad build` would; the rest glb.
        const format: api.ExportFormat = if (std.mem.find(u8, source, "engine: :brep") != null) .step else .glb;
        try cases.append(testing.allocator, .{ .source = source, .format = format });
    }

    for (cases.items) |case| {
        errdefer std.debug.print("format {s}, script:\n{s}\n", .{ @tagName(case.format), case.source });
        const first = try build(case);
        defer testing.allocator.free(first);
        const second = try build(case);
        defer testing.allocator.free(second);
        try testing.expectEqualSlices(u8, first, second);

        manifold.setMaxThreads(1);
        defer manifold.setMaxThreads(null);
        const serial = try build(case);
        defer testing.allocator.free(serial);
        try testing.expectEqualSlices(u8, first, serial);
    }
}

/// Runs the script on a VM whose output is dropped (the examples print, and the test
/// runner's stdout is its protocol) and exports its model as `kupcad build` would.
fn build(case: Case) ![]const u8 {
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try support.runOn(&vm, case.source));
    return api.exportModelFromVm(testing.allocator, &vm, case.format, false);
}
