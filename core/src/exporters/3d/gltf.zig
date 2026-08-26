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
const GltfExtras = struct { kupcad_role: []const u8 };
const GltfMaterial = struct {
    pbrMetallicRoughness: Pbr,
    extensions: ?MaterialExt = null,
    alphaMode: []const u8,
    doubleSided: bool = true,
    extras: ?GltfExtras = null,
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
/// Now supports multiple handles (combining the main CSG body and all display_list ghosts).
pub fn buildGltfBuffer(allocator: std.mem.Allocator, vm: *VM, handles: []const geom.GeometryHandle) ![]const u8 {
    var vertex_buf: std.ArrayListUnmanaged(u8) = .empty;
    var index_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer vertex_buf.deinit(allocator);
    defer index_buf.deinit(allocator);

    var primitives: std.ArrayListUnmanaged(Primitive) = .empty;
    var accessors: std.ArrayListUnmanaged(Accessor) = .empty;
    defer primitives.deinit(allocator);
    defer accessors.deinit(allocator);

    var global_min = [3]f64{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) };
    var global_max = [3]f64{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    var total_vertices: u32 = 0;

    // --- Process All Meshes (Main + Ghosts) ---
    for (handles) |handle| {
        const mesh = kernel.getMesh(allocator, handle) orelse continue;
        defer allocator.free(mesh.vert_props);
        defer allocator.free(mesh.tri_verts);

        const vertex_count: u32 = @intCast(mesh.vert_props.len / mesh.num_prop);
        if (vertex_count == 0) continue;

        // Offset new vertices by the total vertices already processed across previous meshes
        const base_vertex = total_vertices;
        total_vertices += vertex_count;

        // Group Triangles by Material ID
        var mat_indices = std.AutoHashMap(u32, std.ArrayListUnmanaged(u32)).init(allocator);
        var i: usize = 0;
        while (i < mesh.tri_verts.len) : (i += 3) {
            const v_idx = mesh.tri_verts[i] * mesh.num_prop;
            const mat_id: u32 = if (mesh.num_prop >= 4) @intFromFloat(mesh.vert_props[v_idx + 3]) else 0;

            const gop = try mat_indices.getOrPut(mat_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;

            // Append the 3 vertex indices for this triangle, offset by the current base vertex
            try gop.value_ptr.appendSlice(allocator, &.{ mesh.tri_verts[i] + base_vertex, mesh.tri_verts[i + 1] + base_vertex, mesh.tri_verts[i + 2] + base_vertex });
        }

        // Push Raw Vertices and calculate global bounding box
        var v: usize = 0;
        while (v < mesh.vert_props.len) : (v += mesh.num_prop) {
            const x: f64 = @floatCast(mesh.vert_props[v + 0]);
            const y: f64 = @floatCast(mesh.vert_props[v + 1]);
            const z: f64 = @floatCast(mesh.vert_props[v + 2]);

            if (x < global_min[0]) global_min[0] = x;
            if (x > global_max[0]) global_max[0] = x;
            if (y < global_min[1]) global_min[1] = y;
            if (y > global_max[1]) global_max[1] = y;
            if (z < global_min[2]) global_min[2] = z;
            if (z > global_max[2]) global_max[2] = z;

            try vertex_buf.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v + 0]));
            try vertex_buf.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v + 1]));
            try vertex_buf.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v + 2]));
        }

        // Write Index Accessors and Primitives mapped to materials
        var mat_it = mat_indices.iterator();
        while (mat_it.next()) |entry| {
            const mat_id = entry.key_ptr.*;
            const indices = entry.value_ptr.items;
            const current_index_byte_offset: u32 = @intCast(index_buf.items.len);

            for (indices) |idx| {
                try index_buf.appendSlice(allocator, std.mem.asBytes(&idx));
            }

            const accessor_id: u32 = @as(u32, @intCast(accessors.items.len)) + 1; // +1 because Accessor 0 is reserved for POSITION
            try accessors.append(allocator, .{
                .bufferView = 1,
                .byteOffset = current_index_byte_offset,
                .componentType = 5125, // UNSIGNED_INT
                .count = @intCast(indices.len),
                .type = "SCALAR",
            });

            try primitives.append(allocator, .{
                .attributes = .{ .POSITION = 0 },
                .indices = accessor_id,
                .material = mat_id,
            });
            entry.value_ptr.deinit(allocator);
        }
        mat_indices.deinit();
    }

    if (total_vertices == 0) return error.NoGeometry;

    // --- Build Binary Data Chunk ---
    // Prepend the global POSITION accessor at index 0 now that we have the global min/max
    try accessors.insert(allocator, 0, .{
        .bufferView = 0,
        .byteOffset = 0,
        .componentType = 5126, // FLOAT
        .count = total_vertices,
        .type = "VEC3",
        .min = global_min,
        .max = global_max,
    });

    var bin_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer bin_buf.deinit(allocator);

    try bin_buf.appendSlice(allocator, vertex_buf.items);

    const pos_byte_length: u32 = @intCast(vertex_buf.items.len);
    const indices_start_offset: u32 = pos_byte_length;
    const indices_byte_length: u32 = @intCast(index_buf.items.len);

    try bin_buf.appendSlice(allocator, index_buf.items);

    // --- Extract VM Materials & Setup Semantic Roles ---
    var gltf_materials: std.ArrayListUnmanaged(GltfMaterial) = .empty;
    var extensionsUsed: std.ArrayListUnmanaged([]const u8) = .empty;
    defer gltf_materials.deinit(allocator);
    defer extensionsUsed.deinit(allocator);

    var has_transmission = false;

    if (vm.materials.items.len == 0) {
        // Fallback standard material if none provided
        try gltf_materials.append(allocator, .{
            .pbrMetallicRoughness = .{ .baseColorFactor = .{ 0.8, 0.8, 0.8, 1.0 }, .metallicFactor = 0.0, .roughnessFactor = 0.5 },
            .alphaMode = "OPAQUE",
        });
    } else {
        for (vm.materials.items) |mat| {
            const color = parseHexColor(mat.color_hex, mat.alpha);
            var ext: ?MaterialExt = null;
            var alphaMode: []const u8 = if (mat.alpha < 1.0) "BLEND" else "OPAQUE";

            // Semantic Tagging for the Frontend Viewer
            var extras: ?GltfExtras = null;

            if (mat.role == .ghost) {
                // Ensure GLTF viewers know to blend it even if they ignore `extras`
                alphaMode = "BLEND";
                extras = .{ .kupcad_role = "ghost" };
            } else if (mat.role == .highlight) {
                extras = .{ .kupcad_role = "highlight" };
            }

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
                .extras = extras, // Inject semantics
            });
        }
    }

    if (has_transmission) {
        try extensionsUsed.append(allocator, "KHR_materials_transmission");
        try extensionsUsed.append(allocator, "KHR_materials_ior");
    }

    // --- Serialize JSON Hierarchy ---
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

    // GLB chunks must be aligned to 4-byte boundaries
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

    if (arg_count < 2 or !args[0].isString()) {
        vm.reportError("ArgumentError: export_gltf expects (String path, target).\n", .{});
        return error.RuntimeError;
    }

    const path = args[0].asString().chars;
    const target = args[1];

    // --- Dynamically extract geometries from either a direct handle, an Assembly, or an Array ---
    var handles = std.ArrayListUnmanaged(geom.GeometryHandle).empty;
    defer handles.deinit(vm.allocator);

    if (target.isGeometry()) {
        try handles.append(vm.allocator, try vm.ensureConcrete(target));
    } else if (target.isAssembly()) {
        for (target.asAssembly().parts.items.items) |part| {
            if (part.isGeometry()) try handles.append(vm.allocator, try vm.ensureConcrete(part));
        }
    } else if (target.isArray()) {
        for (target.asArray().items.items) |part| {
            if (part.isGeometry()) try handles.append(vm.allocator, try vm.ensureConcrete(part));
        }
    } else {
        vm.reportError("TypeError: export_gltf expects a Geometry, Assembly, or Array.\n", .{});
        return error.RuntimeError;
    }

    const glb_bytes = try buildGltfBuffer(vm.allocator, vm, handles.items);
    defer vm.allocator.free(glb_bytes);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(vm.io, .{
        .sub_path = path,
        .data = glb_bytes,
    });

    return value.Value.initNil();
}
