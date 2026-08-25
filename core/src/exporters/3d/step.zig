const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const geom = @import("../../kernel/geometry_handle.zig");
const brep_driver = @import("../../kernel/engines/brep/driver.zig");
const topo = @import("../../locus/src/topology.zig");
const locus_geom = @import("../../locus/src/geometry.zig");

/// StepSerializer handles string formatting, sequential STEP entity ID generation,
/// and buffer management for ISO 10303-21 output.
const StepSerializer = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8),
    id_counter: u32,

    fn init(allocator: std.mem.Allocator) StepSerializer {
        return .{
            .allocator = allocator,
            .out = .empty,
            .id_counter = 17, // Reserve 1-17 for AP214 Header Boilerplate + Solid ID #17
        };
    }

    fn nextId(self: *StepSerializer) u32 {
        self.id_counter += 1;
        return self.id_counter;
    }

    /// Formats and emits a single STEP record line (e.g. `#18=CARTESIAN_POINT('',(...));\n`).
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

/// Generates a valid ISO 10303-21 STEP file buffer from Half-Edge B-Rep Topology.
pub fn buildStepBuffer(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ![]const u8 {
    if (handle.engine != .brep_native) {
        return error.UnsupportedEngine;
    }

    const solid: *brep_driver.BrepSolid = @ptrCast(@alignCast(handle.ptr));
    const t = &solid.t_arena;
    const g = &solid.g_arena;

    var s = StepSerializer.init(allocator);
    errdefer s.out.deinit(allocator);

    const solid_id = 17; // Target ID #17 for MANIFOLD_SOLID_BREP

    // --- 1. AP214 BOILERPLATE & HEADER ---
    try s.out.appendSlice(allocator,
        \\ISO-10303-21;
        \\HEADER;
        \\FILE_DESCRIPTION(('KupCAD Native B-Rep Export'),'2;1');
        \\FILE_NAME('kupcad_export.step','2026-08-25',('KupCAD'),(''),'','','');
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
        \\#10=ADVANCED_BREP_SHAPE_REPRESENTATION('',(#17),#12);
        \\#12=(GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#13)) GLOBAL_UNIT_ASSIGNED_CONTEXT((#14,#15,#16)) REPRESENTATION_CONTEXT('Context #1','3D Context with UNITS and UNCERTAINTY'));
        \\#13=UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-07),#14,'distance_accuracy_value','confusion accuracy');
        \\#14=(LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.));
        \\#15=(NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.));
        \\#16=(NAMED_UNIT(*) SI_UNIT($,.STERADIAN.) SOLID_ANGLE_UNIT());
        \\
    );

    // --- 2. VERTICES ---
    // Map internal VertexId to emitted STEP VERTEX_POINT record IDs
    var vertex_map = try allocator.alloc(u32, t.vertices.items.len);
    defer allocator.free(vertex_map);

    for (t.vertices.items, 0..) |v, i| {
        const pt_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ v.point[0], v.point[1], v.point[2] });
        vertex_map[i] = try s.emit("VERTEX_POINT('',#{d})", .{pt_id});
    }

    // --- 3. EDGE CURVES (HALF-EDGE PAIR DEDUPLICATION) ---
    // Map HalfEdgeId -> STEP EDGE_CURVE record ID and boolean orientation
    const EdgeCurveInfo = struct { edge_curve_id: u32, is_forward: bool };
    var half_edge_map = try allocator.alloc(EdgeCurveInfo, t.half_edges.items.len);
    defer allocator.free(half_edge_map);

    for (t.half_edges.items, 0..) |he, i| {
        const he_id: u32 = @intCast(i);

        // If this half-edge has a twin that was already emitted, reuse its EDGE_CURVE entity
        if (he.twin != topo.NULL_ID and he.twin < he_id) {
            const twin_info = half_edge_map[he.twin];
            half_edge_map[i] = .{
                .edge_curve_id = twin_info.edge_curve_id,
                .is_forward = false, // Reversed orientation relative to its twin
            };
            continue;
        }

        // Calculate end vertex by inspecting the starting vertex of the next half-edge in the loop
        const next_he = t.half_edges.items[he.next];
        const p1 = t.vertices.items[he.start_vertex].point;
        const p2 = t.vertices.items[next_he.start_vertex].point;

        const dx = p2[0] - p1[0];
        const dy = p2[1] - p1[1];
        const dz = p2[2] - p1[2];
        var len = @sqrt(dx * dx + dy * dy + dz * dz);
        if (len < 1e-12) len = 1.0;

        const dir_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ dx / len, dy / len, dz / len });
        const vec_id = try s.emit("VECTOR('',#{d},{d:.6})", .{ dir_id, len });

        const origin_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ p1[0], p1[1], p1[2] });
        const line_id = try s.emit("LINE('',#{d},#{d})", .{ origin_id, vec_id });

        const edge_curve_id = try s.emit("EDGE_CURVE('',#{d},#{d},#{d},.T.)", .{
            vertex_map[he.start_vertex],
            vertex_map[next_he.start_vertex],
            line_id,
        });

        half_edge_map[i] = .{
            .edge_curve_id = edge_curve_id,
            .is_forward = true,
        };
    }

    // --- 4. LOOPS (EDGE_LOOPs) ---
    // Traverse Half-Edge circular linked lists (following .next) to emit EDGE_LOOP entities
    var loop_map = try allocator.alloc(u32, t.loops.items.len);
    defer allocator.free(loop_map);

    for (t.loops.items, 0..) |loop, i| {
        var loop_oriented_edges = std.ArrayListUnmanaged(u32).empty;
        defer loop_oriented_edges.deinit(allocator);

        var curr_he_id = loop.first_half_edge;
        while (true) {
            const he_info = half_edge_map[curr_he_id];
            const oriented_id = try s.emit("ORIENTED_EDGE('',*,*,#{d},.{s}.)", .{
                he_info.edge_curve_id,
                if (he_info.is_forward) "T" else "F",
            });
            try loop_oriented_edges.append(allocator, oriented_id);

            const he = t.half_edges.items[curr_he_id];
            curr_he_id = he.next;
            if (curr_he_id == loop.first_half_edge) break;
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
        loop_map[i] = s.id_counter;
    }

    // --- 5. FACES & SURFACES ---
    var face_map = try allocator.alloc(u32, t.faces.items.len);
    defer allocator.free(face_map);

    for (t.faces.items, 0..) |face, i| {
        // Emit Surface Geometry
        var surface_record_id: u32 = 0;

        switch (face.surface.surface_type) {
            .plane => {
                const p = g.planes.items[face.surface.index];
                const nx = p.u_axis[1] * p.v_axis[2] - p.u_axis[2] * p.v_axis[1];
                const ny = p.u_axis[2] * p.v_axis[0] - p.u_axis[0] * p.v_axis[2];
                const nz = p.u_axis[0] * p.v_axis[1] - p.u_axis[1] * p.v_axis[0];

                const origin_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ p.origin[0], p.origin[1], p.origin[2] });
                const z_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ nx, ny, nz });
                const x_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ p.u_axis[0], p.u_axis[1], p.u_axis[2] });

                const axis2 = try s.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ origin_id, z_axis_id, x_axis_id });
                surface_record_id = try s.emit("PLANE('',#{d})", .{axis2});
            },
            .cylinder => {
                const cyl = g.cylinders.items[face.surface.index];
                const origin_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ cyl.origin[0], cyl.origin[1], cyl.origin[2] });
                const z_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ cyl.axis[0], cyl.axis[1], cyl.axis[2] });
                const x_axis_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ cyl.x_axis[0], cyl.x_axis[1], cyl.x_axis[2] });

                const axis2 = try s.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ origin_id, z_axis_id, x_axis_id });
                surface_record_id = try s.emit("CYLINDRICAL_SURFACE('',#{d},{d:.6})", .{ axis2, cyl.radius });
            },
            .sphere => {
                const sph = g.spheres.items[face.surface.index];
                const origin_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ sph.center[0], sph.center[1], sph.center[2] });
                const z_axis_id = try s.emit("DIRECTION('',(0.000000,0.000000,1.000000))", .{});
                const x_axis_id = try s.emit("DIRECTION('',(1.000000,0.000000,0.000000))", .{});

                const axis2 = try s.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ origin_id, z_axis_id, x_axis_id });
                surface_record_id = try s.emit("SPHERICAL_SURFACE('',#{d},{d:.6})", .{ axis2, sph.radius });
            },
            .nurbs => {
                const origin_id = try s.emit("CARTESIAN_POINT('',(0.000000,0.000000,0.000000))", .{});
                const z_axis_id = try s.emit("DIRECTION('',(0.000000,0.000000,1.000000))", .{});
                const x_axis_id = try s.emit("DIRECTION('',(1.000000,0.000000,0.000000))", .{});
                const axis2 = try s.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ origin_id, z_axis_id, x_axis_id });
                surface_record_id = try s.emit("PLANE('',#{d})", .{axis2});
            },
        }

        // Generate Outer Boundary (Loop 0) and Inner Bounds / Holes (Loops 1..N)
        var bounds_str = std.ArrayListUnmanaged(u8).empty;
        defer bounds_str.deinit(allocator);

        for (0..face.loops_len) |l_off| {
            const current_loop_id = t.face_loops.items[face.loops_start + l_off];

            const bound_type = if (l_off == 0) "FACE_OUTER_BOUND" else "FACE_BOUND";
            const bound_id = try s.emit("{s}('',#{d},.T.)", .{ bound_type, loop_map[current_loop_id] });

            if (l_off > 0) try bounds_str.appendSlice(allocator, ",");
            var tmp: [32]u8 = undefined;
            try bounds_str.appendSlice(allocator, try std.fmt.bufPrint(&tmp, "#{d}", .{bound_id}));
        }

        face_map[i] = try s.emit("ADVANCED_FACE('',({s}),#{d},.{s}.)", .{
            bounds_str.items,
            surface_record_id,
            if (face.forward) "T" else "F",
        });
    }

    // --- 6. SHELLS ---
    var shell_map = try allocator.alloc(u32, t.shells.items.len);
    defer allocator.free(shell_map);

    for (t.shells.items, 0..) |shell, i| {
        var header_buf: [64]u8 = undefined;
        const header_str = try std.fmt.bufPrint(&header_buf, "#{d}=CLOSED_SHELL('',(", .{s.nextId()});
        try s.out.appendSlice(allocator, header_str);

        for (0..shell.faces_len) |f_off| {
            if (f_off > 0) try s.out.appendSlice(allocator, ",");
            const f_id = t.shell_faces.items[shell.faces_start + f_off];

            var f_buf: [32]u8 = undefined;
            const f_str = try std.fmt.bufPrint(&f_buf, "#{d}", .{face_map[f_id]});
            try s.out.appendSlice(allocator, f_str);
        }
        try s.out.appendSlice(allocator, "));\n");
        shell_map[i] = s.id_counter;
    }

    // --- 7. SOLID (MANIFOLD_SOLID_BREP) ---
    // Emit target ID #17 referenced in the header boilerplate
    const active_solid_id = solid.solid_id;
    if (active_solid_id < t.solids.items.len) {
        const s_item = t.solids.items[active_solid_id];
        if (s_item.shells_len > 0) {
            const shell_id = t.solid_shells.items[s_item.shells_start];
            var buf: [128]u8 = undefined;
            const out_str = try std.fmt.bufPrint(&buf, "#{d}=MANIFOLD_SOLID_BREP('',#{d});\n", .{ solid_id, shell_map[shell_id] });
            try s.out.appendSlice(allocator, out_str);
        }
    }

    try s.out.appendSlice(allocator, "ENDSEC;\nEND-ISO-10303-21;\n");
    return try s.out.toOwnedSlice(allocator);
}

// --- VM API BRIDGES ---

pub fn nativeImportStep(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = arg_count;
    _ = args;
    vm.reportError("Runtime Error: import_step not yet supported for native B-Rep engine.\n", .{});
    return error.RuntimeError;
}

pub fn nativeExportStep(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count != 2 or !args[0].isString() or !args[1].isGeometry()) return error.RuntimeError;

    const filename = args[0].asString();
    const handle = try vm.ensureConcrete(args[1]);

    const step_bytes = buildStepBuffer(vm.allocator, handle) catch |err| {
        vm.reportError("Export Error: Failed to generate STEP ({})\n", .{err});
        return error.RuntimeError;
    };
    defer vm.allocator.free(step_bytes);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(vm.io, .{ .sub_path = filename.chars, .data = step_bytes });
    return value.Value.initNil();
}
