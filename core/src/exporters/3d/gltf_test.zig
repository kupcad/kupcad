const std = @import("std");
const gltf = @import("gltf.zig");
const registry = @import("../../stdlib/registry.zig");
const dag_evaluator = @import("../../vm/dag_evaluator.zig");
const geom = @import("../../kernel/geometry_handle.zig");
const VM = @import("../../vm/vm.zig").VM;

const GLB_HEADER_LEN = 12;
const CHUNK_HEADER_LEN = 8;

test "GLTF: Zero-Copy GLB export generates valid binary container" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const cube_idx = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);
    const handle = try dag_evaluator.evaluateDAG(&vm, cube_idx);

    const handles = [_]geom.GeometryHandle{handle};
    const glb_bytes = try gltf.buildGltfBuffer(std.testing.allocator, &vm, &handles, false, .glb);
    defer std.testing.allocator.free(glb_bytes);

    // 1. Check GLB Magic Bytes "glTF"
    try std.testing.expect(glb_bytes.len > 12);
    try std.testing.expectEqualStrings("glTF", glb_bytes[0..4]);

    // 2. Check Version == 2
    var version: u32 = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&version), glb_bytes[4..8]);
    try std.testing.expectEqual(@as(u32, 2), version);
}

// --- Structural validation of exported GLB files ---

const api = @import("../../api.zig");

const Glb = struct {
    json: std.json.Parsed(std.json.Value),
    bin: []const u8,

    fn deinit(self: *Glb) void {
        self.json.deinit();
    }

    fn array(self: *const Glb, name: []const u8) []std.json.Value {
        return self.json.value.object.get(name).?.array.items;
    }
};

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn parseGlb(bytes: []const u8) !Glb {
    try std.testing.expectEqualStrings("glTF", bytes[0..4]);
    try std.testing.expectEqual(bytes.len, readU32(bytes, 8));
    const json_len = readU32(bytes, GLB_HEADER_LEN);
    const json_start = GLB_HEADER_LEN + CHUNK_HEADER_LEN;
    const bin_header = json_start + json_len;
    const bin_len = readU32(bytes, bin_header);
    const bin_start = bin_header + CHUNK_HEADER_LEN;
    try std.testing.expectEqual(bytes.len, bin_start + bin_len);
    return .{
        .json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes[json_start..bin_header], .{}),
        .bin = bytes[bin_start..][0..bin_len],
    };
}

fn int(v: std.json.Value) usize {
    return @intCast(v.integer);
}

fn componentBytes(accessor: std.json.ObjectMap) usize {
    const per_component: usize = switch (int(accessor.get("componentType").?)) {
        5126, 5125 => 4, // FLOAT, UNSIGNED_INT
        else => unreachable,
    };
    const type_name = accessor.get("type").?.string;
    const components: usize = if (std.mem.eql(u8, type_name, "VEC3")) 3 else 1;
    return per_component * components;
}

/// Every accessor fits inside its buffer view, every view inside the binary chunk, every
/// primitive's accessors and material exist, and (uncompressed) every index addresses an
/// existing vertex. The old exporter broke the first rule for any multi-part model.
fn expectValidLayout(glb: *const Glb) !void {
    const accessors = glb.array("accessors");
    const views = glb.array("bufferViews");
    const materials = glb.array("materials");
    for (views) |v| {
        const offset = if (v.object.get("byteOffset")) |o| int(o) else 0;
        try std.testing.expect(offset + int(v.object.get("byteLength").?) <= glb.bin.len);
    }
    for (accessors) |a| {
        const view_idx = a.object.get("bufferView") orelse continue; // draco-compressed
        const view = views[int(view_idx)].object;
        const elem = componentBytes(a.object);
        const stride = if (view.get("byteStride")) |s| int(s) else elem;
        const count = int(a.object.get("count").?);
        const needed = int(a.object.get("byteOffset").?) + (count - 1) * stride + elem;
        try std.testing.expect(needed <= int(view.get("byteLength").?));
    }
    const prims = glb.array("meshes")[0].object.get("primitives").?.array.items;
    for (prims) |p| {
        const pos = int(p.object.get("attributes").?.object.get("POSITION").?);
        const idx = int(p.object.get("indices").?);
        try std.testing.expect(pos < accessors.len and idx < accessors.len);
        try std.testing.expect(int(p.object.get("material").?) < materials.len);
        const idx_view = accessors[idx].object.get("bufferView") orelse continue;
        const view = views[int(idx_view)].object;
        const start = if (view.get("byteOffset")) |o| int(o) else 0;
        const indices = std.mem.bytesAsSlice(u32, glb.bin[start..][0..int(view.get("byteLength").?)]);
        const vertex_count = int(accessors[pos].object.get("count").?);
        for (indices) |i| try std.testing.expect(std.mem.littleToNative(u32, i) < vertex_count);
    }
}

/// The base colour of the material each primitive uses, in primitive order.
fn primitiveColors(glb: *const Glb, out: [][4]f64) ![][4]f64 {
    const materials = glb.array("materials");
    const prims = glb.array("meshes")[0].object.get("primitives").?.array.items;
    for (prims, 0..) |p, i| {
        const mat = materials[int(p.object.get("material").?)].object;
        const factor = mat.get("pbrMetallicRoughness").?.object.get("baseColorFactor").?.array.items;
        for (factor, 0..) |c, k| out[i][k] = switch (c) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => unreachable,
        };
    }
    return out[0..prims.len];
}

test "GLTF: multi-part exports are valid and each part keeps its own material" {
    // A plain part, a red part, and a union where only one operand is green.
    const source =
        \\[cube(2), cube(2).translate(x: 5).material(color: "#FF0000"),
        \\ (cube(2).material(color: "#00FF00") + cube(2).translate(x: 1)).translate(y: 10)]
    ;
    for ([_]bool{ false, true }) |use_draco| {
        errdefer std.debug.print("draco: {}\n", .{use_draco});
        const bytes = try api.buildModel(std.testing.allocator, std.testing.io, source, "glb", use_draco, null, null);
        defer std.testing.allocator.free(bytes);
        var glb = try parseGlb(bytes);
        defer glb.deinit();
        try expectValidLayout(&glb);

        // Default material first, then one per material(...) call.
        try std.testing.expectEqual(@as(usize, 3), glb.array("materials").len);
        var buf: [8][4]f64 = undefined;
        const colors = try primitiveColors(&glb, &buf);
        var grey: usize = 0;
        var red: usize = 0;
        var green: usize = 0;
        for (colors) |c| {
            if (c[0] == 0.8 and c[1] == 0.8) grey += 1;
            if (c[0] == 1 and c[1] == 0) red += 1;
            if (c[0] == 0 and c[1] == 1) green += 1;
        }
        // The plain cube and the plain half of the union stay grey; nothing else turns red or green.
        try std.testing.expectEqual(@as(usize, 2), grey);
        try std.testing.expectEqual(@as(usize, 1), red);
        try std.testing.expectEqual(@as(usize, 1), green);
    }
}

test "GLTF: a model without materials uses only the default material" {
    const bytes = try api.buildModel(std.testing.allocator, std.testing.io, "[cube(1), sphere(1).translate(x: 3)]", "glb", false, null, null);
    defer std.testing.allocator.free(bytes);
    var glb = try parseGlb(bytes);
    defer glb.deinit();
    try expectValidLayout(&glb);
    try std.testing.expectEqual(@as(usize, 1), glb.array("materials").len);
}

/// A `.gltf` file: JSON whose one buffer is a base64 data URI, decoded into `bin`
/// (owned) so the GLB layout checks apply unchanged.
fn parseGltfJson(bytes: []const u8, bin_storage: *[]u8) !Glb {
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    errdefer json.deinit();
    const buffers = json.value.object.get("buffers").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), buffers.len);
    const uri = buffers[0].object.get("uri").?.string;
    const prefix = "data:application/octet-stream;base64,";
    try std.testing.expect(std.mem.startsWith(u8, uri, prefix));
    const decoder = std.base64.standard.Decoder;
    bin_storage.* = try std.testing.allocator.alloc(u8, try decoder.calcSizeForSlice(uri[prefix.len..]));
    try decoder.decode(bin_storage.*, uri[prefix.len..]);
    try std.testing.expectEqual(bin_storage.len, int(buffers[0].object.get("byteLength").?));
    return .{ .json = json, .bin = bin_storage.* };
}

test "GLTF: a .gltf export is JSON with the buffer embedded, the same scene as .glb" {
    // `-o part.gltf` used to write binary GLB under a .gltf name.
    const source = "[cube(2), cube(2).translate(x: 5).material(color: \"#FF0000\")]";
    for ([_]bool{ false, true }) |use_draco| {
        errdefer std.debug.print("draco: {}\n", .{use_draco});
        const json_bytes = try api.buildModel(std.testing.allocator, std.testing.io, source, "gltf", use_draco, null, null);
        defer std.testing.allocator.free(json_bytes);
        try std.testing.expectEqual(@as(u8, '{'), json_bytes[0]);
        var bin: []u8 = &.{};
        defer std.testing.allocator.free(bin);
        var doc = try parseGltfJson(json_bytes, &bin);
        defer doc.deinit();
        try expectValidLayout(&doc);

        const glb_bytes = try api.buildModel(std.testing.allocator, std.testing.io, source, "glb", use_draco, null, null);
        defer std.testing.allocator.free(glb_bytes);
        var glb = try parseGlb(glb_bytes);
        defer glb.deinit();
        try std.testing.expectEqualSlices(u8, glb.bin[0..bin.len], bin);
        for ([_][]const u8{ "accessors", "bufferViews", "materials" }) |name| {
            try std.testing.expectEqual(glb.array(name).len, doc.array(name).len);
        }
        // A GLB's buffer lives in its binary chunk, so it has no uri.
        try std.testing.expect(glb.array("buffers")[0].object.get("uri") == null);
    }
}

test "GLTF: export_gltf picks the container from the file extension" {
    try std.testing.expectEqual(gltf.Container.gltf, gltf.Container.forPath("out/part.gltf"));
    try std.testing.expectEqual(gltf.Container.gltf, gltf.Container.forPath("PART.GLTF"));
    try std.testing.expectEqual(gltf.Container.glb, gltf.Container.forPath("part.glb"));
    try std.testing.expectEqual(gltf.Container.glb, gltf.Container.forPath("part"));
}

test "GLTF: the scene is in metres and Y-up, as glTF defines" {
    // KupCAD works in millimetres, Z-up; a 10 mm cube used to open elsewhere as 10 m.
    const bytes = try api.buildModel(std.testing.allocator, std.testing.io, "cube(10)", "glb", false, null, null);
    defer std.testing.allocator.free(bytes);
    var glb = try parseGlb(bytes);
    defer glb.deinit();
    const node = glb.array("nodes")[0].object;
    for (node.get("scale").?.array.items) |s| try std.testing.expectEqual(@as(f64, 0.001), s.float);
    const rotation = node.get("rotation").?.array.items;
    try std.testing.expectApproxEqAbs(@as(f64, -std.math.sqrt1_2), rotation[0].float, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, std.math.sqrt1_2), rotation[3].float, 1e-12);
    // The mesh itself stays in millimetres: the position accessor spans 0..10.
    const pos = glb.array("accessors")[0].object;
    try std.testing.expectEqual(@as(f64, 10), switch (pos.get("max").?.array.items[0]) {
        .float => |f| f,
        .integer => |n| @as(f64, @floatFromInt(n)),
        else => unreachable,
    });
}

test "GLTF: a part the engine can't tessellate is an error, not left out of the model" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const cube_idx = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);
    const mesh_part = try dag_evaluator.evaluateDAG(&vm, cube_idx);
    vm.config().engine = .brep_native;
    const brep_part = try dag_evaluator.evaluateDAG(&vm, cube_idx);

    const handles = [_]geom.GeometryHandle{ mesh_part, brep_part };
    try std.testing.expectError(error.EngineCannotTessellate, gltf.buildGltfBuffer(std.testing.allocator, &vm, &handles, false, .glb));
}
