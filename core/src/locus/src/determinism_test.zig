//! Determinism (docs/architecture.md §6, §12): the same inputs give the same bytes, built
//! twice, and with a `Parallel` that runs every range backwards as with the serial one,
//! since parallel work is merged in index order. The body JSON is the canonical form
//! compared; its hash is what KupCAD's caches key on.

const std = @import("std");
const testing = std.testing;
const mat = @import("math/mat.zig");
const vec = @import("math/vec.zig");
const Parallel = @import("parallel.zig").Parallel;
const Diagnostics = @import("diagnostics.zig").Diagnostics;
const Body = @import("topology/body.zig").Body;
const body_json = @import("io/body_json.zig");
const step_write = @import("io/step_write.zig");
const transform = @import("construct/transform.zig");
const fixtures = @import("io/fixtures_test.zig");

/// A `Parallel` that runs a range from its end: any implementation may, and the result
/// must not care.
const Backwards = struct {
    fn forRange(_: ?*anyopaque, start: usize, end: usize, body_context: *anyopaque, body: Parallel.Body) void {
        var i = end;
        while (i > start) {
            i -= 1;
            body(i, body_context);
        }
    }
    fn threads(_: ?*anyopaque) usize {
        return 2;
    }
    const vtable: Parallel.VTable = .{ .forRange = forRange, .threads = threads };
    const parallel: Parallel = .{ .context = null, .vtable = &vtable };
};

const NAMES = [_][]const u8{ "box", "cylinder", "square", "circle", "polygon", "even_odd", "polyhedron" };

test "determinism: every fixture built twice gives the same bytes and hash" {
    for (NAMES) |name| {
        var a = try fixtures.build(testing.allocator, name);
        defer a.deinit();
        var b = try fixtures.build(testing.allocator, name);
        defer b.deinit();
        const ta = try body_json.dump(testing.allocator, &a);
        defer testing.allocator.free(ta);
        const tb = try body_json.dump(testing.allocator, &b);
        defer testing.allocator.free(tb);
        try testing.expectEqualStrings(ta, tb);
        try testing.expectEqual(try body_json.hash(testing.allocator, &a), try body_json.hash(testing.allocator, &b));
    }
}

test "determinism: a transform under the serial and a backwards Parallel gives the same bytes, and the same STEP" {
    const affine = mat.Affine.translate(.{ 1, 2, 3 }).compose(&mat.Affine.rotate(vec.normalized(.{ 1, 2, 3 }).?, 0.7));
    for (NAMES) |name| {
        var body = try fixtures.build(testing.allocator, name);
        defer body.deinit();
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        var serial = try transform.transform(testing.allocator, &body, &affine, .{ .parallel = Parallel.serial }, &diag);
        defer serial.deinit();
        var backwards = try transform.transform(testing.allocator, &body, &affine, .{ .parallel = Backwards.parallel }, &diag);
        defer backwards.deinit();
        const ts = try body_json.dump(testing.allocator, &serial);
        defer testing.allocator.free(ts);
        const tb = try body_json.dump(testing.allocator, &backwards);
        defer testing.allocator.free(tb);
        try testing.expectEqualStrings(ts, tb);
        if (body.kind == .solid) {
            const sa = try step_write.write(testing.allocator, &.{&serial});
            defer testing.allocator.free(sa);
            const sb = try step_write.write(testing.allocator, &.{&backwards});
            defer testing.allocator.free(sb);
            try testing.expectEqualStrings(sa, sb);
        }
    }
}
