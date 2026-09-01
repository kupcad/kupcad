const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const geom = @import("../../kernel/geometry_handle.zig");
const brep_driver = @import("../../kernel/engines/brep/driver.zig");
const topo = @import("../../locus/src/topology.zig");
const locus_geom = @import("../../locus/src/geometry.zig");
const locus_math = @import("../../locus/src/math.zig");

const StepSerializer = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8),
    id_counter: u32,

    fn init(allocator: std.mem.Allocator) StepSerializer {
        return .{
            .allocator = allocator,
            .out = .empty,
            .id_counter = 16, // Reserve 1-16 for AP214 Header Boilerplate
        };
    }

    fn nextId(self: *StepSerializer) u32 {
        self.id_counter += 1;
        return self.id_counter;
    }

    fn emit(self: *StepSerializer, comptime fmt: []const u8, args: anytype) !u32 {
        const id = self.nextId();
        var id_buf: [32]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, "#{d}=", .{id});
        try self.out.appendSlice(self.allocator, id_str);
        const record_str = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(record_str);
        try self.out.appendSlice(self.allocator, record_str);
        try self.out.appendSlice(self.allocator, ";\n");
        return id;
    }
};

const EdgeKey = struct {
    v1: u32,
    v2: u32,
};

const FullCircleEntry = struct {
    ec1: u32,
    ec2: u32,
};

/// Computes the exact 3D plane normal and origin directly from a loop's vertices using Newell's method.
fn computeLoopNormalAndOrigin(
    t: *const topo.TopologyArena,
    loop: topo.Loop,
) !struct { origin: locus_math.Vec3, normal: locus_math.Vec3 } {
    var nx: f64 = 0;
    var ny: f64 = 0;
    var nz: f64 = 0;
    var curr_he = loop.first_half_edge;
    if (curr_he >= t.half_edges.items.len) return error.CorruptTopology;

    const start_v_id = t.half_edges.items[curr_he].start_vertex;
    if (start_v_id >= t.vertices.items.len) return error.CorruptTopology;
    const p0 = t.vertices.items[start_v_id].point;

    var safety_counter: u32 = 0;
    while (curr_he != topo.NULL_ID and curr_he < t.half_edges.items.len) {
        const he_c = t.half_edges.items[curr_he];
        if (he_c.next == topo.NULL_ID or he_c.next >= t.half_edges.items.len) break;

        if (he_c.start_vertex >= t.vertices.items.len) return error.CorruptTopology;
        const p_c = t.vertices.items[he_c.start_vertex].point;

        const next_he = t.half_edges.items[he_c.next];
        if (next_he.start_vertex >= t.vertices.items.len) return error.CorruptTopology;
        const p_n = t.vertices.items[next_he.start_vertex].point;

        nx += (p_c[1] - p_n[1]) * (p_c[2] + p_n[2]);
        ny += (p_c[2] - p_n[2]) * (p_c[0] + p_n[0]);
        nz += (p_c[0] - p_n[0]) * (p_c[1] + p_n[1]);

        curr_he = he_c.next;
        safety_counter += 1;
        if (curr_he == loop.first_half_edge or safety_counter > 10000) break;
    }

    var n_ax = locus_math.normalize(.{ nx, ny, nz });
    if (locus_math.magSq(n_ax) < 1e-12) n_ax = .{ 0, 0, 1 };

    return .{ .origin = p0, .normal = n_ax };
}

/// Helper to fetch or create a straight LINE EDGE_CURVE for shared internal diagonal edges during triangulation.
fn getOrCreateLineEdge(
    s: *StepSerializer,
    t: *const topo.TopologyArena,
    vertex_map: *const std.AutoHashMap(u32, u32),
    edge_map: *std.AutoHashMap(EdgeKey, u32),
    v1_id: u32,
    v2_id: u32,
) !u32 {
    const v_min = @min(v1_id, v2_id);
    const v_max = @max(v1_id, v2_id);
    const key = EdgeKey{ .v1 = v_min, .v2 = v_max };

    if (edge_map.get(key)) |ec_id| {
        return ec_id;
    }

    const p1 = t.vertices.items[v_min].point;
    const p2 = t.vertices.items[v_max].point;
    const dx = p2[0] - p1[0];
    const dy = p2[1] - p1[1];
    const dz = p2[2] - p1[2];
    var len = @sqrt(dx * dx + dy * dy + dz * dz);
    if (len < 1e-12) len = 1.0;

    const dir_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ dx / len, dy / len, dz / len });
    const vec_id = try s.emit("VECTOR('',#{d},1.0)", .{dir_id});
    const origin_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ p1[0], p1[1], p1[2] });
    const curve_entity_id = try s.emit("LINE('',#{d},#{d})", .{ origin_id, vec_id });

    const v_min_step = vertex_map.get(v_min) orelse return error.CorruptTopology;
    const v_max_step = vertex_map.get(v_max) orelse return error.CorruptTopology;
    const edge_curve_id = try s.emit("EDGE_CURVE('',#{d},#{d},#{d},.T.)", .{ v_min_step, v_max_step, curve_entity_id });

    try edge_map.put(key, edge_curve_id);
    return edge_curve_id;
}

/// Generates a valid ISO 10303-21 STEP file buffer supporting Multi-Solid Assemblies.
pub fn buildStepBuffer(allocator: std.mem.Allocator, handles: []const geom.GeometryHandle) ![]const u8 {
    var s = StepSerializer.init(allocator);
    errdefer s.out.deinit(allocator);

    // 1. Pre-Allocate IDs for MANIFOLD_SOLID_BREP components in the assembly
    var solid_rep_ids = std.ArrayListUnmanaged(u32).empty;
    defer solid_rep_ids.deinit(allocator);

    for (handles) |h| {
        if (h.engine == .brep_native) {
            s.id_counter += 1;
            try solid_rep_ids.append(allocator, s.id_counter);
        }
    }
    if (solid_rep_ids.items.len == 0) return error.NoGeometry;

    var rep_list_str = std.ArrayListUnmanaged(u8).empty;
    defer rep_list_str.deinit(allocator);
    for (solid_rep_ids.items, 0..) |id, i| {
        if (i > 0) try rep_list_str.appendSlice(allocator, ",");
        var tmp: [32]u8 = undefined;
        try rep_list_str.appendSlice(allocator, try std.fmt.bufPrint(&tmp, "#{d}", .{id}));
    }

    // 2. Write AP214 Header with Multi-Solid shape representations
    try s.out.appendSlice(allocator,
        \\ISO-10303-21;
        \\HEADER;
        \\FILE_DESCRIPTION(('KupCAD Native B-Rep Export'),'2;1');
        \\FILE_NAME('kupcad_export.step','2026-08-28',('KupCAD'),(''),'','','');
        \\FILE_SCHEMA(('AUTOMOTIVE_DESIGN { 1 0 10303 214 1 1 1 1 }'));
        \\ENDSEC;
        \\DATA;
        \\#1=APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2001,#2);
        \\#2=APPLICATION_CONTEXT('core data for automotive mechanical design processes');
        \\#3=SHAPE_DEFINITION_REPRESENTATION(#4,#10);
        \\#4=PRODUCT_DEFINITION_SHAPE('','',#5);
        \\#5=PRODUCT_DEFINITION('design','',#6,#9);
        \\#6=PRODUCT_DEFINITION_FORMATION('','',#7);
        \\#7=PRODUCT('KupCAD Part','KupCAD Part','',(#8));
        \\#8=PRODUCT_CONTEXT('',#2,'mechanical');
        \\#9=PRODUCT_DEFINITION_CONTEXT('part definition',#2,'design');
        \\
    );

    var header_rep: [256]u8 = undefined;
    try s.out.appendSlice(allocator, try std.fmt.bufPrint(&header_rep, "#10=ADVANCED_BREP_SHAPE_REPRESENTATION('',({s}),#12);\n", .{rep_list_str.items}));

    try s.out.appendSlice(allocator,
        \\#12=(GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#13)) GLOBAL_UNIT_ASSIGNED_CONTEXT((#14,#15,#16)) REPRESENTATION_CONTEXT('Context #1','3D Context with UNITS and UNCERTAINTY'));
        \\#13=UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-07),#14,'distance_accuracy_value','confusion accuracy');
        \\#14=(LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.));
        \\#15=(NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.));
        \\#16=(NAMED_UNIT(*) SI_UNIT($,.STERADIAN.) SOLID_ANGLE_UNIT());
        \\
    );

    // 3. Serialize Geometry per Component
    var valid_idx: usize = 0;
    for (handles) |handle| {
        if (handle.engine != .brep_native) continue;
        const step_solid_id = solid_rep_ids.items[valid_idx];
        valid_idx += 1;

        const solid: *brep_driver.BrepSolid = @ptrCast(@alignCast(handle.ptr));
        const t = &solid.t_arena;
        const g = &solid.g_arena;

        const active_solid_id = solid.solid_id;
        if (active_solid_id >= t.solids.items.len) continue;

        var active_shells = std.AutoHashMap(u32, void).init(allocator);
        defer active_shells.deinit();
        var active_faces = std.AutoHashMap(u32, void).init(allocator);
        defer active_faces.deinit();
        var active_loops = std.AutoHashMap(u32, void).init(allocator);
        defer active_loops.deinit();
        var active_half_edges = std.AutoHashMap(u32, void).init(allocator);
        defer active_half_edges.deinit();
        var active_vertices = std.AutoHashMap(u32, void).init(allocator);
        defer active_vertices.deinit();

        const target_solid = t.solids.items[active_solid_id];
        for (0..target_solid.shells_len) |s_off| {
            const shell_id = t.solid_shells.items[target_solid.shells_start + s_off];
            try active_shells.put(shell_id, {});
            const shell = t.shells.items[shell_id];

            for (0..shell.faces_len) |f_off| {
                const face_id = t.shell_faces.items[shell.faces_start + f_off];
                try active_faces.put(face_id, {});
                const face = t.faces.items[face_id];

                for (0..face.loops_len) |l_off| {
                    const loop_id = t.face_loops.items[face.loops_start + l_off];
                    try active_loops.put(loop_id, {});
                    const loop = t.loops.items[loop_id];

                    var curr_he = loop.first_half_edge;
                    var safety_counter: u32 = 0;
                    while (curr_he != topo.NULL_ID and curr_he < t.half_edges.items.len) {
                        try active_half_edges.put(curr_he, {});
                        const he = t.half_edges.items[curr_he];
                        try active_vertices.put(he.start_vertex, {});

                        curr_he = he.next;
                        safety_counter += 1;
                        if (curr_he == loop.first_half_edge or safety_counter > 10000) break;
                    }
                }
            }
        }

        var vertex_map = std.AutoHashMap(u32, u32).init(allocator);
        defer vertex_map.deinit();

        for (t.vertices.items, 0..) |v, i| {
            if (!active_vertices.contains(@intCast(i))) continue;
            const pt_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ v.point[0], v.point[1], v.point[2] });
            try vertex_map.put(@intCast(i), try s.emit("VERTEX_POINT('',#{d})", .{pt_id}));
        }

        // Deterministic Canonical Edge Mapping
        var edge_map = std.AutoHashMap(EdgeKey, u32).init(allocator);
        defer edge_map.deinit();

        var full_circle_map = std.AutoHashMap(u32, FullCircleEntry).init(allocator);
        defer full_circle_map.deinit();

        for (t.half_edges.items, 0..) |he, i| {
            if (!active_half_edges.contains(@intCast(i))) continue;
            if (he.next == topo.NULL_ID or he.next >= t.half_edges.items.len) return error.CorruptTopology;

            const next_he = t.half_edges.items[he.next];
            const v1_id = he.start_vertex;
            const v2_id = next_he.start_vertex;

            if (v1_id >= t.vertices.items.len or v2_id >= t.vertices.items.len) return error.CorruptTopology;

            if (v1_id == v2_id and he.curve.curve_type == .circle_arc) {
                if (!full_circle_map.contains(he.curve.index)) {
                    if (he.curve.index >= g.circle_arcs.items.len) return error.CorruptTopology;
                    const arc = g.circle_arcs.items[he.curve.index];
                    const p1 = t.vertices.items[v1_id].point;

                    const center_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ arc.center[0], arc.center[1], arc.center[2] });
                    const nx = arc.x_axis[1] * arc.y_axis[2] - arc.x_axis[2] * arc.y_axis[1];
                    const ny = arc.x_axis[2] * arc.y_axis[0] - arc.x_axis[0] * arc.y_axis[2];
                    const nz = arc.x_axis[0] * arc.y_axis[1] - arc.x_axis[1] * arc.y_axis[0];

                    const z_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ nx, ny, nz });
                    const x_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ arc.x_axis[0], arc.x_axis[1], arc.x_axis[2] });

                    const axis2 = try s.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ center_id, z_axis_id, x_axis_id });
                    const circle_id = try s.emit("CIRCLE('',#{d},{d:.6})", .{ axis2, arc.radius });

                    const p_anti = .{ 2.0 * arc.center[0] - p1[0], 2.0 * arc.center[1] - p1[1], 2.0 * arc.center[2] - p1[2] };
                    const anti_pt_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ p_anti[0], p_anti[1], p_anti[2] });
                    const anti_v_id = try s.emit("VERTEX_POINT('',#{d})", .{anti_pt_id});

                    const v1_step = vertex_map.get(v1_id) orelse return error.CorruptTopology;
                    const edge_curve_1 = try s.emit("EDGE_CURVE('',#{d},#{d},#{d},.T.)", .{ v1_step, anti_v_id, circle_id });
                    const edge_curve_2 = try s.emit("EDGE_CURVE('',#{d},#{d},#{d},.T.)", .{ anti_v_id, v1_step, circle_id });

                    try full_circle_map.put(he.curve.index, .{ .ec1 = edge_curve_1, .ec2 = edge_curve_2 });
                }
            } else if (v1_id != v2_id) {
                const v_min = @min(v1_id, v2_id);
                const v_max = @max(v1_id, v2_id);
                const key = EdgeKey{ .v1 = v_min, .v2 = v_max };

                if (!edge_map.contains(key)) {
                    const p1 = t.vertices.items[v_min].point;
                    const p2 = t.vertices.items[v_max].point;
                    var curve_entity_id: u32 = 0;
                    var same_sense = true;

                    switch (he.curve.curve_type) {
                        .circle_arc => {
                            if (he.curve.index >= g.circle_arcs.items.len) return error.CorruptTopology;
                            const arc = g.circle_arcs.items[he.curve.index];
                            const center_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ arc.center[0], arc.center[1], arc.center[2] });
                            const nx = arc.x_axis[1] * arc.y_axis[2] - arc.x_axis[2] * arc.y_axis[1];
                            const ny = arc.x_axis[2] * arc.y_axis[0] - arc.x_axis[0] * arc.y_axis[2];
                            const nz = arc.x_axis[0] * arc.y_axis[1] - arc.x_axis[1] * arc.y_axis[0];
                            const z_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ nx, ny, nz });
                            const x_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ arc.x_axis[0], arc.x_axis[1], arc.x_axis[2] });
                            const axis2 = try s.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ center_id, z_axis_id, x_axis_id });
                            curve_entity_id = try s.emit("CIRCLE('',#{d},{d:.6})", .{ axis2, arc.radius });

                            // Check arc tangent direction vs v_min -> v_max chord
                            const radial = locus_math.sub(p1, arc.center);
                            const z_norm = locus_math.normalize(.{ nx, ny, nz });
                            const tangent = locus_math.cross(z_norm, radial);
                            const chord = locus_math.sub(p2, p1);
                            same_sense = locus_math.dot(tangent, chord) >= 0.0;
                        },
                        else => {
                            const dx = p2[0] - p1[0];
                            const dy = p2[1] - p1[1];
                            const dz = p2[2] - p1[2];
                            var len = @sqrt(dx * dx + dy * dy + dz * dz);
                            if (len < 1e-12) len = 1.0;

                            const dir_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ dx / len, dy / len, dz / len });
                            const vec_id = try s.emit("VECTOR('',#{d},1.0)", .{dir_id});
                            const origin_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ p1[0], p1[1], p1[2] });
                            curve_entity_id = try s.emit("LINE('',#{d},#{d})", .{ origin_id, vec_id });
                        },
                    }

                    const v_min_step = vertex_map.get(v_min) orelse return error.CorruptTopology;
                    const v_max_step = vertex_map.get(v_max) orelse return error.CorruptTopology;
                    const edge_curve_id = try s.emit("EDGE_CURVE('',#{d},#{d},#{d},.{s}.)", .{ v_min_step, v_max_step, curve_entity_id, if (same_sense) "T" else "F" });

                    try edge_map.put(key, edge_curve_id);
                }
            }
        }

        var loop_map = std.AutoHashMap(u32, u32).init(allocator);
        defer loop_map.deinit();

        for (t.loops.items, 0..) |loop, i| {
            if (!active_loops.contains(@intCast(i))) continue;

            var loop_oriented_edges = std.ArrayListUnmanaged(u32).empty;
            defer loop_oriented_edges.deinit(allocator);

            var curr_he_id = loop.first_half_edge;
            var safety_counter: u32 = 0;
            while (curr_he_id != topo.NULL_ID and curr_he_id < t.half_edges.items.len) {
                const he = t.half_edges.items[curr_he_id];
                if (he.next == topo.NULL_ID or he.next >= t.half_edges.items.len) return error.CorruptTopology;

                const next_he = t.half_edges.items[he.next];
                const v1_id = he.start_vertex;
                const v2_id = next_he.start_vertex;

                if (v1_id == v2_id and he.curve.curve_type == .circle_arc) {
                    const entry = full_circle_map.get(he.curve.index) orelse return error.CorruptTopology;
                    if (he.forward) {
                        const oe1 = try s.emit("ORIENTED_EDGE('',*,*,#{d},.T.)", .{entry.ec1});
                        const oe2 = try s.emit("ORIENTED_EDGE('',*,*,#{d},.T.)", .{entry.ec2});
                        try loop_oriented_edges.append(allocator, oe1);
                        try loop_oriented_edges.append(allocator, oe2);
                    } else {
                        const oe2 = try s.emit("ORIENTED_EDGE('',*,*,#{d},.F.)", .{entry.ec2});
                        const oe1 = try s.emit("ORIENTED_EDGE('',*,*,#{d},.F.)", .{entry.ec1});
                        try loop_oriented_edges.append(allocator, oe2);
                        try loop_oriented_edges.append(allocator, oe1);
                    }
                } else {
                    const v_min = @min(v1_id, v2_id);
                    const v_max = @max(v1_id, v2_id);
                    const key = EdgeKey{ .v1 = v_min, .v2 = v_max };
                    const ec_id = edge_map.get(key) orelse return error.CorruptTopology;

                    const is_forward = (v1_id == v_min);
                    const oe_id = try s.emit("ORIENTED_EDGE('',*,*,#{d},.{s}.)", .{
                        ec_id,
                        if (is_forward) "T" else "F",
                    });
                    try loop_oriented_edges.append(allocator, oe_id);
                }

                curr_he_id = he.next;
                safety_counter += 1;
                if (curr_he_id == loop.first_half_edge or safety_counter > 10000) break;
            }

            var header_buf: [64]u8 = undefined;
            const header_str = try std.fmt.bufPrint(&header_buf, "#{d}=EDGE_LOOP('',(", .{s.nextId()});
            try s.out.appendSlice(allocator, header_str);

            for (loop_oriented_edges.items, 0..) |oe, idx| {
                if (idx > 0) try s.out.appendSlice(allocator, ",");
                var oe_buf: [32]u8 = undefined;
                const oe_str = try std.fmt.bufPrint(&oe_buf, "#{d}", .{oe});
                try s.out.appendSlice(allocator, oe_str);
            }
            try s.out.appendSlice(allocator, "));\n");
            try loop_map.put(@intCast(i), s.id_counter);
        }

        var face_map = std.AutoHashMap(u32, std.ArrayListUnmanaged(u32)).init(allocator);
        defer {
            var it = face_map.valueIterator();
            while (it.next()) |list| list.deinit(allocator);
            face_map.deinit();
        }

        for (t.faces.items, 0..) |face, i| {
            if (!active_faces.contains(@intCast(i))) continue;

            var emitted_face_ids = std.ArrayListUnmanaged(u32).empty;

            // Check if planar face is a warped quad/polygon from hull()
            const outer_loop_id = t.face_loops.items[face.loops_start];
            const outer_loop = t.loops.items[outer_loop_id];

            var loop_verts = std.ArrayListUnmanaged(u32).empty;
            defer loop_verts.deinit(allocator);

            var curr_he = outer_loop.first_half_edge;
            var safety_counter: u32 = 0;
            while (curr_he != topo.NULL_ID and curr_he < t.half_edges.items.len) {
                const he = t.half_edges.items[curr_he];
                try loop_verts.append(allocator, he.start_vertex);
                curr_he = he.next;
                safety_counter += 1;
                if (curr_he == outer_loop.first_half_edge or safety_counter > 10000) break;
            }

            var is_warped = false;
            const loop_data = try computeLoopNormalAndOrigin(t, outer_loop);

            if (face.surface.surface_type == .plane and face.loops_len == 1 and loop_verts.items.len >= 4) {
                // Check max distance of vertices from Newell plane
                for (loop_verts.items) |v_id| {
                    const p = t.vertices.items[v_id].point;
                    const dist = @abs(locus_math.dot(locus_math.sub(p, loop_data.origin), loop_data.normal));
                    if (dist > 1e-4) {
                        is_warped = true;
                        break;
                    }
                }
            }

            if (is_warped) {
                // Split warped quad/polygon into planar 3-vertex triangles
                const v0_id = loop_verts.items[0];
                const p0 = t.vertices.items[v0_id].point;

                var j: usize = 1;
                while (j + 1 < loop_verts.items.len) : (j += 1) {
                    const vj_id = loop_verts.items[j];
                    const vj1_id = loop_verts.items[j + 1];

                    const pj = t.vertices.items[vj_id].point;
                    const pj1 = t.vertices.items[vj1_id].point;

                    // Triangle plane
                    const tri_normal = locus_math.normalize(locus_math.cross(locus_math.sub(pj, p0), locus_math.sub(pj1, p0)));
                    var tri_u: locus_math.Vec3 = undefined;
                    if (@abs(tri_normal[0]) < 0.9) {
                        tri_u = locus_math.normalize(locus_math.cross(.{ 1.0, 0.0, 0.0 }, tri_normal));
                    } else {
                        tri_u = locus_math.normalize(locus_math.cross(.{ 0.0, 1.0, 0.0 }, tri_normal));
                    }

                    const origin_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ p0[0], p0[1], p0[2] });
                    const z_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ tri_normal[0], tri_normal[1], tri_normal[2] });
                    const x_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ tri_u[0], tri_u[1], tri_u[2] });
                    const axis2 = try s.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ origin_id, z_axis_id, x_axis_id });
                    const tri_plane_id = try s.emit("PLANE('',#{d})", .{axis2});

                    // 3 Oriented Edges for Triangle (v0 -> vj -> vj1 -> v0)
                    const ec1 = try getOrCreateLineEdge(&s, t, &vertex_map, &edge_map, v0_id, vj_id);
                    const oe1 = try s.emit("ORIENTED_EDGE('',*,*,#{d},.{s}.)", .{ ec1, if (v0_id < vj_id) "T" else "F" });

                    const ec2 = try getOrCreateLineEdge(&s, t, &vertex_map, &edge_map, vj_id, vj1_id);
                    const oe2 = try s.emit("ORIENTED_EDGE('',*,*,#{d},.{s}.)", .{ ec2, if (vj_id < vj1_id) "T" else "F" });

                    const ec3 = try getOrCreateLineEdge(&s, t, &vertex_map, &edge_map, vj1_id, v0_id);
                    const oe3 = try s.emit("ORIENTED_EDGE('',*,*,#{d},.{s}.)", .{ ec3, if (vj1_id < v0_id) "T" else "F" });

                    const tri_loop_id = try s.emit("EDGE_LOOP('',(#{d},#{d},#{d}))", .{ oe1, oe2, oe3 });
                    const bound_id = try s.emit("FACE_OUTER_BOUND('',#{d},.T.)", .{tri_loop_id});
                    const tri_face_id = try s.emit("ADVANCED_FACE('',(#{d}),#{d},.T.)", .{ bound_id, tri_plane_id });

                    try emitted_face_ids.append(allocator, tri_face_id);
                }
            } else {
                var surface_record_id: u32 = 0;
                var face_orientation: []const u8 = "T";

                switch (face.surface.surface_type) {
                    .cylinder => {
                        // Quadrics use g_arena surface and face.forward orientation
                        face_orientation = if (face.forward) "T" else "F";
                        if (face.surface.index >= g.cylinders.items.len) return error.CorruptTopology;
                        const cyl = g.cylinders.items[face.surface.index];

                        var axis_dir = locus_math.normalize(cyl.axis);
                        if (locus_math.magSq(axis_dir) < 1e-12) axis_dir = .{ 0, 0, 1 };

                        var x_dir = locus_math.normalize(cyl.x_axis);
                        if (locus_math.magSq(x_dir) < 1e-12 or @abs(locus_math.dot(x_dir, axis_dir)) > 0.99) {
                            x_dir = if (@abs(axis_dir[0]) < 0.9)
                                locus_math.normalize(locus_math.cross(.{ 1, 0, 0 }, axis_dir))
                            else
                                locus_math.normalize(locus_math.cross(.{ 0, 1, 0 }, axis_dir));
                        } else {
                            x_dir = locus_math.normalize(locus_math.sub(x_dir, locus_math.scale(axis_dir, locus_math.dot(x_dir, axis_dir))));
                        }

                        const origin_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ cyl.origin[0], cyl.origin[1], cyl.origin[2] });
                        const z_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ axis_dir[0], axis_dir[1], axis_dir[2] });
                        const x_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ x_dir[0], x_dir[1], x_dir[2] });

                        const axis2 = try s.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ origin_id, z_axis_id, x_axis_id });
                        surface_record_id = try s.emit("CYLINDRICAL_SURFACE('',#{d},{d:.6})", .{ axis2, cyl.radius });
                    },
                    .sphere => {
                        face_orientation = if (face.forward) "T" else "F";
                        if (face.surface.index >= g.spheres.items.len) return error.CorruptTopology;
                        const sph = g.spheres.items[face.surface.index];

                        const origin_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ sph.center[0], sph.center[1], sph.center[2] });
                        const z_axis_id = try s.emit("DIRECTION('',(0.000000,0.000000,1.000000))", .{});
                        const x_axis_id = try s.emit("DIRECTION('',(1.000000,0.000000,0.000000))", .{});

                        const axis2 = try s.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ origin_id, z_axis_id, x_axis_id });
                        surface_record_id = try s.emit("SPHERICAL_SURFACE('',#{d},{d:.6})", .{ axis2, sph.radius });
                    },
                    .cone => {
                        face_orientation = if (face.forward) "T" else "F";
                        if (face.surface.index >= g.cones.items.len) return error.CorruptTopology;
                        const cone = g.cones.items[face.surface.index];

                        var axis_dir = locus_math.normalize(cone.axis);
                        if (locus_math.magSq(axis_dir) < 1e-12) axis_dir = .{ 0, 0, 1 };

                        var x_dir = locus_math.normalize(cone.x_axis);
                        if (locus_math.magSq(x_dir) < 1e-12 or @abs(locus_math.dot(x_dir, axis_dir)) > 0.99) {
                            x_dir = if (@abs(axis_dir[0]) < 0.9)
                                locus_math.normalize(locus_math.cross(.{ 1, 0, 0 }, axis_dir))
                            else
                                locus_math.normalize(locus_math.cross(.{ 0, 1, 0 }, axis_dir));
                        } else {
                            x_dir = locus_math.normalize(locus_math.sub(x_dir, locus_math.scale(axis_dir, locus_math.dot(x_dir, axis_dir))));
                        }

                        const origin_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ cone.origin[0], cone.origin[1], cone.origin[2] });
                        const z_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ axis_dir[0], axis_dir[1], axis_dir[2] });
                        const x_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ x_dir[0], x_dir[1], x_dir[2] });

                        const axis2 = try s.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ origin_id, z_axis_id, x_axis_id });
                        surface_record_id = try s.emit("CONICAL_SURFACE('',#{d},{d:.6},{d:.6})", .{ axis2, cone.radius, cone.half_angle });
                    },
                    .torus => {
                        face_orientation = if (face.forward) "T" else "F";
                        if (face.surface.index >= g.toruses.items.len) return error.CorruptTopology;
                        const tor = g.toruses.items[face.surface.index];

                        var axis_dir = locus_math.normalize(tor.axis);
                        if (locus_math.magSq(axis_dir) < 1e-12) axis_dir = .{ 0, 0, 1 };

                        var x_dir = locus_math.normalize(tor.x_axis);
                        if (locus_math.magSq(x_dir) < 1e-12 or @abs(locus_math.dot(x_dir, axis_dir)) > 0.99) {
                            x_dir = if (@abs(axis_dir[0]) < 0.9)
                                locus_math.normalize(locus_math.cross(.{ 1, 0, 0 }, axis_dir))
                            else
                                locus_math.normalize(locus_math.cross(.{ 0, 1, 0 }, axis_dir));
                        } else {
                            x_dir = locus_math.normalize(locus_math.sub(x_dir, locus_math.scale(axis_dir, locus_math.dot(x_dir, axis_dir))));
                        }

                        const origin_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ tor.center[0], tor.center[1], tor.center[2] });
                        const z_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ axis_dir[0], axis_dir[1], axis_dir[2] });
                        const x_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ x_dir[0], x_dir[1], x_dir[2] });

                        const axis2 = try s.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ origin_id, z_axis_id, x_axis_id });
                        surface_record_id = try s.emit("TOROIDAL_SURFACE('',#{d},{d:.6},{d:.6})", .{ axis2, tor.major_radius, tor.minor_radius });
                    },
                    else => {
                        // Planar faces calculate exact loop normal; orientation is ALWAYS "T"
                        face_orientation = "T";
                        const n_ax = loop_data.normal;
                        var u_ax: locus_math.Vec3 = undefined;
                        if (@abs(n_ax[0]) < 0.9) {
                            u_ax = locus_math.normalize(locus_math.cross(.{ 1.0, 0.0, 0.0 }, n_ax));
                        } else {
                            u_ax = locus_math.normalize(locus_math.cross(.{ 0.0, 1.0, 0.0 }, n_ax));
                        }

                        const origin_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ loop_data.origin[0], loop_data.origin[1], loop_data.origin[2] });
                        const z_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ n_ax[0], n_ax[1], n_ax[2] });
                        const x_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ u_ax[0], u_ax[1], u_ax[2] });

                        const axis2 = try s.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ origin_id, z_axis_id, x_axis_id });
                        surface_record_id = try s.emit("PLANE('',#{d})", .{axis2});
                    },
                }

                var bounds_str = std.ArrayListUnmanaged(u8).empty;
                defer bounds_str.deinit(allocator);

                for (0..face.loops_len) |l_off| {
                    const current_loop_id = t.face_loops.items[face.loops_start + l_off];
                    const bound_type = if (l_off == 0) "FACE_OUTER_BOUND" else "FACE_BOUND";
                    const step_loop_id = loop_map.get(current_loop_id) orelse return error.CorruptTopology;
                    const bound_id = try s.emit("{s}('',#{d},.T.)", .{ bound_type, step_loop_id });

                    if (l_off > 0) try bounds_str.appendSlice(allocator, ",");
                    var tmp: [32]u8 = undefined;
                    try bounds_str.appendSlice(allocator, try std.fmt.bufPrint(&tmp, "#{d}", .{bound_id}));
                }

                const single_face_id = try s.emit("ADVANCED_FACE('',({s}),#{d},.{s}.)", .{
                    bounds_str.items,
                    surface_record_id,
                    face_orientation,
                });
                try emitted_face_ids.append(allocator, single_face_id);
            }

            try face_map.put(@intCast(i), emitted_face_ids);
        }

        var shell_map = std.AutoHashMap(u32, u32).init(allocator);
        defer shell_map.deinit();

        for (t.shells.items, 0..) |shell, i| {
            if (!active_shells.contains(@intCast(i))) continue;

            var header_buf: [64]u8 = undefined;
            const header_str = try std.fmt.bufPrint(&header_buf, "#{d}=CLOSED_SHELL('',(", .{s.nextId()});
            try s.out.appendSlice(allocator, header_str);

            var written_count: usize = 0;
            for (0..shell.faces_len) |f_off| {
                const f_id = t.shell_faces.items[shell.faces_start + f_off];
                if (face_map.get(f_id)) |sub_face_list| {
                    for (sub_face_list.items) |step_face_id| {
                        if (written_count > 0) try s.out.appendSlice(allocator, ",");
                        var f_buf: [32]u8 = undefined;
                        const f_str = try std.fmt.bufPrint(&f_buf, "#{d}", .{step_face_id});
                        try s.out.appendSlice(allocator, f_str);
                        written_count += 1;
                    }
                }
            }
            try s.out.appendSlice(allocator, "));\n");
            try shell_map.put(@intCast(i), s.id_counter);
        }

        if (target_solid.shells_len > 0) {
            const primary_shell_id = t.solid_shells.items[target_solid.shells_start];
            const step_shell_id = shell_map.get(primary_shell_id) orelse return error.CorruptTopology;
            var buf: [128]u8 = undefined;
            const out_str = try std.fmt.bufPrint(&buf, "#{d}=MANIFOLD_SOLID_BREP('',#{d});\n", .{ step_solid_id, step_shell_id });
            try s.out.appendSlice(allocator, out_str);
        }
    }

    try s.out.appendSlice(allocator, "ENDSEC;\nEND-ISO-10303-21;\n");
    return try s.out.toOwnedSlice(allocator);
}

/// Method invocation variant (e.g. `my_part.export_step("out.step")`)
pub fn meshExportStep(vm: *VM, receiver: value.Value, filepath: []const u8) !value.Value {
    var export_handles = std.ArrayListUnmanaged(geom.GeometryHandle).empty;
    defer export_handles.deinit(vm.allocator);

    if (receiver.isAssembly()) {
        for (receiver.asAssembly().parts.items.items) |part_val| {
            if (part_val.isGeometry()) {
                const h = try vm.ensureConcrete(part_val);
                try export_handles.append(vm.allocator, h);
            }
        }
    } else {
        const h = try vm.ensureConcrete(receiver);
        try export_handles.append(vm.allocator, h);
    }

    const step_bytes = buildStepBuffer(vm.allocator, export_handles.items) catch |err| {
        vm.reportError("Export Error: Failed to generate STEP ({})\n", .{err});
        return error.RuntimeError;
    };
    defer vm.allocator.free(step_bytes);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(vm.io, .{ .sub_path = filepath, .data = step_bytes });

    return receiver;
}

/// Global function fallback variant (e.g. `export_step("out.step", my_part)`)
pub fn nativeExportStep(vm: *VM, path_str: []const u8, target: value.Value) !value.Value {
    return meshExportStep(vm, target, path_str);
}

/// Strongly typed global import (e.g. `import_step("in.step")`)
pub fn nativeImportStep(vm: *VM, path_str: []const u8) !value.Value {
    _ = path_str;
    vm.reportError("Runtime Error: import_step not yet supported for native B-Rep engine.\n", .{});
    return error.RuntimeError;
}
