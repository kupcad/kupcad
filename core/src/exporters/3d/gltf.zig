const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../kernel/geometry_handle.zig");

// --- GLTF Struct Definitions for std.json ---
const Pbr = struct {
    baseColorFactor: [4]f64,
    metallicFactor: f64,
    roughnessFactor: f64,
};
const TransmissionExt = struct { transmissionFactor: f64 };
const IorExt = struct { ior: f64 };
const MaterialExt = struct {
    KHR_materials_transmission: ?TransmissionExt = null,
    KHR_materials_ior: ?IorExt = null,
};
const GltfMaterial = struct {
    pbrMetallicRoughness: Pbr,
    extensions: ?MaterialExt = null,
    alphaMode: []const u8,
    doubleSided: bool = true,
};
const Primitive = struct {
    attributes: struct { POSITION: u32 },
    indices: u32,
    material: u32,
};
const Accessor = struct {
    bufferView: u32,
    byteOffset: u32,
    componentType: u32,
    count: u32,
    type: []const u8,
    min: ?[3]f64 = null,
    max: ?[3]f64 = null,
};
const BufferView = struct {
    buffer: u32,
    byteOffset: u32,
    byteLength: u32,
    target: u32,
};

fn parseHexColor(hex: []const u8, alpha: f64) [4]f64 {
    var r: f64 = 1.0;
    var g: f64 = 1.0;
    var b: f64 = 1.0;
    const clean_hex = if (std.mem.startsWith(u8, hex, "#")) hex[1..] else hex;
    if (clean_hex.len >= 6) {
        if (std.fmt.parseInt(u32, clean_hex[0..6], 16)) |val| {
            const sR = @as(f64, @floatFromInt((val >> 16) & 0xFF)) / 255.0;
            const sG = @as(f64, @floatFromInt((val >> 8) & 0xFF)) / 255.0;
            const sB = @as(f64, @floatFromInt(val & 0xFF)) / 255.0;
            r = std.math.pow(f64, sR, 2.2);
            g = std.math.pow(f64, sG, 2.2);
            b = std.math.pow(f64, sB, 2.2);
        } else |_| {}
    }
    return .{ r, g, b, alpha };
}

/// Constructs and returns an owned slice of binary .GLB bytes directly in memory.
pub fn buildGltfBuffer(allocator: std.mem.Allocator, vm: *VM, handle: geom.GeometryHandle) ![]const u8 {
    const mesh = kernel.getMesh(allocator, handle) orelse return error.MeshExtractionFailed;
    defer allocator.free(mesh.vert_props);
    defer allocator.free(mesh.tri_verts);

    // --- 1. Group Triangles by Material ID ---
    var mat_indices = std.AutoHashMap(u32, std.ArrayListUnmanaged(u32)).init(allocator);
    defer {
        var it = mat_indices.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        mat_indices.deinit();
    }

    var i: usize = 0;
    while (i < mesh.tri_verts.len) : (i += 3) {
        const v_idx = mesh.tri_verts[i] * mesh.num_prop;
        const mat_id: u32 = if (mesh.num_prop >= 4) @intFromFloat(mesh.vert_props[v_idx + 3]) else 0;

        const gop = try mat_indices.getOrPut(mat_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.appendSlice(allocator, &.{ mesh.tri_verts[i], mesh.tri_verts[i + 1], mesh.tri_verts[i + 2] });
    }

    // --- 2. Build Binary Data Chunk ---
    var bin_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer bin_buf.deinit(allocator);

    var min_pos = [3]f64{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var max_pos = [3]f64{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    const vertex_count: u32 = @intCast(mesh.vert_props.len / mesh.num_prop);

    var v: usize = 0;
    while (v < mesh.vert_props.len) : (v += mesh.num_prop) {
        const x: f64 = @floatCast(mesh.vert_props[v + 0]);
        const y: f64 = @floatCast(mesh.vert_props[v + 1]);
        const z: f64 = @floatCast(mesh.vert_props[v + 2]);

        try bin_buf.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v + 0]));
        try bin_buf.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v + 1]));
        try bin_buf.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v + 2]));

        if (x < min_pos[0]) min_pos[0] = x;
        if (x > max_pos[0]) max_pos[0] = x;
        if (y < min_pos[1]) min_pos[1] = y;
        if (y > max_pos[1]) max_pos[1] = y;
        if (z < min_pos[2]) min_pos[2] = z;
        if (z > max_pos[2]) max_pos[2] = z;
    }
    const pos_byte_length: u32 = vertex_count * 12;

    var primitives: std.ArrayListUnmanaged(Primitive) = .empty;
    var accessors: std.ArrayListUnmanaged(Accessor) = .empty;
    defer primitives.deinit(allocator);
    defer accessors.deinit(allocator);

    try accessors.append(allocator, .{
        .bufferView = 0,
        .byteOffset = 0,
        .componentType = 5126, // FLOAT
        .count = vertex_count,
        .type = "VEC3",
        .min = min_pos,
        .max = max_pos,
    });

    const indices_start_offset: u32 = @intCast(bin_buf.items.len);
    var current_index_offset: u32 = 0;

    var mat_it = mat_indices.iterator();
    while (mat_it.next()) |entry| {
        const mat_id = entry.key_ptr.*;
        const indices = entry.value_ptr.items;

        for (indices) |idx| {
            try bin_buf.appendSlice(allocator, std.mem.asBytes(&idx));
        }

        const accessor_id: u32 = @intCast(accessors.items.len);
        try accessors.append(allocator, .{
            .bufferView = 1,
            .byteOffset = current_index_offset,
            .componentType = 5125, // UNSIGNED_INT
            .count = @intCast(indices.len),
            .type = "SCALAR",
        });

        try primitives.append(allocator, .{
            .attributes = .{ .POSITION = 0 },
            .indices = accessor_id,
            .material = mat_id,
        });
        current_index_offset += @intCast(indices.len * 4);
    }
    const indices_byte_length = current_index_offset;

    // --- 3. Extract VM Materials & Extensions ---
    var gltf_materials: std.ArrayListUnmanaged(GltfMaterial) = .empty;
    var extensionsUsed: std.ArrayListUnmanaged([]const u8) = .empty;
    defer gltf_materials.deinit(allocator);
    defer extensionsUsed.deinit(allocator);

    var has_transmission = false;

    if (vm.materials.items.len == 0) {
        try gltf_materials.append(allocator, .{
            .pbrMetallicRoughness = .{ .baseColorFactor = .{ 0.8, 0.8, 0.8, 1.0 }, .metallicFactor = 0.0, .roughnessFactor = 0.5 },
            .alphaMode = "OPAQUE",
        });
    } else {
        for (vm.materials.items) |mat| {
            const color = parseHexColor(mat.color_hex, mat.alpha);
            var ext: ?MaterialExt = null;
            var alphaMode: []const u8 = if (mat.alpha < 1.0) "BLEND" else "OPAQUE";

            if (mat.transmission > 0.0) {
                ext = .{
                    .KHR_materials_transmission = .{ .transmissionFactor = mat.transmission },
                    .KHR_materials_ior = .{ .ior = 1.5 },
                };
                alphaMode = "OPAQUE";
                has_transmission = true;
            }
            try gltf_materials.append(allocator, .{
                .pbrMetallicRoughness = .{ .baseColorFactor = color, .metallicFactor = mat.metallic, .roughnessFactor = mat.roughness },
                .extensions = ext,
                .alphaMode = alphaMode,
            });
        }
    }

    if (has_transmission) {
        try extensionsUsed.append(allocator, "KHR_materials_transmission");
        try extensionsUsed.append(allocator, "KHR_materials_ior");
    }

    // --- 4. Serialize JSON Hierarchy ---
    var bufferViews = [_]BufferView{
        .{ .buffer = 0, .byteOffset = 0, .byteLength = pos_byte_length, .target = 34962 },
        .{ .buffer = 0, .byteOffset = indices_start_offset, .byteLength = indices_byte_length, .target = 34963 },
    };

    const root_obj = .{
        .asset = .{ .version = "2.0", .generator = "KupCAD" },
        .extensionsUsed = if (extensionsUsed.items.len > 0) extensionsUsed.items else null,
        .scene = 0,
        .scenes = [_]struct { nodes: [1]u32 }{.{ .nodes = .{0} }},
        .nodes = [_]struct { mesh: u32, rotation: [4]f64 }{.{ .mesh = 0, .rotation = .{ -0.7071067811865475, 0.0, 0.0, 0.7071067811865476 } }},
        .meshes = [_]struct { primitives: []Primitive }{.{ .primitives = primitives.items }},
        .materials = gltf_materials.items,
        .accessors = accessors.items,
        .bufferViews = &bufferViews,
        .buffers = [_]struct { byteLength: usize }{.{ .byteLength = bin_buf.items.len }},
    };

    var json_writer = std.Io.Writer.Allocating.init(allocator);
    defer json_writer.deinit();
    try json_writer.writer.print("{f}", .{std.json.fmt(root_obj, .{ .emit_null_optional_fields = false })});

    var json_out: std.ArrayListUnmanaged(u8) = .empty;
    defer json_out.deinit(allocator);
    try json_out.appendSlice(allocator, json_writer.written());

    while (json_out.items.len % 4 != 0) try json_out.append(allocator, ' ');
    while (bin_buf.items.len % 4 != 0) try bin_buf.append(allocator, 0);

    const bin_len: u32 = @intCast(bin_buf.items.len);
    const json_len: u32 = @intCast(json_out.items.len);
    const total_length: u32 = 12 + 8 + json_len + 8 + bin_len;

    // --- 5. Assemble GLB Payload ---
    var glb_payload: std.ArrayListUnmanaged(u8) = .empty;
    errdefer glb_payload.deinit(allocator);

    const magic: u32 = 0x46546C67; // "glTF"
    const version: u32 = 2;
    const json_chunk_type: u32 = 0x4E4F534A; // "JSON"
    const bin_chunk_type: u32 = 0x004E4942; // "BIN\0"

    try glb_payload.appendSlice(allocator, std.mem.asBytes(&magic));
    try glb_payload.appendSlice(allocator, std.mem.asBytes(&version));
    try glb_payload.appendSlice(allocator, std.mem.asBytes(&total_length));

    try glb_payload.appendSlice(allocator, std.mem.asBytes(&json_len));
    try glb_payload.appendSlice(allocator, std.mem.asBytes(&json_chunk_type));
    try glb_payload.appendSlice(allocator, json_out.items);

    try glb_payload.appendSlice(allocator, std.mem.asBytes(&bin_len));
    try glb_payload.appendSlice(allocator, std.mem.asBytes(&bin_chunk_type));
    try glb_payload.appendSlice(allocator, bin_buf.items);

    return try glb_payload.toOwnedSlice(allocator);
}

pub fn nativeExportGltf(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (arg_count < 2 or !args[0].isString() or !args[1].isGeometry()) {
        vm.reportError("ArgumentError: export_gltf expects (String path, Geometry geom).\n", .{});
        return error.RuntimeError;
    }

    const path = args[0].asString().chars;
    const handle = try vm.ensureConcrete(args[1]);

    const glb_bytes = try buildGltfBuffer(vm.allocator, vm, handle);
    defer vm.allocator.free(glb_bytes);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(vm.io, .{
        .sub_path = path,
        .data = glb_bytes,
    });

    return value.Value.initNil();
}
