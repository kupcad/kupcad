const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const TransformError = error{
    OutOfMemory,
};

/// Helper to multiply a 3D point by a 4x4 row-major matrix.
inline fn transformPt(mat: [16]f64, pt: math.Vec3) math.Vec3 {
    return .{
        pt[0] * mat[0] + pt[1] * mat[4] + pt[2] * mat[8] + mat[12],
        pt[0] * mat[1] + pt[1] * mat[5] + pt[2] * mat[9] + mat[13],
        pt[0] * mat[2] + pt[1] * mat[6] + pt[2] * mat[10] + mat[14],
    };
}

/// Helper to transform a direction vector (ignores translation components).
inline fn transformDir(mat: [16]f64, dir: math.Vec3) math.Vec3 {
    const x = dir[0] * mat[0] + dir[1] * mat[4] + dir[2] * mat[8];
    const y = dir[0] * mat[1] + dir[1] * mat[5] + dir[2] * mat[9];
    const z = dir[0] * mat[2] + dir[1] * mat[6] + dir[2] * mat[10];
    return math.normalize(.{ x, y, z });
}

/// Deep clones a Solid and applies a 4x4 affine transformation matrix to its geometry.
pub fn transformSolid(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    mat: [16]f64,
) TransformError!topo.SolidId {
    // Maps track Old ID -> New ID so we don't duplicate shared elements
    var v_map = std.AutoHashMap(topo.VertexId, topo.VertexId).init(allocator);
    defer v_map.deinit();
    var e_map = std.AutoHashMap(topo.EdgeId, topo.EdgeId).init(allocator);
    defer e_map.deinit();
    var c_map = std.AutoHashMap(geom.CurveId, geom.CurveId).init(allocator);
    defer c_map.deinit();
    var s_map = std.AutoHashMap(geom.SurfaceId, geom.SurfaceId).init(allocator);
    defer s_map.deinit();

    const solid = t_arena.solids.items[solid_id];
    const new_solid_shells_start: u32 = @intCast(t_arena.solid_shells.items.len);

    // 1. Traverse Shells
    for (0..solid.shells_len) |s_offset| {
        const shell_id = t_arena.solid_shells.items[solid.shells_start + s_offset];
        const shell = t_arena.shells.items[shell_id];

        const new_shell_faces_start: u32 = @intCast(t_arena.shell_faces.items.len);

        // 2. Traverse Faces
        for (0..shell.faces_len) |f_offset| {
            const face_id = t_arena.shell_faces.items[shell.faces_start + f_offset];
            const face = t_arena.faces.items[face_id];

            // Clone & Transform the geometric surface
            var new_surf_id = face.surface;
            if (!s_map.contains(face.surface)) {
                new_surf_id = try cloneAndTransformSurface(allocator, g_arena, face.surface, mat);
                try s_map.put(face.surface, new_surf_id);
            } else {
                new_surf_id = s_map.get(face.surface).?;
            }

            const new_face_wires_start: u32 = @intCast(t_arena.face_wires.items.len);

            // 3. Traverse Wires
            for (0..face.wires_len) |w_offset| {
                const wire_id = t_arena.face_wires.items[face.wires_start + w_offset];
                const wire = t_arena.wires.items[wire_id];

                const new_wire_edges_start: u32 = @intCast(t_arena.wire_edges.items.len);

                // 4. Traverse Edges
                for (0..wire.edges_len) |e_idx| {
                    const d_edge = t_arena.wire_edges.items[wire.edges_start + e_idx];
                    const edge = t_arena.edges.items[d_edge.edge];

                    var new_edge_id = d_edge.edge;
                    if (!e_map.contains(d_edge.edge)) {
                        // Clone & Transform Curve
                        var new_curve_id = edge.curve;
                        if (!c_map.contains(edge.curve)) {
                            new_curve_id = try cloneAndTransformCurve(allocator, g_arena, edge.curve, mat);
                            try c_map.put(edge.curve, new_curve_id);
                        } else {
                            new_curve_id = c_map.get(edge.curve).?;
                        }

                        // Clone & Transform Front Vertex
                        var new_front = edge.front;
                        if (!v_map.contains(edge.front)) {
                            const pt = t_arena.vertices.items[edge.front].point;
                            new_front = @intCast(t_arena.vertices.items.len);
                            try t_arena.vertices.append(allocator, .{ .point = transformPt(mat, pt) });
                            try v_map.put(edge.front, new_front);
                        } else {
                            new_front = v_map.get(edge.front).?;
                        }

                        // Clone & Transform Back Vertex
                        var new_back = edge.back;
                        if (!v_map.contains(edge.back)) {
                            const pt = t_arena.vertices.items[edge.back].point;
                            new_back = @intCast(t_arena.vertices.items.len);
                            try t_arena.vertices.append(allocator, .{ .point = transformPt(mat, pt) });
                            try v_map.put(edge.back, new_back);
                        } else {
                            new_back = v_map.get(edge.back).?;
                        }

                        // Assemble New Edge
                        new_edge_id = @intCast(t_arena.edges.items.len);
                        try t_arena.edges.append(allocator, .{
                            .front = new_front,
                            .back = new_back,
                            .curve = new_curve_id,
                        });
                        try e_map.put(d_edge.edge, new_edge_id);
                    } else {
                        new_edge_id = e_map.get(d_edge.edge).?;
                    }

                    // Map DirectedEdge to Wire
                    try t_arena.wire_edges.append(allocator, .{
                        .edge = new_edge_id,
                        .forward = d_edge.forward,
                    });
                }

                // Assemble New Wire
                const new_wire_id: u32 = @intCast(t_arena.wires.items.len);
                try t_arena.wires.append(allocator, .{
                    .edges_start = new_wire_edges_start,
                    .edges_len = wire.edges_len,
                });
                try t_arena.face_wires.append(allocator, new_wire_id);
            }

            // Assemble New Face
            const new_face_id: u32 = @intCast(t_arena.faces.items.len);
            try t_arena.faces.append(allocator, .{
                .surface = new_surf_id,
                .forward = face.forward,
                .wires_start = new_face_wires_start,
                .wires_len = face.wires_len,
            });
            try t_arena.shell_faces.append(allocator, new_face_id);
        }

        // Assemble New Shell
        const new_shell_id: u32 = @intCast(t_arena.shells.items.len);
        try t_arena.shells.append(allocator, .{
            .faces_start = new_shell_faces_start,
            .faces_len = shell.faces_len,
        });
        try t_arena.solid_shells.append(allocator, new_shell_id);
    }

    // Assemble New Solid
    const new_solid_id: u32 = @intCast(t_arena.solids.items.len);
    try t_arena.solids.append(allocator, .{
        .shells_start = new_solid_shells_start,
        .shells_len = solid.shells_len,
    });

    return new_solid_id;
}

// --- Geometry Transformers ---

fn cloneAndTransformSurface(
    allocator: std.mem.Allocator,
    g_arena: *geom.GeometryArena,
    id: geom.SurfaceId,
    mat: [16]f64,
) !geom.SurfaceId {
    switch (id.surface_type) {
        .plane => {
            const p = g_arena.planes.items[id.index];
            const new_idx: u24 = @intCast(g_arena.planes.items.len);
            try g_arena.planes.append(allocator, .{
                .origin = transformPt(mat, p.origin),
                .u_axis = transformDir(mat, p.u_axis),
                .v_axis = transformDir(mat, p.v_axis),
            });
            return geom.SurfaceId{ .index = new_idx, .surface_type = .plane };
        },
        .cylinder => {
            const c = g_arena.cylinders.items[id.index];
            const new_idx: u24 = @intCast(g_arena.cylinders.items.len);
            try g_arena.cylinders.append(allocator, .{
                .origin = transformPt(mat, c.origin),
                .axis = transformDir(mat, c.axis),
                .x_axis = transformDir(mat, c.x_axis),
                .y_axis = transformDir(mat, c.y_axis),
                .radius = c.radius,
            });
            return geom.SurfaceId{ .index = new_idx, .surface_type = .cylinder };
        },
        .sphere => {
            const s = g_arena.spheres.items[id.index];
            const new_idx: u24 = @intCast(g_arena.spheres.items.len);
            try g_arena.spheres.append(allocator, .{
                .center = transformPt(mat, s.center),
                .radius = s.radius,
            });
            return geom.SurfaceId{ .index = new_idx, .surface_type = .sphere };
        },
        .nurbs => unreachable,
    }
}

fn cloneAndTransformCurve(
    allocator: std.mem.Allocator,
    g_arena: *geom.GeometryArena,
    id: geom.CurveId,
    mat: [16]f64,
) !geom.CurveId {
    switch (id.curve_type) {
        .line => {
            const l = g_arena.lines.items[id.index];
            const new_idx: u24 = @intCast(g_arena.lines.items.len);
            try g_arena.lines.append(allocator, .{
                .start = transformPt(mat, l.start),
                .end = transformPt(mat, l.end),
            });
            return geom.CurveId{ .index = new_idx, .curve_type = .line };
        },
        .circle_arc => {
            const c = g_arena.circle_arcs.items[id.index];
            const new_idx: u24 = @intCast(g_arena.circle_arcs.items.len);
            try g_arena.circle_arcs.append(allocator, .{
                .center = transformPt(mat, c.center),
                .radius = c.radius,
                .x_axis = transformDir(mat, c.x_axis),
                .y_axis = transformDir(mat, c.y_axis),
            });
            return geom.CurveId{ .index = new_idx, .curve_type = .circle_arc };
        },
        .nurbs => unreachable,
    }
}

// --- High Level Public Transformers ---

pub fn translateSolid(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    x: f64,
    y: f64,
    z: f64,
) TransformError!topo.SolidId {
    const mat = [_]f64{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        x, y, z, 1,
    };
    return transformSolid(allocator, t_arena, g_arena, solid_id, mat);
}

pub fn scaleSolid(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    sx: f64,
    sy: f64,
    sz: f64,
) TransformError!topo.SolidId {
    const mat = [_]f64{
        sx, 0,  0,  0,
        0,  sy, 0,  0,
        0,  0,  sz, 0,
        0,  0,  0,  1,
    };
    return transformSolid(allocator, t_arena, g_arena, solid_id, mat);
}
