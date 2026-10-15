const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const util = @import("../../stdlib/methods/util.zig");
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../kernel/geometry_handle.zig");
const draco = @import("../../bindings/draco.zig");

// --- GLTF & Draco Configuration Constants ---
const GLTF_COMPONENT_TYPE_FLOAT = 5126;
const GLTF_COMPONENT_TYPE_UNSIGNED_INT = 5125;
const GLTF_TARGET_ARRAY_BUFFER = 34962;
const GLTF_TARGET_ELEMENT_ARRAY_BUFFER = 34963;
const DRACO_POSITION_QUANTIZATION_BITS = 14;
/// Material slot 0: parts without a `material(...)` (neutral grey, half rough).
const DEFAULT_BASE_COLOR = [4]f64{ 0.8, 0.8, 0.8, 1.0 };
const DEFAULT_ROUGHNESS = 0.5;

const DATA_URI_PREFIX = "data:application/octet-stream;base64,";

/// glTF is Y-up and KupCAD Z-up: the scene's one node turns the model -90 degrees about X.
const Z_UP_TO_Y_UP = [4]f64{ -0.7071067811865475, 0.0, 0.0, 0.7071067811865476 };
/// glTF lengths are metres and KupCAD's millimetres: without this a 10 mm cube opened in
/// another tool as a 10 m one. The mesh data stays in millimetres; the node scales it.
const MM_TO_METRES = 0.001;

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
    byteStride: ?u32 = null,
    target: ?u32 = null,
};

/// glTF's baseColorFactor is linear: decode the sRGB bytes (gamma 2.2).
fn linearColor(rgb: [3]u8, alpha: f64) [4]f64 {
    var color: [4]f64 = .{ 0, 0, 0, alpha };
    for (color[0..3], rgb) |*c, byte| c.* = std.math.pow(f64, @as(f64, @floatFromInt(byte)) / 255.0, 2.2);
    return color;
}

/// How the glTF document is packaged. Both hold the same scene.
pub const Container = enum {
    /// Binary glTF (`.glb`): a JSON chunk followed by the buffer as a binary chunk.
    glb,
    /// glTF JSON (`.gltf`), with the buffer embedded as a base64 data URI so the file stands alone.
    gltf,

    /// `.gltf` for a path ending in it (any case), `.glb` otherwise.
    pub fn forPath(path: []const u8) Container {
        return if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".gltf")) .gltf else .glb;
    }
};

pub fn buildGltfBuffer(
    allocator: std.mem.Allocator,
    vm: *VM,
    handles: []const geom.GeometryHandle,
    use_draco: bool,
    container: Container,
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

    for (handles) |handle| {
        // A part the kernel can't mesh is an error: skipping it exported a model without it.
        if (!kernel.supports(handle.engine, .mesh)) return error.EngineCannotTessellate;
        const mesh = kernel.getMesh(allocator, handle) orelse return error.MeshExtractionFailed;
        defer allocator.free(mesh.vert_props);
        defer allocator.free(mesh.tri_verts);

        const vertex_count: u32 = @intCast(mesh.vert_props.len / mesh.num_prop);
        if (vertex_count == 0) continue;

        const base_vertex = total_vertices;
        total_vertices += vertex_count;

        var mat_indices = std.AutoHashMap(u32, std.ArrayListUnmanaged(u32)).init(allocator);
        defer mat_indices.deinit();

        var i: usize = 0;
        while (i < mesh.tri_verts.len) : (i += 3) {
            const v_idx = mesh.tri_verts[i] * mesh.num_prop;
            const slot: u32 = if (mesh.num_prop >= 4) @intFromFloat(mesh.vert_props[v_idx + 3]) else kernel.DEFAULT_MATERIAL_SLOT;

            const gop = try mat_indices.getOrPut(slot);
            if (!gop.found_existing) gop.value_ptr.* = .empty;

            try gop.value_ptr.appendSlice(allocator, &.{
                mesh.tri_verts[i] + base_vertex,
                mesh.tri_verts[i + 1] + base_vertex,
                mesh.tri_verts[i + 2] + base_vertex,
            });
        }

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
        // Uncompressed: one buffer view of tightly packed positions for every part (accessor 0
        // above), then one index buffer per (part, material) primitive. The same layout as the
        // draco branch, so both export every part with its own material.
        try bin_buf.appendSlice(allocator, vertex_buf.items);
        try bufferViews.append(allocator, .{
            .buffer = 0,
            .byteOffset = 0,
            .byteLength = @intCast(vertex_buf.items.len),
            .target = GLTF_TARGET_ARRAY_BUFFER,
        });

        for (primitives_data.items) |prim| {
            const idx_byte_offset: u32 = @intCast(bin_buf.items.len);
            const raw_indices = std.mem.sliceAsBytes(prim.indices.items);
            try bin_buf.appendSlice(allocator, raw_indices);

            const idx_bv_idx: u32 = @intCast(bufferViews.items.len);
            try bufferViews.append(allocator, .{
                .buffer = 0,
                .byteOffset = idx_byte_offset,
                .byteLength = @intCast(raw_indices.len),
                .target = GLTF_TARGET_ELEMENT_ARRAY_BUFFER,
            });

            const idx_accessor_idx: u32 = @intCast(accessors.items.len);
            try accessors.append(allocator, .{
                .bufferView = idx_bv_idx,
                .byteOffset = 0,
                .componentType = GLTF_COMPONENT_TYPE_UNSIGNED_INT,
                .count = @intCast(prim.indices.items.len),
                .type = "SCALAR",
            });

            try primitives.append(allocator, .{
                .attributes = .{ .POSITION = 0 },
                .indices = idx_accessor_idx,
                .material = prim.material,
            });
        }
    }

    var gltf_materials: std.ArrayListUnmanaged(GltfMaterial) = .empty;
    defer gltf_materials.deinit(allocator);

    var has_transmission = false;

    // glTF material index == material slot: the default material first, then one per
    // user material (kernel.materialSlot).
    try gltf_materials.append(allocator, .{
        .pbrMetallicRoughness = .{ .baseColorFactor = DEFAULT_BASE_COLOR, .metallicFactor = 0.0, .roughnessFactor = DEFAULT_ROUGHNESS },
        .alphaMode = "OPAQUE",
    });
    {
        for (vm.materials.items) |mat| {
            const color = linearColor(mat.rgb, mat.alpha);
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

    const data_uri: ?[]const u8 = switch (container) {
        .glb => null,
        .gltf => try dataUri(allocator, bin_buf.items),
    };
    defer if (data_uri) |uri| allocator.free(uri);

    const root_obj = .{
        .asset = .{ .version = "2.0", .generator = "KupCAD" },
        .extensionsUsed = if (extensionsUsed.items.len > 0) extensionsUsed.items else null,
        .extensionsRequired = if (extensionsRequired.items.len > 0) extensionsRequired.items else null,
        .scene = 0,
        .scenes = [_]struct { nodes: [1]u32 }{.{ .nodes = .{0} }},
        .nodes = [_]struct { mesh: u32, rotation: [4]f64, scale: [3]f64 }{.{ .mesh = 0, .rotation = Z_UP_TO_Y_UP, .scale = @splat(MM_TO_METRES) }},
        .meshes = [_]struct { primitives: []Primitive }{.{ .primitives = primitives.items }},
        .materials = gltf_materials.items,
        .accessors = accessors.items,
        .bufferViews = bufferViews.items,
        .buffers = [_]struct { byteLength: usize, uri: ?[]const u8 }{.{ .byteLength = bin_buf.items.len, .uri = data_uri }},
    };

    var json_writer = std.Io.Writer.Allocating.init(allocator);
    defer json_writer.deinit();
    try json_writer.writer.print("{f}", .{std.json.fmt(root_obj, .{ .emit_null_optional_fields = false })});

    return switch (container) {
        .gltf => json_writer.toOwnedSlice(),
        .glb => packGlb(allocator, json_writer.written(), &bin_buf),
    };
}

fn dataUri(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const uri = try allocator.alloc(u8, DATA_URI_PREFIX.len + encoder.calcSize(bytes.len));
    @memcpy(uri[0..DATA_URI_PREFIX.len], DATA_URI_PREFIX);
    _ = encoder.encode(uri[DATA_URI_PREFIX.len..], bytes);
    return uri;
}

/// The GLB container: a 12-byte header, then the JSON and binary chunks, each padded to 4 bytes.
fn packGlb(allocator: std.mem.Allocator, json: []const u8, bin_buf: *std.ArrayListUnmanaged(u8)) ![]const u8 {
    var json_out: std.ArrayListUnmanaged(u8) = .empty;
    defer json_out.deinit(allocator);
    try json_out.appendSlice(allocator, json);

    while (json_out.items.len % 4 != 0) try json_out.append(allocator, ' ');
    while (bin_buf.items.len % 4 != 0) try bin_buf.append(allocator, 0);

    const bin_len: u32 = @intCast(bin_buf.items.len);
    const json_len: u32 = @intCast(json_out.items.len);
    const total_length: u32 = 12 + 8 + json_len + 8 + bin_len;

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
        _ = vm.raiseError(.TypeError, "export_gltf expects a Geometry, an Assembly or an Array of them, got {s}", .{util.typeName(vm, receiver)});
        return error.RuntimeError;
    }

    for (handles.items) |h| try vm.requireFeature(h.engine, .mesh);
    const bytes = try buildGltfBuffer(vm.allocator, vm, handles.items, use_draco, Container.forPath(filepath));
    defer vm.allocator.free(bytes);

    try vm.vfs.writeFile(filepath, bytes);

    return receiver;
}

pub fn nativeExportGltf(vm: *VM, path_str: []const u8, target: value.Value, draco_opt: ?bool) !value.Value {
    return meshExportGltf(vm, target, path_str, draco_opt);
}
