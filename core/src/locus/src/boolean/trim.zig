//! A solid cut by a plane (KupCAD's `trim_by_plane` and `split_by_plane`, the mesh engine's
//! `TrimByPlane` and `SplitByPlane`): the part on the side the normal points to is the
//! solid's intersection with the half-space there, as the mesh engine takes it, the
//! half-space a box from the plane past the solid's box on every side (§7.4's boolean, so
//! planar solids only until M5). A split is the two trims, the second by the plane turned
//! round.

const std = @import("std");
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const geometry = @import("../geometry/types.zig");
const diagnostics = @import("../diagnostics.zig");
const body_mod = @import("../topology/body.zig");
const bbox = @import("../measure/bbox.zig");
const primitives = @import("../construct/primitives.zig");
const transform = @import("../construct/transform.zig");
const pipeline = @import("pipeline.zig");
const Body = body_mod.Body;
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// The part of `body` (a solid) on the side of the plane `n·p = offset` that `normal`
/// points to (`normal` of any length; `offset` along its unit), a new solid; the empty
/// solid when nothing of it is there.
pub fn trimByPlane(allocator: std.mem.Allocator, body: *const Body, normal: Vec3, offset: f64, options: pipeline.Options, diag: *Diagnostics, report: ?*pipeline.Report) Error!Body {
    for (normal) |c| try diagnostics.input.finite(diag, "the plane's normal", c);
    try diagnostics.input.finite(diag, "the plane's offset", offset);
    const n = vec.normalized(normal) orelse return diag.fail(error.InvalidInput, .{ .code = .not_positive, .entity = .{ .kind = .argument }, .label = "the plane's normal" });
    if (body.kind != .solid) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .label = "the body: a solid" });
    const tol = options.common.tolerance orelse body.tol;
    const box = bbox.bodyBounds(body) catch return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
    if (body.isEmpty() or box.isEmpty()) return emptySolid(allocator, tol);
    // The plane's frame, its origin the plane's point nearest the origin
    const frame = geometry.Frame.fromAxis(vec.scale(n, offset), n);
    var lo: Vec3 = .{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var hi: Vec3 = .{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for ([_]f64{ box.min[0], box.max[0] }) |x| for ([_]f64{ box.min[1], box.max[1] }) |y| for ([_]f64{ box.min[2], box.max[2] }) |z| {
        const l = frame.toLocal(.{ x, y, z });
        lo = vec.min(lo, l);
        hi = vec.max(hi, l);
    };
    // Nothing of the solid beyond the plane: nothing kept
    if (hi[2] <= tol.zone) return emptySolid(allocator, tol);
    // Past the solid's box by its own size on every side but the plane
    const margin = box.extent() + 1;
    var half = try primitives.box(allocator, tol, hi[0] - lo[0] + 2 * margin, hi[1] - lo[1] + 2 * margin, hi[2] + margin, false, diag);
    defer half.deinit();
    const corner = frame.toWorld(.{ lo[0] - margin, lo[1] - margin, 0 });
    const place = mat.Affine.fromColumns(.{ frame.x[0], frame.x[1], frame.x[2], frame.y[0], frame.y[1], frame.y[2], frame.z[0], frame.z[1], frame.z[2], corner[0], corner[1], corner[2] });
    var space = try transform.transform(allocator, &half, &place, options.common, diag);
    defer space.deinit();
    return pipeline.boolean(allocator, body, &space, .intersection, options, diag, report);
}

/// `body` cut in two by the plane `n·p = offset`: the part the normal points to, then the
/// other.
pub fn splitByPlane(allocator: std.mem.Allocator, body: *const Body, normal: Vec3, offset: f64, options: pipeline.Options, diag: *Diagnostics) Error![2]Body {
    var front = try trimByPlane(allocator, body, normal, offset, options, diag, null);
    errdefer front.deinit();
    const back = try trimByPlane(allocator, body, vec.neg(normal), -offset, options, diag, null);
    return .{ front, back };
}

fn emptySolid(allocator: std.mem.Allocator, tol: @import("../tolerance.zig").Tolerance) Body {
    var empty = Body.empty(allocator, tol);
    empty.kind = .solid;
    return empty;
}
