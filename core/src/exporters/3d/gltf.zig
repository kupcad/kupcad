const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../kernel/geometry_handle.zig");
const draco = @import("../../bindings/draco.zig");

// --- GLTF & Draco Configuration Constants ---
const GLTF_COMPONENT_TYPE_FLOAT = 5126;
const GLTF_COMPONENT_TYPE_UNSIGNED_INT = 5125;
const GLTF_TARGET_ARRAY_BUFFER = 34962;
const GLTF_TARGET_ELEMENT_ARRAY_BUFFER = 34963;
const DRACO_POSITION_QUANTIZATION_BITS = 14;

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

const DracoExtension = struct {
    bufferView: u32,
    attributes: struct { POSITION: u32 = 0 },
};
const PrimitiveExtensions = struct {
    KHR_draco_mesh_compression: DracoExtension,
};

const Primitive = struct {
    attributes: struct { POSITION: u32 },
    indices: u32,
    material: u32,
    extensions: ?PrimitiveExtensions = null,
};
const Accessor = struct {
    bufferView: ?u32 = null,
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
    target: ?u32 = null,
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
/// Supports optional Draco geometry compression via `use_draco`.
pub fn buildGltfBuffer(
    allocator: std.mem.Allocator,
    vm: *VM,
    handles: []const geom.GeometryHandle,
    use_draco: bool,
) ![]const u8 {
    var vertex_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer vertex_buf.deinit(allocator);

    var primitives_data: std.ArrayListUnmanaged(struct {
        material: u32,
        indices: std.ArrayListUnmanaged(u32),
    }) = .empty;
    defer {
        for (primitives_data.items) |*p| p.indices.deinit(allocator);
        primitives_data.deinit(allocator);
    }

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

        const base_vertex = total_vertices;
        total_vertices += vertex_count;

        // Group Triangles by Material ID
        var mat_indices = std.AutoHashMap(u32, std.ArrayListUnmanaged(u32)).init(allocator);
        defer mat_indices.deinit();

        var i: usize = 0;
        while (i < mesh.tri_verts.len) : (i += 3) {
            const v_idx = mesh.tri_verts[i] * mesh.num_prop;
            const mat_id: u32 = if (mesh.num_prop >= 4) @intFromFloat(mesh.vert_props[v_idx + 3]) else 0;

            const gop = try mat_indices.getOrPut(mat_id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;

            try gop.value_ptr.appendSlice(allocator, &.{
                mesh.tri_verts[i] + base_vertex,
                mesh.tri_verts[i + 1] + base_vertex,
                mesh.tri_verts[i + 2] + base_vertex,
            });
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

        var mat_it = mat_indices.iterator();
        while (mat_it.next()) |entry| {
            try primitives_data.append(allocator, .{
                .material = entry.key_ptr.*,
                .indices = entry.value_ptr.*,
            });
        }
    }

    if (total_vertices == 0) return error.NoGeometry;

    var primitives: std.ArrayListUnmanaged(Primitive) = .empty;
    var accessors: std.ArrayListUnmanaged(Accessor) = .empty;
    var bufferViews: std.ArrayListUnmanaged(BufferView) = .empty;
    var bin_buf: std.ArrayListUnmanaged(u8) = .empty;

    defer primitives.deinit(allocator);
    defer accessors.deinit(allocator);
    defer bufferViews.deinit(allocator);
    defer bin_buf.deinit(allocator);

    var extensionsUsed: std.ArrayListUnmanaged([]const u8) = .empty;
    var extensionsRequired: std.ArrayListUnmanaged([]const u8) = .empty;
    defer extensionsUsed.deinit(allocator);
    defer extensionsRequired.deinit(allocator);

    // Position Accessor (Index 0)
    try accessors.append(allocator, .{
        .bufferView = if (use_draco) null else 0,
        .byteOffset = 0,
        .componentType = GLTF_COMPONENT_TYPE_FLOAT,
        .count = total_vertices,
        .type = "VEC3",
        .min = global_min,
        .max = global_max,
    });

    if (use_draco) {
        try extensionsUsed.append(allocator, "KHR_draco_mesh_compression");
        try extensionsRequired.append(allocator, "KHR_draco_mesh_compression");

        const raw_positions = @as([*]const f32, @ptrCast(@alignCast(vertex_buf.items.ptr)))[0 .. vertex_buf.items.len / 4];

        for (primitives_data.items) |prim| {
            const draco_bytes = try draco.encodeMesh(allocator, raw_positions, prim.indices.items, DRACO_POSITION_QUANTIZATION_BITS);
            defer allocator.free(draco_bytes);

            const draco_offset: u32 = @intCast(bin_buf.items.len);
            try bin_buf.appendSlice(allocator, draco_bytes);

            while (bin_buf.items.len % 4 != 0) try bin_buf.append(allocator, 0);

            const draco_bv_idx: u32 = @intCast(bufferViews.items.len);
            try bufferViews.append(allocator, .{
                .buffer = 0,
                .byteOffset = draco_offset,
                .byteLength = @intCast(draco_bytes.len),
            });

            const accessor_id: u32 = @intCast(accessors.items.len);
            try accessors.append(allocator, .{
                .bufferView = null,
                .byteOffset = 0,
                .componentType = GLTF_COMPONENT_TYPE_UNSIGNED_INT,
                .count = @intCast(prim.indices.items.len),
                .type = "SCALAR",
            });

            try primitives.append(allocator, .{
                .attributes = .{ .POSITION = 0 },
                .indices = accessor_id,
                .material = prim.material,
                .extensions = .{
                    .KHR_draco_mesh_compression = .{
                        .bufferView = draco_bv_idx,
                        .attributes = .{ .POSITION = 0 },
                    },
                },
            });
        }
    } else {
        // --- Uncompressed GLTF Buffer Layout ---
        try bin_buf.appendSlice(allocator, vertex_buf.items);

        const pos_byte_length: u32 = @intCast(vertex_buf.items.len);
        const indices_start_offset: u32 = pos_byte_length;

        var index_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer index_buf.deinit(allocator);

        for (primitives_data.items) |prim| {
            const current_index_byte_offset: u32 = @intCast(index_buf.items.len);

            for (prim.indices.items) |idx| {
                try index_buf.appendSlice(allocator, std.mem.asBytes(&idx));
            }

            const accessor_id: u32 = @intCast(accessors.items.len);
            try accessors.append(allocator, .{
                .bufferView = 1,
                .byteOffset = current_index_byte_offset,
                .componentType = GLTF_COMPONENT_TYPE_UNSIGNED_INT,
                .count = @intCast(prim.indices.items.len),
                .type = "SCALAR",
            });

            try primitives.append(allocator, .{
                .attributes = .{ .POSITION = 0 },
                .indices = accessor_id,
                .material = prim.material,
            });
        }

        try bin_buf.appendSlice(allocator, index_buf.items);
        const indices_byte_length: u32 = @intCast(index_buf.items.len);

        try bufferViews.append(allocator, .{
            .buffer = 0,
            .byteOffset = 0,
            .byteLength = pos_byte_length,
            .target = GLTF_TARGET_ARRAY_BUFFER,
        });
        try bufferViews.append(allocator, .{
            .buffer = 0,
            .byteOffset = indices_start_offset,
            .byteLength = indices_byte_length,
            .target = GLTF_TARGET_ELEMENT_ARRAY_BUFFER,
        });
    }

    // --- Extract VM Materials & Setup Semantic Roles ---
    var gltf_materials: std.ArrayListUnmanaged(GltfMaterial) = .empty;
    defer gltf_materials.deinit(allocator);

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

            var extras: ?GltfExtras = null;

            if (mat.role == .ghost) {
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
                .extras = extras,
            });
        }
    }

    if (has_transmission) {
        try extensionsUsed.append(allocator, "KHR_materials_transmission");
        try extensionsUsed.append(allocator, "KHR_materials_ior");
    }

    // --- Serialize JSON Hierarchy ---
    const root_obj = .{
        .asset = .{ .version = "2.0", .generator = "KupCAD" },
        .extensionsUsed = if (extensionsUsed.items.len > 0) extensionsUsed.items else null,
        .extensionsRequired = if (extensionsRequired.items.len > 0) extensionsRequired.items else null,
        .scene = 0,
        .scenes = [_]struct { nodes: [1]u32 }{.{ .nodes = .{0} }},
        .nodes = [_]struct { mesh: u32, rotation: [4]f64 }{.{ .mesh = 0, .rotation = .{ -0.7071067811865475, 0.0, 0.0, 0.7071067811865476 } }},
        .meshes = [_]struct { primitives: []Primitive }{.{ .primitives = primitives.items }},
        .materials = gltf_materials.items,
        .accessors = accessors.items,
        .bufferViews = bufferViews.items,
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

    // --- Assemble GLB Payload ---
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

/// Method invocation variant (e.g. `my_part.export_gltf("out.glb")`)
pub fn meshExportGltf(vm: *VM, receiver: value.Value, filepath: []const u8, draco_opt: ?bool) !value.Value {
    var handles = std.ArrayListUnmanaged(geom.GeometryHandle).empty;
    defer handles.deinit(vm.allocator);

    const use_draco = draco_opt orelse false;

    if (receiver.isGeometry()) {
        try handles.append(vm.allocator, try vm.ensureConcrete(receiver));
    } else if (receiver.isAssembly()) {
        for (receiver.asAssembly().parts.items.items) |part| {
            if (part.isGeometry()) try handles.append(vm.allocator, try vm.ensureConcrete(part));
        }
    } else if (receiver.isArray()) {
        for (receiver.asArray().items.items) |part| {
            if (part.isGeometry()) try handles.append(vm.allocator, try vm.ensureConcrete(part));
        }
    } else {
        vm.reportError("TypeError: export_gltf expects a Geometry, Assembly, or Array.\n", .{});
        return error.RuntimeError;
    }

    const glb_bytes = try buildGltfBuffer(vm.allocator, vm, handles.items, use_draco);
    defer vm.allocator.free(glb_bytes);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(vm.io, .{
        .sub_path = filepath,
        .data = glb_bytes,
    });

    return receiver;
}

/// Global function fallback variant (e.g. `export_gltf("out.glb", my_part)`)
pub fn nativeExportGltf(vm: *VM, path_str: []const u8, target: value.Value, draco_opt: ?bool) !value.Value {
    return meshExportGltf(vm, target, path_str, draco_opt);
}
