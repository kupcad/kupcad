const std = @import("std");
const topo = @import("topology.zig");
const geom = @import("geometry.zig");
const math = @import("math.zig");

pub const TransformError = error{OutOfMemory};

fn collectSolidGeometry(
    allocator: std.mem.Allocator,
    t_arena: *const topo.TopologyArena,
    solid_id: topo.SolidId,
    vertices: *std.AutoHashMap(topo.VertexId, void),
    lines: *std.AutoHashMap(u24, void),
    arcs: *std.AutoHashMap(u24, void),
    planes: *std.AutoHashMap(u24, void),
    spheres: *std.AutoHashMap(u24, void),
    cylinders: *std.AutoHashMap(u24, void),
    cones: *std.AutoHashMap(u24, void),
    toruses: *std.AutoHashMap(u24, void),
) !void {
    _ = allocator;
    const solid = t_arena.solids.items[solid_id];
    for (0..solid.shells_len) |s_off| {
        const shell = t_arena.shells.items[t_arena.solid_shells.items[solid.shells_start + s_off]];
        for (0..shell.faces_len) |f_off| {
            const face = t_arena.faces.items[t_arena.shell_faces.items[shell.faces_start + f_off]];
            switch (face.surface.surface_type) {
                .plane => try planes.put(face.surface.index, {}),
                .sphere => try spheres.put(face.surface.index, {}),
                .cylinder => try cylinders.put(face.surface.index, {}),
                .cone => try cones.put(face.surface.index, {}),
                .torus => try toruses.put(face.surface.index, {}),
                else => {},
            }
            for (0..face.loops_len) |l_off| {
                const loop_id = t_arena.face_loops.items[face.loops_start + l_off];
                const loop = t_arena.loops.items[loop_id];
                var current_he = loop.first_half_edge;
                while (true) {
                    const he = t_arena.half_edges.items[current_he];
                    try vertices.put(he.start_vertex, {});
                    switch (he.curve.curve_type) {
                        .line => try lines.put(he.curve.index, {}),
                        .circle_arc => try arcs.put(he.curve.index, {}),
                        else => {},
                    }
                    current_he = he.next;
                    if (current_he == loop.first_half_edge) break;
                }
            }
        }
    }
}

pub fn translateSolid(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    tx: f64,
    ty: f64,
    tz: f64,
) TransformError!topo.SolidId {
    var v_map = std.AutoHashMap(topo.VertexId, void).init(allocator);
    defer v_map.deinit();
    var l_map = std.AutoHashMap(u24, void).init(allocator);
    defer l_map.deinit();
    var a_map = std.AutoHashMap(u24, void).init(allocator);
    defer a_map.deinit();
    var p_map = std.AutoHashMap(u24, void).init(allocator);
    defer p_map.deinit();
    var s_map = std.AutoHashMap(u24, void).init(allocator);
    defer s_map.deinit();
    var c_map = std.AutoHashMap(u24, void).init(allocator);
    defer c_map.deinit();
    var co_map = std.AutoHashMap(u24, void).init(allocator);
    defer co_map.deinit();
    var t_map = std.AutoHashMap(u24, void).init(allocator);
    defer t_map.deinit();

    try collectSolidGeometry(allocator, t_arena, solid_id, &v_map, &l_map, &a_map, &p_map, &s_map, &c_map, &co_map, &t_map);

    const offset = math.Vec3{ tx, ty, tz };

    var v_it = v_map.keyIterator();
    while (v_it.next()) |v| t_arena.vertices.items[v.*].point = math.add(t_arena.vertices.items[v.*].point, offset);

    var l_it = l_map.keyIterator();
    while (l_it.next()) |l| {
        g_arena.lines.items[l.*].start = math.add(g_arena.lines.items[l.*].start, offset);
        g_arena.lines.items[l.*].end = math.add(g_arena.lines.items[l.*].end, offset);
    }

    var a_it = a_map.keyIterator();
    while (a_it.next()) |a| g_arena.circle_arcs.items[a.*].center = math.add(g_arena.circle_arcs.items[a.*].center, offset);

    var p_it = p_map.keyIterator();
    while (p_it.next()) |p| g_arena.planes.items[p.*].origin = math.add(g_arena.planes.items[p.*].origin, offset);

    var s_it = s_map.keyIterator();
    while (s_it.next()) |s| g_arena.spheres.items[s.*].center = math.add(g_arena.spheres.items[s.*].center, offset);

    var c_it = c_map.keyIterator();
    while (c_it.next()) |c| g_arena.cylinders.items[c.*].origin = math.add(g_arena.cylinders.items[c.*].origin, offset);

    var co_it = co_map.keyIterator();
    while (co_it.next()) |co| g_arena.cones.items[co.*].origin = math.add(g_arena.cones.items[co.*].origin, offset);

    var t_it = t_map.keyIterator();
    while (t_it.next()) |to| g_arena.toruses.items[to.*].center = math.add(g_arena.toruses.items[to.*].center, offset);

    return solid_id;
}

fn applyRotation(pt: math.Vec3, rx: f64, ry: f64, rz: f64) math.Vec3 {
    const rad_x = rx * std.math.pi / 180.0;
    const rad_y = ry * std.math.pi / 180.0;
    const rad_z = rz * std.math.pi / 180.0;
    const cx = @cos(rad_x);
    const sx = @sin(rad_x);
    const cy = @cos(rad_y);
    const sy = @sin(rad_y);
    const cz = @cos(rad_z);
    const sz = @sin(rad_z);

    const m00 = cy * cz;
    const m01 = cz * sx * sy - cx * sz;
    const m02 = cx * cz * sy + sx * sz;
    const m10 = cy * sz;
    const m11 = cx * cz + sx * sy * sz;
    const m12 = -cz * sx + cx * sy * sz;
    const m20 = -sy;
    const m21 = cy * sx;
    const m22 = cx * cy;

    return .{
        pt[0] * m00 + pt[1] * m01 + pt[2] * m02,
        pt[0] * m10 + pt[1] * m11 + pt[2] * m12,
        pt[0] * m20 + pt[1] * m21 + pt[2] * m22,
    };
}

pub fn rotateSolid(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    rx: f64,
    ry: f64,
    rz: f64,
) TransformError!topo.SolidId {
    var v_map = std.AutoHashMap(topo.VertexId, void).init(allocator);
    defer v_map.deinit();
    var l_map = std.AutoHashMap(u24, void).init(allocator);
    defer l_map.deinit();
    var a_map = std.AutoHashMap(u24, void).init(allocator);
    defer a_map.deinit();
    var p_map = std.AutoHashMap(u24, void).init(allocator);
    defer p_map.deinit();
    var s_map = std.AutoHashMap(u24, void).init(allocator);
    defer s_map.deinit();
    var c_map = std.AutoHashMap(u24, void).init(allocator);
    defer c_map.deinit();
    var co_map = std.AutoHashMap(u24, void).init(allocator);
    defer co_map.deinit();
    var t_map = std.AutoHashMap(u24, void).init(allocator);
    defer t_map.deinit();

    try collectSolidGeometry(allocator, t_arena, solid_id, &v_map, &l_map, &a_map, &p_map, &s_map, &c_map, &co_map, &t_map);

    var v_it = v_map.keyIterator();
    while (v_it.next()) |v| t_arena.vertices.items[v.*].point = applyRotation(t_arena.vertices.items[v.*].point, rx, ry, rz);

    var l_it = l_map.keyIterator();
    while (l_it.next()) |l| {
        g_arena.lines.items[l.*].start = applyRotation(g_arena.lines.items[l.*].start, rx, ry, rz);
        g_arena.lines.items[l.*].end = applyRotation(g_arena.lines.items[l.*].end, rx, ry, rz);
    }

    var a_it = a_map.keyIterator();
    while (a_it.next()) |a| {
        g_arena.circle_arcs.items[a.*].center = applyRotation(g_arena.circle_arcs.items[a.*].center, rx, ry, rz);
        g_arena.circle_arcs.items[a.*].x_axis = math.normalize(applyRotation(g_arena.circle_arcs.items[a.*].x_axis, rx, ry, rz));
        g_arena.circle_arcs.items[a.*].y_axis = math.normalize(applyRotation(g_arena.circle_arcs.items[a.*].y_axis, rx, ry, rz));
    }

    var p_it = p_map.keyIterator();
    while (p_it.next()) |p| {
        g_arena.planes.items[p.*].origin = applyRotation(g_arena.planes.items[p.*].origin, rx, ry, rz);
        g_arena.planes.items[p.*].u_axis = math.normalize(applyRotation(g_arena.planes.items[p.*].u_axis, rx, ry, rz));
        g_arena.planes.items[p.*].v_axis = math.normalize(applyRotation(g_arena.planes.items[p.*].v_axis, rx, ry, rz));
    }

    var s_it = s_map.keyIterator();
    while (s_it.next()) |s| g_arena.spheres.items[s.*].center = applyRotation(g_arena.spheres.items[s.*].center, rx, ry, rz);

    var c_it = c_map.keyIterator();
    while (c_it.next()) |c| {
        g_arena.cylinders.items[c.*].origin = applyRotation(g_arena.cylinders.items[c.*].origin, rx, ry, rz);
        g_arena.cylinders.items[c.*].axis = math.normalize(applyRotation(g_arena.cylinders.items[c.*].axis, rx, ry, rz));
        g_arena.cylinders.items[c.*].x_axis = math.normalize(applyRotation(g_arena.cylinders.items[c.*].x_axis, rx, ry, rz));
        g_arena.cylinders.items[c.*].y_axis = math.normalize(applyRotation(g_arena.cylinders.items[c.*].y_axis, rx, ry, rz));
    }

    var co_it = co_map.keyIterator();
    while (co_it.next()) |co| {
        g_arena.cones.items[co.*].origin = applyRotation(g_arena.cones.items[co.*].origin, rx, ry, rz);
        g_arena.cones.items[co.*].axis = math.normalize(applyRotation(g_arena.cones.items[co.*].axis, rx, ry, rz));
        g_arena.cones.items[co.*].x_axis = math.normalize(applyRotation(g_arena.cones.items[co.*].x_axis, rx, ry, rz));
        g_arena.cones.items[co.*].y_axis = math.normalize(applyRotation(g_arena.cones.items[co.*].y_axis, rx, ry, rz));
    }

    var t_it = t_map.keyIterator();
    while (t_it.next()) |to| {
        g_arena.toruses.items[to.*].center = applyRotation(g_arena.toruses.items[to.*].center, rx, ry, rz);
        g_arena.toruses.items[to.*].axis = math.normalize(applyRotation(g_arena.toruses.items[to.*].axis, rx, ry, rz));
        g_arena.toruses.items[to.*].x_axis = math.normalize(applyRotation(g_arena.toruses.items[to.*].x_axis, rx, ry, rz));
        g_arena.toruses.items[to.*].y_axis = math.normalize(applyRotation(g_arena.toruses.items[to.*].y_axis, rx, ry, rz));
    }

    return solid_id;
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
    var v_map = std.AutoHashMap(topo.VertexId, void).init(allocator);
    defer v_map.deinit();
    var l_map = std.AutoHashMap(u24, void).init(allocator);
    defer l_map.deinit();
    var a_map = std.AutoHashMap(u24, void).init(allocator);
    defer a_map.deinit();
    var p_map = std.AutoHashMap(u24, void).init(allocator);
    defer p_map.deinit();
    var s_map = std.AutoHashMap(u24, void).init(allocator);
    defer s_map.deinit();
    var c_map = std.AutoHashMap(u24, void).init(allocator);
    defer c_map.deinit();
    var co_map = std.AutoHashMap(u24, void).init(allocator);
    defer co_map.deinit();
    var t_map = std.AutoHashMap(u24, void).init(allocator);
    defer t_map.deinit();

    try collectSolidGeometry(allocator, t_arena, solid_id, &v_map, &l_map, &a_map, &p_map, &s_map, &c_map, &co_map, &t_map);

    const uniform_scale = (sx + sy + sz) / 3.0;

    var v_it = v_map.keyIterator();
    while (v_it.next()) |v| {
        t_arena.vertices.items[v.*].point[0] *= sx;
        t_arena.vertices.items[v.*].point[1] *= sy;
        t_arena.vertices.items[v.*].point[2] *= sz;
    }

    var l_it = l_map.keyIterator();
    while (l_it.next()) |l| {
        g_arena.lines.items[l.*].start[0] *= sx;
        g_arena.lines.items[l.*].start[1] *= sy;
        g_arena.lines.items[l.*].start[2] *= sz;
        g_arena.lines.items[l.*].end[0] *= sx;
        g_arena.lines.items[l.*].end[1] *= sy;
        g_arena.lines.items[l.*].end[2] *= sz;
    }

    var a_it = a_map.keyIterator();
    while (a_it.next()) |a| {
        g_arena.circle_arcs.items[a.*].center[0] *= sx;
        g_arena.circle_arcs.items[a.*].center[1] *= sy;
        g_arena.circle_arcs.items[a.*].center[2] *= sz;
        g_arena.circle_arcs.items[a.*].radius *= uniform_scale;
    }

    var p_it = p_map.keyIterator();
    while (p_it.next()) |p| {
        g_arena.planes.items[p.*].origin[0] *= sx;
        g_arena.planes.items[p.*].origin[1] *= sy;
        g_arena.planes.items[p.*].origin[2] *= sz;
    }

    var s_it = s_map.keyIterator();
    while (s_it.next()) |s| {
        g_arena.spheres.items[s.*].center[0] *= sx;
        g_arena.spheres.items[s.*].center[1] *= sy;
        g_arena.spheres.items[s.*].center[2] *= sz;
        g_arena.spheres.items[s.*].radius *= uniform_scale;
    }

    var c_it = c_map.keyIterator();
    while (c_it.next()) |c| {
        g_arena.cylinders.items[c.*].origin[0] *= sx;
        g_arena.cylinders.items[c.*].origin[1] *= sy;
        g_arena.cylinders.items[c.*].origin[2] *= sz;
        g_arena.cylinders.items[c.*].radius *= uniform_scale;
    }

    var co_it = co_map.keyIterator();
    while (co_it.next()) |co| {
        g_arena.cones.items[co.*].origin[0] *= sx;
        g_arena.cones.items[co.*].origin[1] *= sy;
        g_arena.cones.items[co.*].origin[2] *= sz;
        g_arena.cones.items[co.*].radius *= uniform_scale;
    }

    var t_it = t_map.keyIterator();
    while (t_it.next()) |to| {
        g_arena.toruses.items[to.*].center[0] *= sx;
        g_arena.toruses.items[to.*].center[1] *= sy;
        g_arena.toruses.items[to.*].center[2] *= sz;
        g_arena.toruses.items[to.*].major_radius *= uniform_scale;
        g_arena.toruses.items[to.*].minor_radius *= uniform_scale;
    }

    return solid_id;
}

pub fn transformMatrixSolid(
    allocator: std.mem.Allocator,
    t_arena: *topo.TopologyArena,
    g_arena: *geom.GeometryArena,
    solid_id: topo.SolidId,
    mat: [12]f64,
) TransformError!topo.SolidId {
    var v_map = std.AutoHashMap(topo.VertexId, void).init(allocator);
    defer v_map.deinit();
    var l_map = std.AutoHashMap(u24, void).init(allocator);
    defer l_map.deinit();
    var a_map = std.AutoHashMap(u24, void).init(allocator);
    defer a_map.deinit();
    var p_map = std.AutoHashMap(u24, void).init(allocator);
    defer p_map.deinit();
    var s_map = std.AutoHashMap(u24, void).init(allocator);
    defer s_map.deinit();
    var c_map = std.AutoHashMap(u24, void).init(allocator);
    defer c_map.deinit();
    var co_map = std.AutoHashMap(u24, void).init(allocator);
    defer co_map.deinit();
    var t_map = std.AutoHashMap(u24, void).init(allocator);
    defer t_map.deinit();

    try collectSolidGeometry(allocator, t_arena, solid_id, &v_map, &l_map, &a_map, &p_map, &s_map, &c_map, &co_map, &t_map);

    const applyMat = struct {
        fn apply(pt: math.Vec3, m: [12]f64) math.Vec3 {
            return .{
                pt[0] * m[0] + pt[1] * m[1] + pt[2] * m[2] + m[3],
                pt[0] * m[4] + pt[1] * m[5] + pt[2] * m[6] + m[7],
                pt[0] * m[8] + pt[1] * m[9] + pt[2] * m[10] + m[11],
            };
        }
        fn applyDir(vec: math.Vec3, m: [12]f64) math.Vec3 {
            return math.normalize(.{
                vec[0] * m[0] + vec[1] * m[1] + vec[2] * m[2],
                vec[0] * m[4] + vec[1] * m[5] + vec[2] * m[6],
                vec[0] * m[8] + vec[1] * m[9] + vec[2] * m[10],
            });
        }
    };

    var v_it = v_map.keyIterator();
    while (v_it.next()) |v| t_arena.vertices.items[v.*].point = applyMat.apply(t_arena.vertices.items[v.*].point, mat);

    var l_it = l_map.keyIterator();
    while (l_it.next()) |l| {
        g_arena.lines.items[l.*].start = applyMat.apply(g_arena.lines.items[l.*].start, mat);
        g_arena.lines.items[l.*].end = applyMat.apply(g_arena.lines.items[l.*].end, mat);
    }

    var p_it = p_map.keyIterator();
    while (p_it.next()) |p| {
        g_arena.planes.items[p.*].origin = applyMat.apply(g_arena.planes.items[p.*].origin, mat);
        g_arena.planes.items[p.*].u_axis = applyMat.applyDir(g_arena.planes.items[p.*].u_axis, mat);
        g_arena.planes.items[p.*].v_axis = applyMat.applyDir(g_arena.planes.items[p.*].v_axis, mat);
    }

    const scale_factor = @sqrt(mat[0] * mat[0] + mat[4] * mat[4] + mat[8] * mat[8]);

    var c_it = c_map.keyIterator();
    while (c_it.next()) |c| {
        g_arena.cylinders.items[c.*].origin = applyMat.apply(g_arena.cylinders.items[c.*].origin, mat);
        g_arena.cylinders.items[c.*].axis = applyMat.applyDir(g_arena.cylinders.items[c.*].axis, mat);
        g_arena.cylinders.items[c.*].x_axis = applyMat.applyDir(g_arena.cylinders.items[c.*].x_axis, mat);
        g_arena.cylinders.items[c.*].y_axis = applyMat.applyDir(g_arena.cylinders.items[c.*].y_axis, mat);
        g_arena.cylinders.items[c.*].radius *= scale_factor;
    }

    var s_it = s_map.keyIterator();
    while (s_it.next()) |s| {
        g_arena.spheres.items[s.*].center = applyMat.apply(g_arena.spheres.items[s.*].center, mat);
        g_arena.spheres.items[s.*].radius *= scale_factor;
    }

    var co_it = co_map.keyIterator();
    while (co_it.next()) |co| {
        g_arena.cones.items[co.*].origin = applyMat.apply(g_arena.cones.items[co.*].origin, mat);
        g_arena.cones.items[co.*].axis = applyMat.applyDir(g_arena.cones.items[co.*].axis, mat);
        g_arena.cones.items[co.*].x_axis = applyMat.applyDir(g_arena.cones.items[co.*].x_axis, mat);
        g_arena.cones.items[co.*].y_axis = applyMat.applyDir(g_arena.cones.items[co.*].y_axis, mat);
        g_arena.cones.items[co.*].radius *= scale_factor;
    }

    var t_it = t_map.keyIterator();
    while (t_it.next()) |to| {
        g_arena.toruses.items[to.*].center = applyMat.apply(g_arena.toruses.items[to.*].center, mat);
        g_arena.toruses.items[to.*].axis = applyMat.applyDir(g_arena.toruses.items[to.*].axis, mat);
        g_arena.toruses.items[to.*].x_axis = applyMat.applyDir(g_arena.toruses.items[to.*].x_axis, mat);
        g_arena.toruses.items[to.*].y_axis = applyMat.applyDir(g_arena.toruses.items[to.*].y_axis, mat);
        g_arena.toruses.items[to.*].major_radius *= scale_factor;
        g_arena.toruses.items[to.*].minor_radius *= scale_factor;
    }

    return solid_id;
}
