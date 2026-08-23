const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../kernel/geometry_handle.zig");

pub const StlMesh = struct {
    points: [][3]f64,
    faces: [][3]u32,

    pub fn deinit(self: *StlMesh, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.faces);
    }
};

const PointKey = struct {
    x: u32,
    y: u32,
    z: u32,
};

/// Parses raw STL bytes (Binary or ASCII) into vertex points and triangle face indices.
pub fn parseStlBuffer(allocator: std.mem.Allocator, data: []const u8) !StlMesh {
    // Binary STL check: Header is 80 bytes + 4 bytes count
    if (data.len >= 84) {
        const num_tris = std.mem.readInt(u32, data[80..84], .little);
        const expected_len = 84 + @as(usize, num_tris) * 50;
        if (data.len >= expected_len and expected_len > 84) {
            return parseBinaryStl(allocator, data, num_tris);
        }
    }
    // Fallback to ASCII STL parser
    return parseAsciiStl(allocator, data);
}

fn parseBinaryStl(allocator: std.mem.Allocator, data: []const u8, num_tris: u32) !StlMesh {
    var points = std.ArrayListUnmanaged([3]f64).empty;
    defer points.deinit(allocator);
    var faces = try allocator.alloc([3]u32, num_tris);
    errdefer allocator.free(faces);

    var point_map = std.AutoHashMap(PointKey, u32).init(allocator);
    defer point_map.deinit();

    var offset: usize = 84;
    for (0..num_tris) |i| {
        offset += 12; // Skip Normal vector (3x f32)

        var tri_indices: [3]u32 = undefined;
        for (0..3) |v| {
            const ix = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;
            const iy = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;
            const iz = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;

            const vx: f32 = @bitCast(ix);
            const vy: f32 = @bitCast(iy);
            const vz: f32 = @bitCast(iz);

            const key = PointKey{ .x = ix, .y = iy, .z = iz };
            const gop = try point_map.getOrPut(key);
            if (!gop.found_existing) {
                const new_idx: u32 = @intCast(points.items.len);
                try points.append(allocator, .{ @floatCast(vx), @floatCast(vy), @floatCast(vz) });
                gop.value_ptr.* = new_idx;
            }
            tri_indices[v] = gop.value_ptr.*;
        }
        offset += 2; // Skip attribute byte count

        faces[i] = tri_indices;
    }

    return StlMesh{
        .points = try points.toOwnedSlice(allocator),
        .faces = faces,
    };
}

fn parseAsciiStl(allocator: std.mem.Allocator, data: []const u8) !StlMesh {
    var points = std.ArrayListUnmanaged([3]f64).empty;
    defer points.deinit(allocator);
    var faces = std.ArrayListUnmanaged([3]u32).empty;
    defer faces.deinit(allocator);

    var point_map = std.AutoHashMap(PointKey, u32).init(allocator);
    defer point_map.deinit();

    var lines = std.mem.tokenizeAny(u8, data, "\r\n");
    var current_tri_indices: [3]u32 = undefined;
    var current_tri_verts: usize = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "vertex")) {
            var tokens = std.mem.tokenizeAny(u8, trimmed[6..], " \t");
            const x_str = tokens.next() orelse continue;
            const y_str = tokens.next() orelse continue;
            const z_str = tokens.next() orelse continue;

            const x = std.fmt.parseFloat(f32, x_str) catch continue;
            const y = std.fmt.parseFloat(f32, y_str) catch continue;
            const z = std.fmt.parseFloat(f32, z_str) catch continue;

            const key = PointKey{ .x = @bitCast(x), .y = @bitCast(y), .z = @bitCast(z) };
            const gop = try point_map.getOrPut(key);
            if (!gop.found_existing) {
                const new_idx: u32 = @intCast(points.items.len);
                try points.append(allocator, .{ @floatCast(x), @floatCast(y), @floatCast(z) });
                gop.value_ptr.* = new_idx;
            }

            current_tri_indices[current_tri_verts] = gop.value_ptr.*;
            current_tri_verts += 1;

            if (current_tri_verts == 3) {
                try faces.append(allocator, current_tri_indices);
                current_tri_verts = 0;
            }
        }
    }

    if (faces.items.len == 0) return error.InvalidStl;

    return StlMesh{
        .points = try points.toOwnedSlice(allocator),
        .faces = try faces.toOwnedSlice(allocator),
    };
}

/// Generates an STL binary buffer in memory.
pub fn buildStlBuffer(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ![]const u8 {
    const mesh = kernel.getMesh(allocator, handle) orelse return error.MeshExtractionFailed;
    defer allocator.free(mesh.vert_props);
    defer allocator.free(mesh.tri_verts);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    // STL Header (80 bytes)
    try out.appendNTimes(allocator, 0, 80);
    // Triangle Count (4 bytes)
    const tri_count: u32 = @intCast(mesh.tri_verts.len / 3);
    try out.appendSlice(allocator, std.mem.asBytes(&tri_count));

    var i: usize = 0;
    while (i < mesh.tri_verts.len) : (i += 3) {
        // Normal vector (dummy 0.0, 0.0, 0.0)
        const zero: f32 = 0.0;
        try out.appendSlice(allocator, std.mem.asBytes(&zero));
        try out.appendSlice(allocator, std.mem.asBytes(&zero));
        try out.appendSlice(allocator, std.mem.asBytes(&zero));

        // 3 Vertices (x, y, z floats)
        for (0..3) |v| {
            const idx = mesh.tri_verts[i + v];
            const v_idx = idx * mesh.num_prop;
            try out.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v_idx]));
            try out.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v_idx + 1]));
            try out.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v_idx + 2]));
        }

        // Attribute byte count (2 bytes)
        const attr_count: u16 = 0;
        try out.appendSlice(allocator, std.mem.asBytes(&attr_count));
    }

    return try out.toOwnedSlice(allocator);
}

pub fn nativeExportStl(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (arg_count != 2) return error.RuntimeError;
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (!args[0].isString()) return error.RuntimeError;
    if (!args[1].isGeometry()) return error.RuntimeError;

    const path_str = args[0].asString().chars;
    const handle = try vm.ensureConcrete(args[1]);

    const stl_bytes = try buildStlBuffer(vm.allocator, handle);
    defer vm.allocator.free(stl_bytes);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(vm.io, .{
        .sub_path = path_str,
        .data = stl_bytes,
    });

    return value.Value.initNil();
}

pub fn nativeImportStl(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (arg_count < 1 or !args[0].isString()) {
        vm.reportError("ArgumentError: import_stl expects (String path).\n", .{});
        return error.RuntimeError;
    }

    const path_str = args[0].asString().chars;
    const cwd = std.Io.Dir.cwd();

    const file = cwd.openFile(vm.io, path_str, .{}) catch |err| {
        vm.reportError("IOError: Failed to open STL file '{s}': {}\n", .{ path_str, err });
        return error.RuntimeError;
    };
    defer file.close(vm.io);

    const stat = file.stat(vm.io) catch |err| {
        vm.reportError("IOError: Failed to stat STL file '{s}': {}\n", .{ path_str, err });
        return error.RuntimeError;
    };

    const file_size: usize = std.math.cast(usize, stat.size) orelse {
        vm.reportError("IOError: STL file '{s}' is too large for 32-bit address space.\n", .{path_str});
        return error.OutOfMemory;
    };

    const file_buf = vm.allocator.alloc(u8, file_size) catch return error.OutOfMemory;
    defer vm.allocator.free(file_buf);

    const bytes_read = file.readStreaming(vm.io, &.{file_buf}) catch |err| {
        vm.reportError("IOError: Failed to read STL file '{s}': {}\n", .{ path_str, err });
        return error.RuntimeError;
    };
    if (bytes_read != file_size) return error.RuntimeError;

    var stl_mesh = parseStlBuffer(vm.allocator, file_buf) catch |err| {
        vm.reportError("ParseError: Failed to parse STL file '{s}': {}\n", .{ path_str, err });
        return error.RuntimeError;
    };
    defer stl_mesh.deinit(vm.allocator);

    const dag_idx = try vm.dag_builder.addPolyhedron(stl_mesh.points, stl_mesh.faces);
    return try vm.allocateGeometry(.{ .symbolic = dag_idx });
}
