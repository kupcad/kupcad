const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const booleans = @import("booleans.zig");
const generators = @import("generators.zig");
const math = @import("math.zig");

const Edge2D = struct {
    start: [2]f64,
    end: [2]f64,
    is_a: bool,
};

fn extractPolygon(allocator: std.mem.Allocator, t_arena: *topo.TopologyArena, solid_id: topo.SolidId) ![]const [2]f64 {
    var pts = std.ArrayListUnmanaged([2]f64).empty;
    const s = t_arena.solids.items[solid_id];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[s.shells_start]];
    const face_id = t_arena.shell_faces.items[shell.faces_start];
    const face = t_arena.faces.items[face_id];
    const loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start]];

    var curr = loop.first_half_edge;
    while (true) {
        const he = t_arena.half_edges.items[curr];
        const pt = t_arena.vertices.items[he.start_vertex].point;
        try pts.append(allocator, .{ pt[0], pt[1] });
        curr = he.next;
        if (curr == loop.first_half_edge) break;
    }
    return pts.toOwnedSlice(allocator);
}

fn extractEdges(allocator: std.mem.Allocator, t_arena: *topo.TopologyArena, solid_id: topo.SolidId, is_a: bool, out_edges: *std.ArrayListUnmanaged(Edge2D)) !void {
    const s = t_arena.solids.items[solid_id];
    const shell = t_arena.shells.items[t_arena.solid_shells.items[s.shells_start]];
    const face_id = t_arena.shell_faces.items[shell.faces_start];
    const face = t_arena.faces.items[face_id];
    const loop = t_arena.loops.items[t_arena.face_loops.items[face.loops_start]];

    var curr = loop.first_half_edge;
    while (true) {
        const he = t_arena.half_edges.items[curr];
        const p1 = t_arena.vertices.items[he.start_vertex].point;
        const p2 = t_arena.vertices.items[t_arena.half_edges.items[he.next].start_vertex].point;
        try out_edges.append(allocator, .{ .start = .{ p1[0], p1[1] }, .end = .{ p2[0], p2[1] }, .is_a = is_a });
        curr = he.next;
        if (curr == loop.first_half_edge) break;
    }
}

// Computes geometric line-line intersection
fn intersect2D(p1: [2]f64, p2: [2]f64, p3: [2]f64, p4: [2]f64, tol: math.Tolerance) ?[2]f64 {
    const denom = (p1[0] - p2[0]) * (p3[1] - p4[1]) - (p1[1] - p2[1]) * (p3[0] - p4[0]);
    if (@abs(denom) < math.MATH_EPSILON) return null; // Keep MATH_EPSILON for strictly mathematical division-by-zero protection

    const t = ((p1[0] - p3[0]) * (p3[1] - p4[1]) - (p1[1] - p3[1]) * (p3[0] - p4[0])) / denom;
    const u = ((p1[0] - p3[0]) * (p1[1] - p2[1]) - (p1[1] - p3[1]) * (p1[0] - p2[0])) / denom;

    // Split only if intersection happens deep within the line segment bounds
    if (t > tol.parametric and t < 1.0 - tol.parametric and u > tol.parametric and u < 1.0 - tol.parametric) {
        return [2]f64{ p1[0] + t * (p2[0] - p1[0]), p1[1] + t * (p2[1] - p1[1]) };
    }
    return null;
}

pub fn crossSectionBoolean(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_a: topo.SolidId,
    solid_b: topo.SolidId,
    op: booleans.BooleanOp,
) !topo.SolidId {
    const poly_a = try extractPolygon(allocator, t_arena, solid_a);
    defer allocator.free(poly_a);
    const poly_b = try extractPolygon(allocator, t_arena, solid_b);
    defer allocator.free(poly_b);

    // Calculate global bounding box for the 2D operation to establish adaptive tolerance
    var min_b = math.Vec3{ std.math.inf(f64), std.math.inf(f64), 0 };
    var max_b = math.Vec3{ -std.math.inf(f64), -std.math.inf(f64), 0 };
    for (poly_a) |p| {
        min_b[0] = @min(min_b[0], p[0]);
        min_b[1] = @min(min_b[1], p[1]);
        max_b[0] = @max(max_b[0], p[0]);
        max_b[1] = @max(max_b[1], p[1]);
    }
    for (poly_b) |p| {
        min_b[0] = @min(min_b[0], p[0]);
        min_b[1] = @min(min_b[1], p[1]);
        max_b[0] = @max(max_b[0], p[0]);
        max_b[1] = @max(max_b[1], p[1]);
    }
    const tol = math.Tolerance.fromBoundingBox(min_b, max_b);

    var edges = std.ArrayListUnmanaged(Edge2D).empty;
    defer edges.deinit(allocator);

    // 1. Gather all line segments from both shapes
    try extractEdges(allocator, t_arena, solid_a, true, &edges);
    try extractEdges(allocator, t_arena, solid_b, false, &edges);

    // 2. Iteratively collide and split overlapping edges
    var i: usize = 0;
    while (i < edges.items.len) {
        var j: usize = i + 1;
        var split = false;
        while (j < edges.items.len) {
            if (intersect2D(edges.items[i].start, edges.items[i].end, edges.items[j].start, edges.items[j].end, tol)) |pt| {
                const end_i = edges.items[i].end;
                edges.items[i].end = pt;
                try edges.append(allocator, .{ .start = pt, .end = end_i, .is_a = edges.items[i].is_a });

                const end_j = edges.items[j].end;
                edges.items[j].end = pt;
                try edges.append(allocator, .{ .start = pt, .end = end_j, .is_a = edges.items[j].is_a });

                split = true;
                break;
            }
            j += 1;
        }
        if (!split) i += 1;
    }

    // 3. Keep surviving edges by evaluating midpoints
    var kept_edges = std.ArrayListUnmanaged(Edge2D).empty;
    defer kept_edges.deinit(allocator);

    for (edges.items) |edge| {
        const mid = [2]f64{ (edge.start[0] + edge.end[0]) / 2.0, (edge.start[1] + edge.end[1]) / 2.0 };
        var keep = false;

        if (edge.is_a) {
            const in_b = booleans.isPointInPolygon2D(mid, poly_b, tol);
            keep = switch (op) {
                .union_op => !in_b,
                .difference => !in_b,
                .intersection => in_b,
            };
        } else {
            const in_a = booleans.isPointInPolygon2D(mid, poly_a, tol);
            keep = switch (op) {
                .union_op => !in_a,
                .difference => in_a,
                .intersection => in_a,
            };
        }

        if (keep) {
            var final_edge = edge;
            // Difference inverts B's normals
            if (!edge.is_a and op == .difference) {
                final_edge.start = edge.end;
                final_edge.end = edge.start;
            }
            try kept_edges.append(allocator, final_edge);
        }
    }

    // 4. Trace the continuous boundary loop and repackage as a fresh 2D Solid!
    if (kept_edges.items.len > 0) {
        var pts2d = std.ArrayListUnmanaged([2]f64).empty;
        defer pts2d.deinit(allocator);

        var used = try allocator.alloc(bool, kept_edges.items.len);
        defer allocator.free(used);
        @memset(used, false);

        used[0] = true;
        try pts2d.append(allocator, kept_edges.items[0].start);
        var current_pt = kept_edges.items[0].end;

        while (true) {
            if (tol.pointsCoincide2D(current_pt, pts2d.items[0])) {
                break;
            }

            try pts2d.append(allocator, current_pt);

            var found = false;
            for (kept_edges.items, 0..) |edge, idx| {
                if (!used[idx]) {
                    if (tol.pointsCoincide2D(edge.start, current_pt)) {
                        current_pt = edge.end;
                        used[idx] = true;
                        found = true;
                        break;
                    }
                }
            }
            if (!found) return error.FaceNotFound;
        }

        return generators.generatePolygon(allocator, t_arena, g_arena, pts2d.items);
    }

    if (op == .union_op) {
        // If union and no edges survived, one polygon completely envelopes the other, or they are identical.
        return solid_a;
    }

    return error.FaceNotFound;
}
