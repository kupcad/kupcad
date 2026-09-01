const std = @import("std");
const topo = @import("../topology.zig");
const geom = @import("../geometry.zig");
const math = @import("../math.zig");
const classify = @import("classify.zig");
const types = @import("types.zig");

const BooleanError = types.BooleanError;
const IntersectionResult = types.IntersectionResult;

/// Calculate chordal sag samples for a cylinder of radius r
fn ellipseSamples(r: f64) usize {
    const sag = 1e-3;
    if (r > sag) {
        const arg = std.math.clamp(1.0 - sag / r, -1.0, 1.0);
        const n = @ceil(std.math.pi / std.math.acos(arg));
        return @intFromFloat(std.math.clamp(n, 64.0, 512.0));
    }
    return 64;
}

fn marchingSsiConePlane(
    allocator: std.mem.Allocator,
    plane: geom.Plane,
    cone: geom.Cone,
    n_samples: usize,
    tol: math.Tolerance,
) !IntersectionResult {
    var points: std.ArrayListUnmanaged(math.Vec3) = .empty;
    errdefer points.deinit(allocator);

    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));
    const axis = math.normalize(cone.axis);
    const ca = @cos(cone.half_angle);
    const sa = @sin(cone.half_angle);

    for (0..n_samples) |i| {
        const u = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_samples));
        const dir_u = math.add(math.scale(axis, ca), math.scale(math.add(math.scale(cone.x_axis, @cos(u)), math.scale(cone.y_axis, @sin(u))), sa));
        const denom = math.dot(n, dir_u);
        if (@abs(denom) < math.MATH_EPSILON) continue;

        const numer = math.dot(n, math.sub(plane.origin, cone.origin));
        const v = numer / denom;
        if (v > tol.absolute) {
            try points.append(allocator, math.add(cone.origin, math.scale(dir_u, v)));
        }
    }

    if (points.items.len == 0) {
        points.deinit(allocator);
        return .empty;
    }
    return .{ .sampled = try points.toOwnedSlice(allocator) };
}

/// 3D Predictor-Corrector Surface-Surface Marching Solver
pub fn marchIntersection(
    allocator: std.mem.Allocator,
    g_arena: *geom.GeometryArena,
    surf_a_id: geom.SurfaceId,
    surf_b_id: geom.SurfaceId,
    start_pt: math.Vec3,
    step_size: f64,
    max_steps: u32,
    tol: math.Tolerance,
) BooleanError!geom.CurveId {
    var points: std.ArrayListUnmanaged(math.Vec3) = .empty;
    defer points.deinit(allocator);

    var curr_pt = start_pt;
    try points.append(allocator, curr_pt);

    var prev_dir: ?math.Vec3 = null;

    for (0..max_steps) |_| {
        // Corrector on start point
        const p_a = classify.projectPointToSurface(g_arena, surf_a_id, curr_pt);
        const p_b = classify.projectPointToSurface(g_arena, surf_b_id, curr_pt);
        curr_pt = math.scale(math.add(p_a, p_b), 0.5);

        const uv_a = g_arena.surfaceProject(surf_a_id, curr_pt);
        const uv_b = g_arena.surfaceProject(surf_b_id, curr_pt);

        const n_a = g_arena.surfaceNormal(surf_a_id, uv_a[0], uv_a[1]);
        const n_b = g_arena.surfaceNormal(surf_b_id, uv_b[0], uv_b[1]);

        var tangent = math.cross(n_a, n_b);
        const tan_len = math.mag(tangent);

        if (tan_len < tol.absolute) {
            if (prev_dir) |pd| {
                tangent = pd;
            } else {
                // At a saddle/crossing point (normals parallel), pick orthogonal tangent
                var arb = math.Vec3{ 0, 1, 1 };
                if (@abs(math.dot(n_a, arb)) > 0.9) arb = .{ 1, 0, 1 };
                tangent = math.normalize(math.cross(n_a, arb));
            }
        } else {
            tangent = math.scale(tangent, 1.0 / tan_len);
            if (prev_dir) |pd| {
                if (math.dot(tangent, pd) < 0.0) {
                    tangent = math.scale(tangent, -1.0);
                }
            }
        }
        prev_dir = tangent;

        // Predictor step along the tangent
        const pred_pt = math.add(curr_pt, math.scale(tangent, step_size));

        // Corrector step: project onto both surfaces and average
        var corr_pt = pred_pt;
        for (0..3) |_| {
            const corr_a = classify.projectPointToSurface(g_arena, surf_a_id, corr_pt);
            const corr_b = classify.projectPointToSurface(g_arena, surf_b_id, corr_pt);
            corr_pt = math.scale(math.add(corr_a, corr_b), 0.5);
        }

        curr_pt = corr_pt;
        try points.append(allocator, curr_pt);

        if (math.distSq(curr_pt, start_pt) < step_size * step_size and points.items.len > 3) {
            break;
        }
    }

    if (points.items.len < 2) return error.DidNotConverge;

    const nurbs_idx: u24 = @intCast(g_arena.nurbs_curves.items.len);
    var control_pts = try allocator.alloc(math.Vec4, points.items.len);
    defer allocator.free(control_pts);

    for (points.items, 0..) |p, i| {
        control_pts[i] = .{ p[0], p[1], p[2], 1.0 };
    }

    const n = points.items.len;
    var knots = try allocator.alloc(f64, n + 3);
    defer allocator.free(knots);

    @memset(knots[0..3], 0.0);
    @memset(knots[n .. n + 3], 1.0);
    for (3..n) |i| {
        knots[i] = @as(f64, @floatFromInt(i - 2)) / @as(f64, @floatFromInt(n - 2));
    }

    try g_arena.nurbs_curves.append(allocator, .{
        .degree = 2,
        .knots = try allocator.dupe(f64, knots),
        .control_points = try allocator.dupe(math.Vec4, control_pts),
    });

    return geom.CurveId{ .index = nurbs_idx, .curve_type = .nurbs };
}

/// Numerical root-refinement solver to intersect an edge segment with quadric surfaces (.cylinder, .cone, .sphere, .torus)
pub fn intersectSegmentSurface(
    allocator: std.mem.Allocator,
    g_arena: *const geom.GeometryArena,
    surface_id: geom.SurfaceId,
    v_start: math.Vec3,
    v_end: math.Vec3,
    tol: math.Tolerance,
) ![]math.Vec3 {
    var hits: std.ArrayListUnmanaged(math.Vec3) = .empty;
    const steps: usize = 32;
    var prev_pt = v_start;
    var prev_proj = classify.projectPointToSurface(g_arena, surface_id, prev_pt);

    for (1..steps + 1) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const curr_pt = math.add(v_start, math.scale(math.sub(v_end, v_start), t));
        const curr_proj = classify.projectPointToSurface(g_arena, surface_id, curr_pt);

        const uv_p = g_arena.surfaceProject(surface_id, prev_pt);
        const uv_c = g_arena.surfaceProject(surface_id, curr_pt);
        const norm_p = g_arena.surfaceNormal(surface_id, uv_p[0], uv_p[1]);
        const norm_c = g_arena.surfaceNormal(surface_id, uv_c[0], uv_c[1]);

        const side_prev = math.dot(math.sub(prev_pt, prev_proj), norm_p);
        const side_curr = math.dot(math.sub(curr_pt, curr_proj), norm_c);

        if (side_prev * side_curr < 0.0) {
            var t_lo = @as(f64, @floatFromInt(i - 1)) / @as(f64, @floatFromInt(steps));
            var t_hi = t;

            for (0..15) |_| {
                const t_mid = 0.5 * (t_lo + t_hi);
                const mid_pt = math.add(v_start, math.scale(math.sub(v_end, v_start), t_mid));
                const mid_proj = classify.projectPointToSurface(g_arena, surface_id, mid_pt);
                const uv_m = g_arena.surfaceProject(surface_id, mid_pt);
                const norm_m = g_arena.surfaceNormal(surface_id, uv_m[0], uv_m[1]);
                const side_m = math.dot(math.sub(mid_pt, mid_proj), norm_m);

                if (side_m * side_prev > 0.0) {
                    t_lo = t_mid;
                } else {
                    t_hi = t_mid;
                }
            }

            const hit_t = 0.5 * (t_lo + t_hi);
            if (hit_t > tol.parametric and hit_t < 1.0 - tol.parametric) {
                const hit_pt = math.add(v_start, math.scale(math.sub(v_end, v_start), hit_t));
                try hits.append(allocator, hit_pt);
            }
        }
        prev_pt = curr_pt;
        prev_proj = curr_proj;
    }
    return hits.toOwnedSlice(allocator);
}

/// Analytical intersection between a 3D ray (pt + t * ray_dir) and a Cylinder surface.
pub fn intersectRayCylinder(pt: math.Vec3, ray_dir: math.Vec3, cyl: geom.Cylinder) [2]?f64 {
    var hits = [2]?f64{ null, null };
    const axis = math.normalize(cyl.axis);

    const v = math.sub(pt, cyl.origin);
    const v_proj = math.sub(v, math.scale(axis, math.dot(v, axis)));
    const d_proj = math.sub(ray_dir, math.scale(axis, math.dot(ray_dir, axis)));

    const a = math.magSq(d_proj);
    if (a < math.MATH_EPSILON) return hits;

    const b = 2.0 * math.dot(v_proj, d_proj);
    const c = math.magSq(v_proj) - (cyl.radius * cyl.radius);
    const disc = b * b - 4.0 * a * c;

    if (disc < 0.0) return hits;

    const sqrt_disc = @sqrt(disc);
    const t1 = (-b - sqrt_disc) / (2.0 * a);
    const t2 = (-b + sqrt_disc) / (2.0 * a);

    var count: usize = 0;
    if (t1 > math.MATH_EPSILON) {
        hits[count] = t1;
        count += 1;
    }
    if (t2 > math.MATH_EPSILON) {
        hits[count] = t2;
    }
    return hits;
}

pub fn intersectLinePlane(line_start: math.Vec3, line_end: math.Vec3, plane_origin: math.Vec3, plane_normal: math.Vec3, tol: math.Tolerance) ?math.Vec3 {
    const dir = math.sub(line_end, line_start);
    const denom = math.dot(dir, plane_normal);
    if (@abs(denom) < math.MATH_EPSILON) return null;

    const t = math.dot(math.sub(plane_origin, line_start), plane_normal) / denom;
    if (t > tol.parametric and t < (1.0 - tol.parametric)) {
        return math.add(line_start, math.scale(dir, t));
    }
    return null;
}

pub fn intersectArcPlane(arc: geom.CircleArc, v_start: math.Vec3, v_end: math.Vec3, plane_origin: math.Vec3, plane_normal: math.Vec3, forward: bool, tol: math.Tolerance) ?math.Vec3 {
    const A = arc.radius * math.dot(plane_normal, arc.x_axis);
    const B = arc.radius * math.dot(plane_normal, arc.y_axis);
    const D = math.dot(plane_normal, math.sub(plane_origin, arc.center));
    const Rab_sq = A * A + B * B;
    if (Rab_sq < math.MATH_EPSILON) return null;
    const Rab = @sqrt(Rab_sq);
    if (@abs(D) > Rab + tol.absolute) return null;

    const D_clamped = std.math.clamp(D / Rab, -1.0, 1.0);
    const phi = std.math.atan2(A, B);
    var t1 = std.math.asin(D_clamped) - phi;
    var t2 = std.math.pi - std.math.asin(D_clamped) - phi;
    t1 = @mod(t1, 2.0 * std.math.pi);
    if (t1 < 0) t1 += 2.0 * std.math.pi;
    t2 = @mod(t2, 2.0 * std.math.pi);
    if (t2 < 0) t2 += 2.0 * std.math.pi;

    const u_start = math.normalize(math.sub(v_start, arc.center));
    const u_end = math.normalize(math.sub(v_end, arc.center));
    var ang_start = std.math.atan2(math.dot(u_start, arc.y_axis), math.dot(u_start, arc.x_axis));
    var ang_end = std.math.atan2(math.dot(u_end, arc.y_axis), math.dot(u_end, arc.x_axis));
    if (ang_start < 0) ang_start += 2.0 * std.math.pi;
    if (ang_end < 0) ang_end += 2.0 * std.math.pi;
    if (!forward) std.mem.swap(f64, &ang_start, &ang_end);

    const is_full = math.distSq(v_start, v_end) < tol.squared;
    const eps = tol.parametric;
    const in1 = is_full or (if (ang_start < ang_end) (t1 > ang_start + eps and t1 < ang_end - eps) else (t1 > ang_start + eps or t1 < ang_end - eps));
    const in2 = is_full or (if (ang_start < ang_end) (t2 > ang_start + eps and t2 < ang_end - eps) else (t2 > ang_start + eps or t2 < ang_end - eps));

    const p1 = math.add(arc.center, math.add(math.scale(arc.x_axis, arc.radius * @cos(t1)), math.scale(arc.y_axis, arc.radius * @sin(t1))));
    const p2 = math.add(arc.center, math.add(math.scale(arc.x_axis, arc.radius * @cos(t2)), math.scale(arc.y_axis, arc.radius * @sin(t2))));

    if (in1 and !in2) return p1;
    if (in2 and !in1) return p2;
    if (in1 and in2) return p1;
    return null;
}

pub fn intersectNurbsPlane(curve: geom.NurbsCurve, plane_origin: math.Vec3, plane_normal: math.Vec3, tol: math.Tolerance) ?math.Vec3 {
    const segments = 20;
    var prev_pt = geom.evaluateNurbsCurve(curve, 0.0);
    var prev_dist = math.dot(plane_normal, math.sub(prev_pt, plane_origin));
    for (1..segments + 1) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(segments));
        const curr_pt = geom.evaluateNurbsCurve(curve, t);
        const curr_dist = math.dot(plane_normal, math.sub(curr_pt, plane_origin));
        if (prev_dist * curr_dist < 0.0) {
            var t_low = t - (1.0 / @as(f64, @floatFromInt(segments)));
            var t_high = t;
            for (0..15) |_| {
                const t_mid = (t_low + t_high) / 2.0;
                const mid_pt = geom.evaluateNurbsCurve(curve, t_mid);
                const mid_dist = math.dot(plane_normal, math.sub(mid_pt, plane_origin));
                if (mid_dist * prev_dist > 0.0) t_low = t_mid else t_high = t_mid;
            }
            const hit_t = (t_low + t_high) / 2.0;
            if (hit_t > tol.parametric and hit_t < (1.0 - tol.parametric)) return geom.evaluateNurbsCurve(curve, hit_t);
        }
        prev_pt = curr_pt;
        prev_dist = curr_dist;
    }
    return null;
}

/// Intersection of two planes.
/// Returns an exact line, or empty if parallel/coincident.
pub fn intersectPlanePlane(a: geom.Plane, b: geom.Plane, tol: math.Tolerance) IntersectionResult {
    const n1 = math.normalize(math.cross(a.u_axis, a.v_axis));
    const n2 = math.normalize(math.cross(b.u_axis, b.v_axis));

    const dir = math.cross(n1, n2);
    const dir_len = math.mag(dir);

    if (dir_len < tol.absolute) {
        // Parallel or coincident. For boolean boundaries, coincident faces
        // are resolved via face classification, so we return empty.
        return .empty;
    }

    const d1 = math.dot(n1, a.origin);
    const d2 = math.dot(n2, b.origin);

    const n1n1 = math.dot(n1, n1);
    const n1n2 = math.dot(n1, n2);
    const n2n2 = math.dot(n2, n2);

    const det = n1n1 * n2n2 - n1n2 * n1n2;
    if (@abs(det) < math.MATH_EPSILON) {
        return .empty;
    }

    const c1 = (d1 * n2n2 - d2 * n1n2) / det;
    const c2 = (d2 * n1n1 - d1 * n1n2) / det;

    const origin = math.add(math.scale(n1, c1), math.scale(n2, c2));

    return .{ .line = .{ .origin = origin, .direction = math.normalize(dir) } };
}

/// Intersection of a plane and a sphere.
/// Returns a circle, a tangent point, or empty.
pub fn intersectPlaneSphere(plane: geom.Plane, sphere: geom.Sphere, tol: math.Tolerance) IntersectionResult {
    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));

    // Signed distance from sphere center to plane
    const dist = math.dot(n, math.sub(sphere.center, plane.origin));
    const abs_dist = @abs(dist);

    if (abs_dist > sphere.radius + tol.absolute) {
        return .empty;
    }

    if (@abs(abs_dist - sphere.radius) < tol.absolute) {
        // Tangent - single point
        const pt = math.sub(sphere.center, math.scale(n, dist));
        return .{ .point = pt };
    }

    // Circle
    const circle_radius = @sqrt(sphere.radius * sphere.radius - dist * dist);
    const circle_center = math.sub(sphere.center, math.scale(n, dist));

    // Construct an arbitrary orthonormal basis for the circle on the plane
    var x_axis = math.Vec3{ 1, 0, 0 };
    if (@abs(n[0]) > 0.99) {
        x_axis = math.normalize(math.cross(n, .{ 0, 1, 0 }));
    } else {
        x_axis = math.normalize(math.cross(n, .{ 1, 0, 0 }));
    }
    const y_axis = math.normalize(math.cross(n, x_axis));

    return .{ .circle = .{
        .center = circle_center,
        .radius = circle_radius,
        .normal = n,
        .x_axis = x_axis,
        .y_axis = y_axis,
    } };
}

/// Finds where an infinite 2D line crosses a finite 2D line segment.
/// Returns the `t` parameter along the INFINITE line, or null if it misses.
pub fn intersectInfiniteLineSegment2D(line_o: [2]f64, line_d: [2]f64, p1: [2]f64, p2: [2]f64, tol: math.Tolerance) ?f64 {
    const seg_d = [2]f64{ p2[0] - p1[0], p2[1] - p1[1] };
    const denom = line_d[0] * seg_d[1] - line_d[1] * seg_d[0];

    if (@abs(denom) < math.MATH_EPSILON) return null; // Parallel

    const diff = [2]f64{ p1[0] - line_o[0], p1[1] - line_o[1] };
    const u = (diff[0] * line_d[1] - diff[1] * line_d[0]) / denom;
    const t = (diff[0] * seg_d[1] - diff[1] * seg_d[0]) / denom;

    // If the intersection lies within the bounds of the finite segment
    if (u >= -tol.parametric and u <= 1.0 + tol.parametric) {
        return t;
    }
    return null;
}

/// Intersection of two spheres.
/// Returns a circle, a tangent point, or empty.
pub fn intersectSphereSphere(a: geom.Sphere, b: geom.Sphere, tol: math.Tolerance) IntersectionResult {
    const ab = math.sub(b.center, a.center);
    const d = math.mag(ab);

    if (d < tol.absolute) {
        // Concentric spheres (or identical)
        return .empty;
    }

    if (d > a.radius + b.radius + tol.absolute) {
        return .empty; // Too far apart
    }

    if (d < @abs(a.radius - b.radius) - tol.absolute) {
        return .empty; // One completely inside the other
    }

    // Check tangent cases
    if (@abs(d - a.radius - b.radius) < tol.absolute) {
        // External tangent
        const pt = math.add(a.center, math.scale(ab, a.radius / d));
        return .{ .point = pt };
    }

    if (@abs(d - @abs(a.radius - b.radius)) < tol.absolute) {
        // Internal tangent
        const sign: f64 = if (a.radius > b.radius) 1.0 else -1.0;
        const pt = math.add(a.center, math.scale(ab, sign * (a.radius / d)));
        return .{ .point = pt };
    }

    // General case - Circle
    // Distance from center A to the plane containing the intersection circle
    const h = (d * d + a.radius * a.radius - b.radius * b.radius) / (2.0 * d);
    const circle_center = math.add(a.center, math.scale(ab, h / d));

    // Clamp to 0 to prevent NaN from tiny floating point inaccuracies
    const radius_sq = @max(0.0, a.radius * a.radius - h * h);
    const circle_radius = @sqrt(radius_sq);
    const normal = math.normalize(ab);

    var x_axis = math.Vec3{ 1, 0, 0 };
    if (@abs(normal[0]) > 0.99) {
        x_axis = math.normalize(math.cross(normal, .{ 0, 1, 0 }));
    } else {
        x_axis = math.normalize(math.cross(normal, .{ 1, 0, 0 }));
    }
    const y_axis = math.normalize(math.cross(normal, x_axis));

    return .{ .circle = .{
        .center = circle_center,
        .radius = circle_radius,
        .normal = normal,
        .x_axis = x_axis,
        .y_axis = y_axis,
    } };
}

// Handles Cylinder x Cylinder (Steinmetz curves & fallback)
pub fn intersectCylinderCylinder(
    allocator: std.mem.Allocator,
    a: geom.Cylinder,
    b: geom.Cylinder,
    tol: math.Tolerance,
) !IntersectionResult {
    const axis_a = math.normalize(a.axis);
    const axis_b = math.normalize(b.axis);
    const dot_ab = math.dot(axis_a, axis_b);

    if (@abs(@abs(dot_ab) - 1.0) < tol.absolute) return .empty;

    // Check for perpendicular equal-radii cylinders (Steinmetz curves)
    if (@abs(dot_ab) < tol.absolute and @abs(a.radius - b.radius) < tol.absolute) {
        const cb_minus_ca = math.sub(b.origin, a.origin);
        const t = math.dot(cb_minus_ca, axis_a);
        const s = -math.dot(cb_minus_ca, axis_b);
        const p_a = math.add(a.origin, math.scale(axis_a, t));
        const p_b = math.add(b.origin, math.scale(axis_b, s));

        if (math.mag(math.sub(p_a, p_b)) < tol.absolute) {
            const n_samples: usize = 64;
            var curve_plus = try allocator.alloc(math.Vec3, n_samples + 1);
            errdefer allocator.free(curve_plus);
            var curve_minus = try allocator.alloc(math.Vec3, n_samples + 1);
            errdefer allocator.free(curve_minus);

            const ref_a = axis_b;
            const y_a = math.cross(axis_a, ref_a);
            const r = a.radius;

            for (0..n_samples + 1) |i| {
                const theta = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_samples));
                const cos_t = @cos(theta);
                const sin_t = @sin(theta);
                const lateral = math.add(math.scale(ref_a, r * cos_t), math.scale(y_a, r * sin_t));
                const axial = math.scale(axis_a, r * cos_t);

                curve_plus[i] = math.add(p_a, math.add(lateral, axial));
                curve_minus[i] = math.add(p_a, math.sub(lateral, axial));
            }

            return .{ .two_sampled = .{ curve_plus, curve_minus } };
        }
    }

    // General fallback to Marching SSI
    const surf_a_id = geom.SurfaceId{ .index = 0, .surface_type = .cylinder };
    const surf_b_id = geom.SurfaceId{ .index = 1, .surface_type = .cylinder };
    var arena = geom.GeometryArena.init(allocator);
    defer arena.deinit(allocator);
    try arena.cylinders.append(allocator, a);
    try arena.cylinders.append(allocator, b);

    const start_pt = math.add(a.origin, math.scale(a.x_axis, a.radius));
    _ = try marchIntersection(allocator, &arena, surf_a_id, surf_b_id, start_pt, 0.5, 64, tol);

    return .empty;
}

/// Intersection of a plane and a cylinder.
/// Returns exact Circle/Lines for perpendicular/parallel axes, or a sampled polyline for oblique planes.
pub fn intersectPlaneCylinder(
    allocator: std.mem.Allocator,
    plane: geom.Plane,
    cyl: geom.Cylinder,
    tol: math.Tolerance,
) !IntersectionResult {
    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));
    const axis = math.normalize(cyl.axis);

    const cos_angle = @abs(math.dot(n, axis));

    if (cos_angle < tol.absolute) {
        // Plane parallel to cylinder axis
        const axis_pt = cyl.origin;
        const dist = @abs(math.dot(n, math.sub(axis_pt, plane.origin)));

        if (dist > cyl.radius + tol.absolute) {
            return .empty;
        }

        if (@abs(dist - cyl.radius) < tol.absolute) {
            // Tangent line
            const signed_dist = math.dot(n, math.sub(axis_pt, plane.origin));
            const closest = math.sub(axis_pt, math.scale(n, signed_dist));
            return .{ .line = .{ .origin = closest, .direction = axis } };
        }

        // Two parallel lines
        const signed_dist = math.dot(n, math.sub(axis_pt, plane.origin));
        const axis_on_plane = math.sub(axis_pt, math.scale(n, signed_dist));

        var perp = math.cross(axis, n);
        if (math.magSq(perp) < tol.absolute) {
            return .empty;
        }
        perp = math.normalize(perp);

        const lateral = @sqrt(cyl.radius * cyl.radius - dist * dist);
        const p1 = math.add(axis_on_plane, math.scale(perp, lateral));
        const p2 = math.sub(axis_on_plane, math.scale(perp, lateral));

        return .{ .two_lines = .{
            .{ .origin = p1, .direction = axis },
            .{ .origin = p2, .direction = axis },
        } };
    } else if (@abs(cos_angle - 1.0) < tol.absolute) {
        // Plane perpendicular to cylinder axis -> Exact Circle
        const dist_along_axis = math.dot(math.sub(plane.origin, cyl.origin), axis);
        const circle_center = math.add(cyl.origin, math.scale(axis, dist_along_axis));

        return .{ .circle = .{
            .center = circle_center,
            .radius = cyl.radius,
            .normal = n,
            .x_axis = cyl.x_axis,
            .y_axis = cyl.y_axis,
        } };
    } else {
        // General oblique case -> Ellipse sampled as a polyline
        const n_samples = ellipseSamples(cyl.radius);
        var points: std.ArrayListUnmanaged(math.Vec3) = .empty;
        errdefer points.deinit(allocator);

        const tau = 2.0 * std.math.pi;
        for (0..n_samples) |i| {
            const angle = tau * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_samples));
            const cos_a = @cos(angle);
            const sin_a = @sin(angle);

            const radial = math.add(
                math.scale(cyl.x_axis, cyl.radius * cos_a),
                math.scale(cyl.y_axis, cyl.radius * sin_a),
            );
            const p_on_cyl_base = math.add(cyl.origin, radial);

            const denom = math.dot(n, axis);
            if (@abs(denom) < math.MATH_EPSILON) continue;

            const t = math.dot(n, math.sub(plane.origin, p_on_cyl_base)) / denom;
            const pt = math.add(p_on_cyl_base, math.scale(axis, t));
            try points.append(allocator, pt);
        }

        if (points.items.len == 0) {
            points.deinit(allocator);
            return .empty;
        }

        // Close the sampled loop
        try points.append(allocator, points.items[0]);
        return .{ .sampled = try points.toOwnedSlice(allocator) };
    }
}

/// Routes two Surface IDs to their corresponding exact algebraic solver.
pub fn intersectSurfaces(
    allocator: std.mem.Allocator,
    g_arena: *const geom.GeometryArena,
    surf_a: geom.SurfaceId,
    surf_b: geom.SurfaceId,
    tol: math.Tolerance,
) !IntersectionResult {
    switch (surf_a.surface_type) {
        .plane => switch (surf_b.surface_type) {
            .plane => return intersectPlanePlane(g_arena.planes.items[surf_a.index], g_arena.planes.items[surf_b.index], tol),
            .cylinder => return try intersectPlaneCylinder(allocator, g_arena.planes.items[surf_a.index], g_arena.cylinders.items[surf_b.index], tol),
            .sphere => return intersectPlaneSphere(g_arena.planes.items[surf_a.index], g_arena.spheres.items[surf_b.index], tol),
            .cone => return try intersectPlaneCone(allocator, g_arena.planes.items[surf_a.index], g_arena.cones.items[surf_b.index], tol),
            .torus => return try intersectPlaneTorus(allocator, g_arena.planes.items[surf_a.index], g_arena.toruses.items[surf_b.index], tol),
            else => return .empty,
        },
        .cylinder => switch (surf_b.surface_type) {
            .plane => return try intersectPlaneCylinder(allocator, g_arena.planes.items[surf_b.index], g_arena.cylinders.items[surf_a.index], tol),
            .cylinder => return try intersectCylinderCylinder(allocator, g_arena.cylinders.items[surf_a.index], g_arena.cylinders.items[surf_b.index], tol),
            else => return .empty,
        },
        .sphere => switch (surf_b.surface_type) {
            .plane => return intersectPlaneSphere(g_arena.planes.items[surf_b.index], g_arena.spheres.items[surf_a.index], tol),
            .sphere => return intersectSphereSphere(g_arena.spheres.items[surf_a.index], g_arena.spheres.items[surf_b.index], tol),
            else => return .empty,
        },
        .cone => switch (surf_b.surface_type) {
            .plane => return try intersectPlaneCone(allocator, g_arena.planes.items[surf_b.index], g_arena.cones.items[surf_a.index], tol),
            else => return .empty,
        },
        .torus => switch (surf_b.surface_type) {
            .plane => return try intersectPlaneTorus(allocator, g_arena.planes.items[surf_b.index], g_arena.toruses.items[surf_a.index], tol),
            else => return .empty,
        },
        else => return .empty,
    }
}

// Handles Plane x Cone intersection (rulings, circles, oblique cuts)
pub fn intersectPlaneCone(
    allocator: std.mem.Allocator,
    plane: geom.Plane,
    cone: geom.Cone,
    tol: math.Tolerance,
) !IntersectionResult {
    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));
    const axis = math.normalize(cone.axis);
    const cos_angle = @abs(math.dot(n, axis));

    // Check if plane passes directly through cone apex
    const apex_dist = math.dot(n, math.sub(plane.origin, cone.origin));
    const apex_scale = @max(math.mag(cone.origin), @max(math.mag(plane.origin), 1.0));

    if (@abs(apex_dist) < tol.absolute * apex_scale) {
        const ca = @cos(cone.half_angle);
        const sa = @sin(cone.half_angle);
        const a_coef = sa * math.dot(n, cone.x_axis);
        const b_coef = sa * math.dot(n, cone.y_axis);
        const c_coef = ca * math.dot(n, axis);
        const r_coef = @sqrt(a_coef * a_coef + b_coef * b_coef);

        if (r_coef < @abs(c_coef) - tol.absolute) return .{ .point = cone.origin };

        const phi = std.math.atan2(b_coef, a_coef);
        if (r_coef < @abs(c_coef) + tol.absolute) {
            const u = if (c_coef <= 0.0) phi else phi + std.math.pi;
            const dir = math.add(math.scale(axis, ca), math.scale(math.add(math.scale(cone.x_axis, @cos(u)), math.scale(cone.y_axis, @sin(u))), sa));
            return .{ .line = .{ .origin = cone.origin, .direction = math.normalize(dir) } };
        }

        const delta = std.math.acos(std.math.clamp(-c_coef / r_coef, -1.0, 1.0));
        const u_1 = phi + delta;
        const u_2 = phi - delta;
        const dir1 = math.normalize(math.add(math.scale(axis, ca), math.scale(math.add(math.scale(cone.x_axis, @cos(u_1)), math.scale(cone.y_axis, @sin(u_1))), sa)));
        const dir2 = math.normalize(math.add(math.scale(axis, ca), math.scale(math.add(math.scale(cone.x_axis, @cos(u_2)), math.scale(cone.y_axis, @sin(u_2))), sa)));

        return .{ .two_lines = .{
            .{ .origin = cone.origin, .direction = dir1 },
            .{ .origin = cone.origin, .direction = dir2 },
        } };
    }

    if (@abs(cos_angle - 1.0) < tol.absolute) {
        // Plane perpendicular to cone axis -> Circle
        const apex_to_plane = math.dot(axis, math.sub(plane.origin, cone.origin));
        const v_param = apex_to_plane / @cos(cone.half_angle);

        if (@abs(v_param) < tol.absolute) return .{ .point = cone.origin };
        if (v_param < 0.0) return .empty;

        const circle_radius = @abs(apex_to_plane) * @tan(cone.half_angle);
        const circle_center = math.add(cone.origin, math.scale(axis, apex_to_plane));

        return .{ .circle = .{
            .center = circle_center,
            .radius = circle_radius,
            .normal = n,
            .x_axis = cone.x_axis,
            .y_axis = cone.y_axis,
        } };
    }

    // Oblique Conic Section -> Parameter sweep
    return try marchingSsiConePlane(allocator, plane, cone, 64, tol);
}

fn evaluateTorusPoint(torus: geom.Torus, u: f64, v: f64) math.Vec3 {
    const radial = math.add(math.scale(torus.x_axis, @cos(u)), math.scale(torus.y_axis, @sin(u)));
    const tube_center = math.add(torus.center, math.scale(radial, torus.major_radius));
    const tube_offset = math.add(math.scale(radial, torus.minor_radius * @cos(v)), math.scale(torus.axis, torus.minor_radius * @sin(v)));
    return math.add(tube_center, tube_offset);
}

fn refineTorusCrossing(torus: geom.Torus, plane: geom.Plane, u: f64, v_a: f64, v_b: f64, tol: math.Tolerance) f64 {
    _ = tol;
    var lo = v_a;
    var hi = v_b;
    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));

    for (0..20) |_| {
        const mid = 0.5 * (lo + hi);
        const pt = evaluateTorusPoint(torus, u, mid);
        const dist = math.dot(n, math.sub(pt, plane.origin));
        const pt_lo = evaluateTorusPoint(torus, u, lo);
        const dist_lo = math.dot(n, math.sub(pt_lo, plane.origin));

        if (dist_lo * dist < 0.0) {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    return 0.5 * (lo + hi);
}

fn marchingSsiTorusPlane(
    allocator: std.mem.Allocator,
    plane: geom.Plane,
    torus: geom.Torus,
    n_samples: usize,
    tol: math.Tolerance,
) !IntersectionResult {
    var points: std.ArrayListUnmanaged(math.Vec3) = .empty;
    errdefer points.deinit(allocator);

    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));
    const n_v: usize = 32;

    for (0..n_samples) |i| {
        const u = 2.0 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n_samples));
        var prev_dist: ?f64 = null;

        for (0..n_v + 1) |j| {
            const v = 2.0 * std.math.pi * @as(f64, @floatFromInt(j)) / @as(f64, @floatFromInt(n_v));
            const pt = evaluateTorusPoint(torus, u, v);
            const dist = math.dot(n, math.sub(pt, plane.origin));

            if (prev_dist) |pd| {
                if (pd * dist < 0.0) {
                    const v_prev = 2.0 * std.math.pi * @as(f64, @floatFromInt(j - 1)) / @as(f64, @floatFromInt(n_v));
                    const v_ref = refineTorusCrossing(torus, plane, u, v_prev, v, tol);
                    try points.append(allocator, evaluateTorusPoint(torus, u, v_ref));
                }
            }
            prev_dist = dist;
        }
    }

    if (points.items.len == 0) {
        points.deinit(allocator);
        return .empty;
    }
    return .{ .sampled = try points.toOwnedSlice(allocator) };
}

// Handles Plane x Torus intersection
pub fn intersectPlaneTorus(
    allocator: std.mem.Allocator,
    plane: geom.Plane,
    torus: geom.Torus,
    tol: math.Tolerance,
) !IntersectionResult {
    const n = math.normalize(math.cross(plane.u_axis, plane.v_axis));
    const dist = @abs(math.dot(n, math.sub(torus.center, plane.origin)));

    if (dist > torus.major_radius + torus.minor_radius + tol.absolute) return .empty;

    const cos_angle = @abs(math.dot(n, math.normalize(torus.axis)));
    if (@abs(cos_angle - 1.0) < tol.absolute) {
        const z = math.dot(n, math.sub(torus.center, plane.origin));
        const abs_z = @abs(z);
        if (abs_z > torus.minor_radius + tol.absolute) return .empty;

        const r_offset = @sqrt(@max(0.0, torus.minor_radius * torus.minor_radius - z * z));
        const circle_center = math.sub(torus.center, math.scale(n, z));

        return .{ .circle = .{
            .center = circle_center,
            .radius = torus.major_radius + r_offset,
            .normal = n,
            .x_axis = torus.x_axis,
            .y_axis = torus.y_axis,
        } };
    }

    return try marchingSsiTorusPlane(allocator, plane, torus, 64, tol);
}
