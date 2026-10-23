//! glTF export: `buildGltfBuffer` meshes each part into one primitive per part and material,
//! optionally Draco-compressed, as a `.glb` or a self-contained `.gltf` (`Container`), with
//! the scene turned Z-up to Y-up and scaled to metres. The script's `export_gltf` is in
//! stdlib/files.zig.

const std = @import("std");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../kernel/geometry_handle.zig");
const draco = @import("../../bindings/draco.zig");
const MaterialDef = @import("../../core/material.zig").MaterialDef;
const material_groups = @import("material_groups.zig");

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
/// Each starts where its buffer view does, glTF's default, so no byteOffset is written: a
/// Draco accessor has no buffer view, and a byteOffset without one is invalid glTF.
const Accessor = struct {
    bufferView: ?u32 = null,
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
    var parts: Parts = .{};
    defer parts.deinit(allocator);
    for (handles) |handle| try parts.add(allocator, handle);
    if (parts.vertexCount() == 0) return error.NoGeometry;

    var doc: Gltf = .{};
    defer doc.deinit(allocator);
    if (use_draco) try doc.addDracoPrimitives(allocator, &parts) else try doc.addPrimitives(allocator, &parts);
    try doc.addMaterials(allocator, vm.materials.items);
    return doc.write(allocator, container);
}

/// One part's triangles with one material: a glTF primitive.
const PartPrimitive = struct {
    material: u32,
    /// Into Parts.positions, as vertex numbers.
    indices: std.ArrayList(u32),
};

/// Every part's mesh, merged: the positions of all their vertices (x, y, z each) with
/// their bounds, and one primitive per part and material, so every part keeps its own.
const Parts = struct {
    positions: std.ArrayList(f32) = .empty,
    primitives: std.ArrayList(PartPrimitive) = .empty,
    min: [3]f64 = @splat(std.math.inf(f64)),
    max: [3]f64 = @splat(-std.math.inf(f64)),

    fn deinit(self: *Parts, allocator: std.mem.Allocator) void {
        for (self.primitives.items) |*p| p.indices.deinit(allocator);
        self.primitives.deinit(allocator);
        self.positions.deinit(allocator);
    }

    fn vertexCount(self: *const Parts) u32 {
        return @intCast(self.positions.items.len / 3);
    }

    /// Meshes `handle` and adds its vertices and its primitives.
    fn add(self: *Parts, allocator: std.mem.Allocator, handle: geom.GeometryHandle) !void {
        // A part the kernel can't mesh is an error: skipping it exported a model without it.
        if (!kernel.supports(handle.engine, .mesh)) return error.EngineCannotTessellate;
        const mesh = kernel.getMesh(allocator, handle) orelse return error.MeshExtractionFailed;
        defer allocator.free(mesh.vert_props);
        defer allocator.free(mesh.tri_verts);
        if (mesh.vert_props.len / mesh.num_prop == 0) return;
        const base_vertex = self.vertexCount();

        var groups = try material_groups.Groups.collect(allocator, mesh);
        defer groups.deinit(allocator);

        var v: usize = 0;
        while (v < mesh.vert_props.len) : (v += mesh.num_prop) {
            const position = mesh.vert_props[v..][0..3];
            try self.positions.appendSlice(allocator, position);
            for (position, &self.min, &self.max) |c, *lo, *hi| {
                lo.* = @min(lo.*, @as(f64, @floatCast(c)));
                hi.* = @max(hi.*, @as(f64, @floatCast(c)));
            }
        }

        try self.primitives.ensureUnusedCapacity(allocator, groups.count());
        for (0..groups.count()) |g| {
            const group = groups.at(g);
            var indices: std.ArrayList(u32) = .empty;
            errdefer indices.deinit(allocator);
            try indices.ensureTotalCapacity(allocator, group.tri_starts.len * 3);
            for (group.tri_starts) |tri| {
                for (mesh.tri_verts[tri..][0..3]) |vertex| indices.appendAssumeCapacity(vertex + base_vertex);
            }
            self.primitives.appendAssumeCapacity(.{ .material = group.slot, .indices = indices });
        }
    }
};

/// The glTF document's tables as they are filled in, and its one binary buffer.
const Gltf = struct {
    primitives: std.ArrayList(Primitive) = .empty,
    accessors: std.ArrayList(Accessor) = .empty,
    buffer_views: std.ArrayList(BufferView) = .empty,
    materials: std.ArrayList(GltfMaterial) = .empty,
    extensions_used: std.ArrayList([]const u8) = .empty,
    extensions_required: std.ArrayList([]const u8) = .empty,
    bin: std.ArrayList(u8) = .empty,

    fn deinit(self: *Gltf, allocator: std.mem.Allocator) void {
        self.primitives.deinit(allocator);
        self.accessors.deinit(allocator);
        self.buffer_views.deinit(allocator);
        self.materials.deinit(allocator);
        self.extensions_used.deinit(allocator);
        self.extensions_required.deinit(allocator);
        self.bin.deinit(allocator);
    }

    fn addAccessor(self: *Gltf, allocator: std.mem.Allocator, accessor: Accessor) !u32 {
        try self.accessors.append(allocator, accessor);
        return @intCast(self.accessors.items.len - 1);
    }

    fn addBufferView(self: *Gltf, allocator: std.mem.Allocator, view: BufferView) !u32 {
        try self.buffer_views.append(allocator, view);
        return @intCast(self.buffer_views.items.len - 1);
    }

    /// Uncompressed: one buffer view of tightly packed positions for every part (accessor
    /// 0), then one index buffer per primitive.
    fn addPrimitives(self: *Gltf, allocator: std.mem.Allocator, parts: *const Parts) !void {
        const positions = try self.addAccessor(allocator, .{
            .bufferView = 0,
            .componentType = GLTF_COMPONENT_TYPE_FLOAT,
            .count = parts.vertexCount(),
            .type = "VEC3",
            .min = parts.min,
            .max = parts.max,
        });
        for (parts.positions.items) |c| try appendF32Le(&self.bin, allocator, c);
        _ = try self.addBufferView(allocator, .{
            .buffer = 0,
            .byteOffset = 0,
            .byteLength = @intCast(self.bin.items.len),
            .target = GLTF_TARGET_ARRAY_BUFFER,
        });

        for (parts.primitives.items) |prim| {
            const byte_offset: u32 = @intCast(self.bin.items.len);
            for (prim.indices.items) |index| try appendU32Le(&self.bin, allocator, index);
            const view = try self.addBufferView(allocator, .{
                .buffer = 0,
                .byteOffset = byte_offset,
                .byteLength = @intCast(prim.indices.items.len * 4),
                .target = GLTF_TARGET_ELEMENT_ARRAY_BUFFER,
            });
            const indices = try self.addAccessor(allocator, .{
                .bufferView = view,
                .componentType = GLTF_COMPONENT_TYPE_UNSIGNED_INT,
                .count = @intCast(prim.indices.items.len),
                .type = "SCALAR",
            });
            try self.primitives.append(allocator, .{ .attributes = .{ .POSITION = positions }, .indices = indices, .material = prim.material });
        }
    }

    /// Draco: each primitive compressed on its own into a buffer view, with accessors that
    /// only count (Draco decodes the data).
    fn addDracoPrimitives(self: *Gltf, allocator: std.mem.Allocator, parts: *const Parts) !void {
        try self.extensions_used.append(allocator, "KHR_draco_mesh_compression");
        try self.extensions_required.append(allocator, "KHR_draco_mesh_compression");

        for (parts.primitives.items) |prim| {
            // Draco decodes each primitive's mesh on its own, so its POSITION accessor must
            // count that mesh's vertices: the ones the primitive uses, renumbered. (Every
            // primitive pointed at one accessor with the total vertex count, a malformed
            // file for any multi-part model.)
            var compact = try compactPrimitive(allocator, parts.positions.items, prim.indices.items);
            defer compact.deinit(allocator);
            const draco_bytes = try draco.encodeMesh(allocator, compact.positions.items, compact.indices, DRACO_POSITION_QUANTIZATION_BITS);
            defer allocator.free(draco_bytes);

            const draco_offset: u32 = @intCast(self.bin.items.len);
            try self.bin.appendSlice(allocator, draco_bytes);
            while (self.bin.items.len % 4 != 0) try self.bin.append(allocator, 0);
            const view = try self.addBufferView(allocator, .{
                .buffer = 0,
                .byteOffset = draco_offset,
                .byteLength = @intCast(draco_bytes.len),
            });

            const positions = try self.addAccessor(allocator, .{
                .componentType = GLTF_COMPONENT_TYPE_FLOAT,
                .count = @intCast(compact.positions.items.len / 3),
                .type = "VEC3",
                .min = compact.min,
                .max = compact.max,
            });
            const indices = try self.addAccessor(allocator, .{
                .componentType = GLTF_COMPONENT_TYPE_UNSIGNED_INT,
                .count = @intCast(prim.indices.items.len),
                .type = "SCALAR",
            });
            try self.primitives.append(allocator, .{
                .attributes = .{ .POSITION = positions },
                .indices = indices,
                .material = prim.material,
                .extensions = .{
                    .KHR_draco_mesh_compression = .{
                        .bufferView = view,
                        // Draco's own attribute id within the compressed mesh, not an accessor
                        .attributes = .{ .POSITION = 0 },
                    },
                },
            });
        }
    }

    /// glTF material index == material slot: the default material first, then one per
    /// user material (kernel.materialSlot).
    fn addMaterials(self: *Gltf, allocator: std.mem.Allocator, defs: []const MaterialDef) !void {
        try self.materials.append(allocator, .{
            .pbrMetallicRoughness = .{ .baseColorFactor = DEFAULT_BASE_COLOR, .metallicFactor = 0.0, .roughnessFactor = DEFAULT_ROUGHNESS },
            .alphaMode = "OPAQUE",
        });
        var has_transmission = false;
        for (defs) |def| {
            try self.materials.append(allocator, gltfMaterial(def));
            has_transmission = has_transmission or def.transmission > 0.0;
        }
        if (has_transmission) {
            try self.extensions_used.append(allocator, "KHR_materials_transmission");
            try self.extensions_used.append(allocator, "KHR_materials_ior");
        }
    }

    /// The document as `container` packages it, the scene turned Y-up and scaled to metres.
    fn write(self: *Gltf, allocator: std.mem.Allocator, container: Container) ![]const u8 {
        const data_uri: ?[]const u8 = switch (container) {
            .glb => null,
            .gltf => try dataUri(allocator, self.bin.items),
        };
        defer if (data_uri) |uri| allocator.free(uri);

        const root_obj = .{
            .asset = .{ .version = "2.0", .generator = "KupCAD" },
            .extensionsUsed = if (self.extensions_used.items.len > 0) self.extensions_used.items else null,
            .extensionsRequired = if (self.extensions_required.items.len > 0) self.extensions_required.items else null,
            .scene = 0,
            .scenes = [_]struct { nodes: [1]u32 }{.{ .nodes = .{0} }},
            .nodes = [_]struct { mesh: u32, rotation: [4]f64, scale: [3]f64 }{.{ .mesh = 0, .rotation = Z_UP_TO_Y_UP, .scale = @splat(MM_TO_METRES) }},
            .meshes = [_]struct { primitives: []Primitive }{.{ .primitives = self.primitives.items }},
            .materials = self.materials.items,
            .accessors = self.accessors.items,
            .bufferViews = self.buffer_views.items,
            .buffers = [_]struct { byteLength: usize, uri: ?[]const u8 }{.{ .byteLength = self.bin.items.len, .uri = data_uri }},
        };

        var json_writer = std.Io.Writer.Allocating.init(allocator);
        defer json_writer.deinit();
        try json_writer.writer.print("{f}", .{std.json.fmt(root_obj, .{ .emit_null_optional_fields = false })});

        return switch (container) {
            .gltf => json_writer.toOwnedSlice(),
            .glb => packGlb(allocator, json_writer.written(), &self.bin),
        };
    }
};

/// A script's material as glTF's: a ghost blends and a highlight is tagged, for the viewer;
/// transmission (glass) needs two extensions and is opaque to them.
fn gltfMaterial(def: MaterialDef) GltfMaterial {
    var material: GltfMaterial = .{
        .pbrMetallicRoughness = .{ .baseColorFactor = linearColor(def.rgb, def.alpha), .metallicFactor = def.metallic, .roughnessFactor = def.roughness },
        .alphaMode = if (def.alpha < 1.0) "BLEND" else "OPAQUE",
    };
    switch (def.role) {
        .ghost => {
            material.alphaMode = "BLEND";
            material.extras = .{ .kupcad_role = "ghost" };
        },
        .highlight => material.extras = .{ .kupcad_role = "highlight" },
        .standard => {},
    }
    if (def.transmission > 0.0) {
        material.extensions = .{
            .KHR_materials_transmission = .{ .transmissionFactor = def.transmission },
            .KHR_materials_ior = .{ .ior = 1.5 },
        };
        material.alphaMode = "OPAQUE";
    }
    return material;
}

fn dataUri(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const uri = try allocator.alloc(u8, DATA_URI_PREFIX.len + encoder.calcSize(bytes.len));
    @memcpy(uri[0..DATA_URI_PREFIX.len], DATA_URI_PREFIX);
    _ = encoder.encode(uri[DATA_URI_PREFIX.len..], bytes);
    return uri;
}

/// The GLB container: a 12-byte header, then the JSON and binary chunks, each padded to 4 bytes.
fn packGlb(allocator: std.mem.Allocator, json: []const u8, bin_buf: *std.ArrayList(u8)) ![]const u8 {
    var json_out: std.ArrayList(u8) = .empty;
    defer json_out.deinit(allocator);
    try json_out.appendSlice(allocator, json);

    while (json_out.items.len % 4 != 0) try json_out.append(allocator, ' ');
    while (bin_buf.items.len % 4 != 0) try bin_buf.append(allocator, 0);

    const bin_len: u32 = @intCast(bin_buf.items.len);
    const json_len: u32 = @intCast(json_out.items.len);
    const total_length: u32 = 12 + 8 + json_len + 8 + bin_len;

    var glb_payload: std.ArrayList(u8) = .empty;
    errdefer glb_payload.deinit(allocator);

    const magic: u32 = 0x46546C67; // "glTF"
    const version: u32 = 2;
    const json_chunk_type: u32 = 0x4E4F534A; // "JSON"
    const bin_chunk_type: u32 = 0x004E4942; // "BIN\0"

    // glTF is little-endian on any host (the header and buffers were written in native order)
    for ([_]u32{ magic, version, total_length, json_len, json_chunk_type }) |word| try appendU32Le(&glb_payload, allocator, word);
    try glb_payload.appendSlice(allocator, json_out.items);
    for ([_]u32{ bin_len, bin_chunk_type }) |word| try appendU32Le(&glb_payload, allocator, word);
    try glb_payload.appendSlice(allocator, bin_buf.items);

    return try glb_payload.toOwnedSlice(allocator);
}

fn appendU32Le(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, word: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, word, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn appendF32Le(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, f: f32) !void {
    try appendU32Le(buf, allocator, @bitCast(f));
}

/// The vertices one primitive uses, renumbered from 0 in order of first use, its indices
/// rewritten to match, and the bounds of those vertices.
const CompactMesh = struct {
    positions: std.ArrayList(f32) = .empty,
    indices: []u32,
    min: [3]f64 = .{ std.math.inf(f64), std.math.inf(f64), std.math.inf(f64) },
    max: [3]f64 = .{ -std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) },

    fn deinit(self: *CompactMesh, allocator: std.mem.Allocator) void {
        self.positions.deinit(allocator);
        allocator.free(self.indices);
    }
};

fn compactPrimitive(allocator: std.mem.Allocator, positions: []const f32, indices: []const u32) !CompactMesh {
    var compact: CompactMesh = .{ .indices = try allocator.alloc(u32, indices.len) };
    errdefer compact.deinit(allocator);
    var renumbered = std.AutoHashMap(u32, u32).init(allocator);
    defer renumbered.deinit();
    for (indices, compact.indices) |old, *new| {
        const gop = try renumbered.getOrPut(old);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(compact.positions.items.len / 3);
            const vertex = positions[old * 3 ..][0..3];
            try compact.positions.appendSlice(allocator, vertex);
            for (vertex, &compact.min, &compact.max) |c, *lo, *hi| {
                lo.* = @min(lo.*, @as(f64, @floatCast(c)));
                hi.* = @max(hi.*, @as(f64, @floatCast(c)));
            }
        }
        new.* = gop.value_ptr.*;
    }
    return compact;
}
