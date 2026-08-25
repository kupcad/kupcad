const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const geom = @import("../../kernel/geometry_handle.zig");
const brep_driver = @import("../../kernel/engines/brep/driver.zig");

const StepSerializer = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8),
    id_counter: u32,

    fn init(allocator: std.mem.Allocator) StepSerializer {
        return .{
            .allocator = allocator,
            .out = .empty,
            .id_counter = 17, // Reserve 1-17 for Boilerplate + Solid ID
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

/// Generates a valid ISO 10303-21 STEP file buffer from the Native B-Rep Arrays
pub fn buildStepBuffer(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ![]const u8 {
    if (handle.engine != .brep_native) {
        return error.UnsupportedEngine;
    }

    const solid: *brep_driver.BrepSolid = @ptrCast(@alignCast(handle.ptr));
    const t = &solid.t_arena;

    var s = StepSerializer.init(allocator);
    errdefer s.out.deinit(allocator);

    const solid_id = 17; // Pre-allocated target for the MANIFOLD_SOLID_BREP

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

    // --- 2. MAP TOPOLOGY TO STEP RECORDS ---

    var vertex_map = try allocator.alloc(u32, t.vertices.items.len);
    defer allocator.free(vertex_map);

    for (t.vertices.items, 0..) |v, i| {
        const pt_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ v.point[0], v.point[1], v.point[2] });
        vertex_map[i] = try s.emit("VERTEX_POINT('',#{d})", .{pt_id});
    }

    var edge_map = try allocator.alloc(u32, t.edges.items.len);
    defer allocator.free(edge_map);

    for (t.edges.items, 0..) |edge, i| {
        const p1 = t.vertices.items[edge.front].point;
        const p2 = t.vertices.items[edge.back].point;

        const dx = p2[0] - p1[0];
        const dy = p2[1] - p1[1];
        const dz = p2[2] - p1[2];
        const len = @sqrt(dx * dx + dy * dy + dz * dz);

        const dir_id = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ dx / len, dy / len, dz / len });
        const vec_id = try s.emit("VECTOR('',#{d},{d:.6})", .{ dir_id, len });

        const origin_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ p1[0], p1[1], p1[2] });
        const line_id = try s.emit("LINE('',#{d},#{d})", .{ origin_id, vec_id });

        edge_map[i] = try s.emit("EDGE_CURVE('',#{d},#{d},#{d},.T.)", .{ vertex_map[edge.front], vertex_map[edge.back], line_id });
    }

    // Wires (Loops)
    var wire_map = try allocator.alloc(u32, t.wires.items.len);
    defer allocator.free(wire_map);

    for (t.wires.items, 0..) |wire, i| {
        var loop_edges = std.ArrayListUnmanaged(u32).empty;
        defer loop_edges.deinit(allocator);

        for (0..wire.edges_len) |we_off| {
            const d_edge = t.wire_edges.items[wire.edges_start + we_off];
            const oriented_id = try s.emit("ORIENTED_EDGE('',*,*,#{d},.{s}.)", .{ edge_map[d_edge.edge], if (d_edge.forward) "T" else "F" });
            try loop_edges.append(allocator, oriented_id);
        }

        var header_buf: [64]u8 = undefined;
        const header_str = try std.fmt.bufPrint(&header_buf, "#{d}=EDGE_LOOP('',(", .{s.nextId()});
        try s.out.appendSlice(allocator, header_str);

        for (loop_edges.items, 0..) |oe, idx| {
            if (idx > 0) try s.out.appendSlice(allocator, ",");
            var oe_buf: [32]u8 = undefined;
            const oe_str = try std.fmt.bufPrint(&oe_buf, "#{d}", .{oe});
            try s.out.appendSlice(allocator, oe_str);
        }
        try s.out.appendSlice(allocator, "));\n");
        wire_map[i] = s.id_counter;
    }

    // Faces
    var face_map = try allocator.alloc(u32, t.faces.items.len);
    defer allocator.free(face_map);

    for (t.faces.items, 0..) |face, i| {
        const wire_id = t.face_wires.items[face.wires_start];
        const wire = t.wires.items[wire_id];

        if (wire.edges_len < 2) continue; // Safety guard

        const d_e1 = t.wire_edges.items[wire.edges_start];
        const d_e2 = t.wire_edges.items[wire.edges_start + 1];

        const e1 = t.edges.items[d_e1.edge];
        const e2 = t.edges.items[d_e2.edge];

        const p0 = t.vertices.items[e1.front].point;
        const p1 = t.vertices.items[e1.back].point;
        const p2 = if (e1.back == e2.front) t.vertices.items[e2.back].point else t.vertices.items[e2.front].point;

        const dx1 = p1[0] - p0[0];
        const dy1 = p1[1] - p0[1];
        const dz1 = p1[2] - p0[2];
        const dx2 = p2[0] - p0[0];
        const dy2 = p2[1] - p0[1];
        const dz2 = p2[2] - p0[2];

        var nx = dy1 * dz2 - dz1 * dy2;
        var ny = dz1 * dx2 - dx1 * dz2;
        var nz = dx1 * dy2 - dy1 * dx2;
        const nlen = @sqrt(nx * nx + ny * ny + nz * nz);
        if (nlen > 0.0) {
            nx /= nlen;
            ny /= nlen;
            nz /= nlen;
        } else {
            nz = 1.0;
        }

        var xx = dx1;
        var xy = dy1;
        var xz = dz1;
        const xlen = @sqrt(xx * xx + xy * xy + xz * xz);
        if (xlen > 0.0) {
            xx /= xlen;
            xy /= xlen;
            xz /= xlen;
        } else {
            xx = 1.0;
        }

        const origin_id = try s.emit("CARTESIAN_POINT('',({d:.6},{d:.6},{d:.6}))", .{ p0[0], p0[1], p0[2] });
        const z_axis = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ nx, ny, nz });
        const x_axis = try s.emit("DIRECTION('',({d:.6},{d:.6},{d:.6}))", .{ xx, xy, xz });

        const axis2 = try s.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ origin_id, z_axis, x_axis });
        const plane_id = try s.emit("PLANE('',#{d})", .{axis2});

        // Generate Outer and Inner Bounds (Holes)
        var bounds_str = std.ArrayListUnmanaged(u8).empty;
        defer bounds_str.deinit(allocator);

        for (0..face.wires_len) |w_off| {
            const current_wire_id = t.face_wires.items[face.wires_start + w_off];

            // Wire 0 is always the Outer Bound. Wires 1..N are Inner Holes.
            const bound_type = if (w_off == 0) "FACE_OUTER_BOUND" else "FACE_BOUND";
            const bound_id = try s.emit("{s}('',#{d},.T.)", .{ bound_type, wire_map[current_wire_id] });

            if (w_off > 0) try bounds_str.appendSlice(allocator, ",");
            var tmp: [32]u8 = undefined;
            try bounds_str.appendSlice(allocator, try std.fmt.bufPrint(&tmp, "#{d}", .{bound_id}));
        }

        face_map[i] = try s.emit("ADVANCED_FACE('',({s}),#{d},.T.)", .{ bounds_str.items, plane_id });
    }

    // Shells
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

    // Solid (We manually write the reserved ID #17 so the boilerplate finds it)
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

// ... (keep nativeImportStep and nativeExportStep the same)
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
