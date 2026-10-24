const std = @import("std");
const gltf = @import("gltf.zig");
const MeshPart = @import("mesh_part.zig").MeshPart;
const registry = @import("../../stdlib/registry.zig");
const dag_evaluator = @import("../../vm/dag_evaluator.zig");
const VM = @import("../../vm/vm.zig").VM;
const draco = @import("../../bindings/draco.zig");
const mesh_check = @import("../../kernel/mesh_check.zig");

const GLB_HEADER_LEN = 12;
const CHUNK_HEADER_LEN = 8;

const PARTS_SOURCE =
    \\[cube(2), sphere(1).translate(x: 5).material(color: "#FF0000"),
    \\ (cube(2).material(color: "#00FF00") + cylinder(r: 1, h: 4).translate(x: 1)).translate(y: 10)]
;

test "GLTF: Zero-Copy GLB export generates valid binary container" {
    var vm = try VM.init(std.testing.allocator, std.testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const cube_idx = try vm.dag_builder.addCube(10.0, 10.0, 10.0, true);
    const handle = try dag_evaluator.evaluateDAG(&vm, cube_idx);

    const parts = [_]MeshPart{.{ .handle = handle }};
    const glb_bytes = try gltf.buildGltfBuffer(std.testing.allocator, vm.materials.items, &parts, null, .glb);
    defer std.testing.allocator.free(glb_bytes);

    // 1. Check GLB Magic Bytes "glTF"
    try std.testing.expect(glb_bytes.len > 12);
    try std.testing.expectEqualStrings("glTF", glb_bytes[0..4]);

    // 2. Check Version == 2
    var version: u32 = undefined;
    @memmove(std.mem.asBytes(&version), glb_bytes[4..8]);
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

/// Every mesh's primitives in the file's order: a mesh per part, each its own node.
fn allPrimitives(glb: *const Glb) ![]std.json.Value {
    var prims: std.ArrayList(std.json.Value) = .empty;
    errdefer prims.deinit(std.testing.allocator);
    for (glb.array("meshes")) |mesh| try prims.appendSlice(std.testing.allocator, mesh.object.get("primitives").?.array.items);
    return prims.toOwnedSlice(std.testing.allocator);
}

test "GLTF: each part is a node named after it, under the root node that turns the scene" {
    // The parts were one mesh on the root node, unnamed: a viewer showed one object.
    const source = "lid = cube(1).named(\"lid\")\nassemble(name: \"box\", parts: [lid, lid.translate(x: 3), cube(2).translate(x: 6)])";
    const bytes = try api.buildModel(std.testing.allocator, std.testing.io, source, .{ .format = .glb });
    defer std.testing.allocator.free(bytes);
    var glb = try parseGlb(bytes);
    defer glb.deinit();
    try expectValidLayout(&glb);
    const nodes = glb.array("nodes");
    const meshes = glb.array("meshes");
    try std.testing.expectEqual(@as(usize, 4), nodes.len);
    try std.testing.expectEqual(@as(usize, 3), meshes.len);
    const root = nodes[0].object;
    try std.testing.expect(root.get("rotation") != null and root.get("mesh") == null and root.get("name") == null);
    const children = root.get("children").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), children.len);
    for ([_][]const u8{ "lid", "lid_2", "part_1" }, 1..) |name, n| {
        try std.testing.expectEqual(n, int(children[n - 1]));
        const node = nodes[n].object;
        try std.testing.expectEqualStrings(name, node.get("name").?.string);
        try std.testing.expectEqual(n - 1, int(node.get("mesh").?));
        try std.testing.expectEqualStrings(name, meshes[n - 1].object.get("name").?.string);
    }

    // A ghost is a node without a name, before the model's
    const ghosted = try api.buildModel(std.testing.allocator, std.testing.io, "cube(1).ghost\ncube(2)", .{ .format = .glb });
    defer std.testing.allocator.free(ghosted);
    var with_ghost = try parseGlb(ghosted);
    defer with_ghost.deinit();
    const ghost_nodes = with_ghost.array("nodes");
    try std.testing.expectEqual(@as(usize, 3), ghost_nodes.len);
    try std.testing.expect(ghost_nodes[1].object.get("name") == null);
    try std.testing.expectEqualStrings("part_1", ghost_nodes[2].object.get("name").?.string);
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
        const needed = (count - 1) * stride + elem; // accessors start at their view (byteOffset 0)
        try std.testing.expect(a.object.get("byteOffset") == null);
        try std.testing.expect(needed <= int(view.get("byteLength").?));
    }
    const prims = try allPrimitives(glb);
    defer std.testing.allocator.free(prims);
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
    const prims = try allPrimitives(glb);
    defer std.testing.allocator.free(prims);
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
        const bytes = try api.buildModel(std.testing.allocator, std.testing.io, source, .{ .format = .glb, .draco = use_draco });
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
        if (use_draco) try expectOwnPositionsPerPrimitive(&glb);
    }
}

/// Under Draco each primitive is decoded on its own, so each needs a POSITION accessor
/// counting its own vertices, with their bounds. Every primitive used to point at one
/// accessor with the total count, which no decoder accepts for a multi-part model.
fn expectOwnPositionsPerPrimitive(glb: *const Glb) !void {
    const accessors = glb.array("accessors");
    const prims = try allPrimitives(glb);
    defer std.testing.allocator.free(prims);
    var total: usize = 0;
    for (prims, 0..) |p, i| {
        const pos = int(p.object.get("attributes").?.object.get("POSITION").?);
        for (prims[0..i]) |earlier| try std.testing.expect(int(earlier.object.get("attributes").?.object.get("POSITION").?) != pos);
        const accessor = accessors[pos].object;
        try std.testing.expect(accessor.get("bufferView") == null); // compressed: no view of its own
        total += int(accessor.get("count").?);
        const min = accessor.get("min").?.array.items;
        const max = accessor.get("max").?.array.items;
        for (min, max) |lo, hi| try std.testing.expect(number(lo) <= number(hi));
    }
    // The two single cubes have 8 vertices each; the union's two primitives share none.
    try std.testing.expectEqual(@as(usize, 8), int(accessors[int(prims[0].object.get("attributes").?.object.get("POSITION").?)].object.get("count").?));
    try std.testing.expect(total > 16);
}

fn number(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => unreachable,
    };
}

test "GLTF: a model without materials uses only the default material" {
    const bytes = try api.buildModel(std.testing.allocator, std.testing.io, "[cube(1), sphere(1).translate(x: 3)]", .{ .format = .glb });
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
        const json_bytes = try api.buildModel(std.testing.allocator, std.testing.io, source, .{ .format = .gltf, .draco = use_draco });
        defer std.testing.allocator.free(json_bytes);
        try std.testing.expectEqual(@as(u8, '{'), json_bytes[0]);
        var bin: []u8 = &.{};
        defer std.testing.allocator.free(bin);
        var doc = try parseGltfJson(json_bytes, &bin);
        defer doc.deinit();
        try expectValidLayout(&doc);

        const glb_bytes = try api.buildModel(std.testing.allocator, std.testing.io, source, .{ .format = .glb, .draco = use_draco });
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
    const bytes = try api.buildModel(std.testing.allocator, std.testing.io, "cube(10)", .{ .format = .glb });
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

    const mesh_part = try dag_evaluator.evaluateDAG(&vm, try vm.dag_builder.addCube(10.0, 10.0, 10.0, true));
    try vm.setConfig(.{ .engine = .brep_native });
    const brep_part = try dag_evaluator.evaluateDAG(&vm, try vm.dag_builder.addCube(10.0, 10.0, 10.0, true));

    const parts = [_]MeshPart{ .{ .handle = mesh_part }, .{ .handle = brep_part } };
    try std.testing.expectError(error.EngineCannotTessellate, gltf.buildGltfBuffer(std.testing.allocator, vm.materials.items, &parts, null, .glb));
}

/// The bytes of buffer view `index`.
fn viewBytes(glb: *const Glb, index: usize) []const u8 {
    const view = glb.array("bufferViews")[index].object;
    const offset = if (view.get("byteOffset")) |o| int(o) else 0;
    return glb.bin[offset..][0..int(view.get("byteLength").?)];
}

test "GLTF: the primitives of an export close every part" {
    // A part split by material is several primitives over its one set of vertices.
    const bytes = try api.buildModel(std.testing.allocator, std.testing.io, PARTS_SOURCE, .{ .format = .glb });
    defer std.testing.allocator.free(bytes);
    var glb = try parseGlb(bytes);
    defer glb.deinit();
    const accessors = glb.array("accessors");
    const positions = std.mem.bytesAsSlice(f32, viewBytes(&glb, int(accessors[0].object.get("bufferView").?)));
    var indices: std.ArrayList(u32) = .empty;
    defer indices.deinit(std.testing.allocator);
    const prims = try allPrimitives(&glb);
    defer std.testing.allocator.free(prims);
    for (prims) |p| {
        const view = int(accessors[int(p.object.get("indices").?)].object.get("bufferView").?);
        for (std.mem.bytesAsSlice(u32, viewBytes(&glb, view))) |i| try indices.append(std.testing.allocator, i);
    }
    const triangles = try mesh_check.weld(std.testing.allocator, @alignCast(positions), indices.items);
    defer std.testing.allocator.free(triangles);
    try mesh_check.expectClosed(std.testing.allocator, triangles);
}

test "GLTF: Draco quantizes positions to the bits the export asks for" {
    // The bits were fixed at 14 whatever the part or the use
    const support = @import("../../test_support.zig");
    var vm = try support.initVm();
    defer vm.deinit();
    try std.testing.expectEqual(.ok, try support.runOn(&vm, "sphere(r: 10, segments: 96)"));
    for ([_]u8{ 6, 20 }) |bits| {
        errdefer std.debug.print("bits: {d}\n", .{bits});
        const bytes = try api.exportModelFromVm(std.testing.allocator, &vm, .glb, .{ .draco = true, .draco_bits = bits });
        defer std.testing.allocator.free(bytes);
        var glb = try parseGlb(bytes);
        defer glb.deinit();
        const prims = try allPrimitives(&glb);
        defer std.testing.allocator.free(prims);
        const ext = prims[0].object.get("extensions").?.object.get("KHR_draco_mesh_compression").?.object;
        const mesh = try draco.decodeMesh(std.testing.allocator, viewBytes(&glb, int(ext.get("bufferView").?)));
        defer mesh.deinit(std.testing.allocator);
        // The distinct x positions: on a grid of 2^bits steps at most
        const xs = try std.testing.allocator.alloc(f32, mesh.positions.len / 3);
        defer std.testing.allocator.free(xs);
        for (xs, 0..) |*x, v| x.* = mesh.positions[3 * v];
        std.mem.sort(f32, xs, {}, std.sort.asc(f32));
        var distinct: usize = 1;
        for (xs[1..], xs[0 .. xs.len - 1]) |x, before| distinct += @intFromBool(x != before);
        if (bits == 6) try std.testing.expect(distinct <= 64) else try std.testing.expect(distinct > 64);
    }
}

test "GLTF: each Draco primitive decodes to the mesh its accessors describe" {
    // Only the JSON around the compressed buffers was checked; nothing decoded them.
    const plain_bytes = try api.buildModel(std.testing.allocator, std.testing.io, PARTS_SOURCE, .{ .format = .glb });
    defer std.testing.allocator.free(plain_bytes);
    var plain = try parseGlb(plain_bytes);
    defer plain.deinit();
    const bytes = try api.buildModel(std.testing.allocator, std.testing.io, PARTS_SOURCE, .{ .format = .glb, .draco = true });
    defer std.testing.allocator.free(bytes);
    var glb = try parseGlb(bytes);
    defer glb.deinit();

    const accessors = glb.array("accessors");
    const prims = try allPrimitives(&glb);
    defer std.testing.allocator.free(prims);
    const plain_prims = try allPrimitives(&plain);
    defer std.testing.allocator.free(plain_prims);
    try std.testing.expectEqual(plain_prims.len, prims.len);
    for (prims, plain_prims, 0..) |p, plain_p, n| {
        errdefer std.debug.print("primitive {d}\n", .{n});
        const ext = p.object.get("extensions").?.object.get("KHR_draco_mesh_compression").?.object;
        const mesh = try draco.decodeMesh(std.testing.allocator, viewBytes(&glb, int(ext.get("bufferView").?)));
        defer mesh.deinit(std.testing.allocator);

        const position = accessors[int(p.object.get("attributes").?.object.get("POSITION").?)].object;
        try std.testing.expectEqual(int(position.get("count").?), mesh.positions.len / 3);
        try std.testing.expectEqual(int(accessors[int(p.object.get("indices").?)].object.get("count").?), mesh.indices.len);
        // As many triangles as the uncompressed primitive.
        try std.testing.expectEqual(int(plain.array("accessors")[int(plain_p.object.get("indices").?)].object.get("count").?), mesh.indices.len);
        for (mesh.indices) |i| try std.testing.expect(i < mesh.positions.len / 3);
        // Within the bounds the accessor declares, give or take the quantization step.
        const min = position.get("min").?.array.items;
        const max = position.get("max").?.array.items;
        for (0..mesh.positions.len / 3) |v| {
            for (0..3) |k| {
                const c: f64 = mesh.positions[v * 3 + k];
                const slack = (number(max[k]) - number(min[k])) * 1e-3 + 1e-6;
                try std.testing.expect(c >= number(min[k]) - slack and c <= number(max[k]) + slack);
            }
        }
    }
    // The first two parts are a primitive each, whole, so each decodes closed.
    for (prims[0..2]) |p| {
        const ext = p.object.get("extensions").?.object.get("KHR_draco_mesh_compression").?.object;
        const mesh = try draco.decodeMesh(std.testing.allocator, viewBytes(&glb, int(ext.get("bufferView").?)));
        defer mesh.deinit(std.testing.allocator);
        const triangles = try mesh_check.weld(std.testing.allocator, mesh.positions, mesh.indices);
        defer std.testing.allocator.free(triangles);
        try mesh_check.expectClosed(std.testing.allocator, triangles);
    }
}

test "GLTF: a colour's base factor is its sRGB bytes decoded by the sRGB curve, as viewers encode it back" {
    // A gamma of 2.2 came near: `#cc3333` was 0.612 for 0.8, which a viewer showed as `#cd3030`
    const source =
        \\[cube(1).material(color: "#cc3333"), cube(1).translate(x: 3).material(color: "#050505")]
    ;
    const bytes = try api.buildModel(std.testing.allocator, std.testing.io, source, .{ .format = .glb });
    defer std.testing.allocator.free(bytes);
    var glb = try parseGlb(bytes);
    defer glb.deinit();
    const materials = glb.array("materials");
    // 0.8 above the knee: ((0.8 + 0.055) / 1.055) ^ 2.4; 0.2 too; 5/255 below it: linear
    const mid = std.math.pow(f64, (0.8 + 0.055) / 1.055, 2.4);
    const low = std.math.pow(f64, (0.2 + 0.055) / 1.055, 2.4);
    try expectNumbers(&.{ mid, low, low, 1 }, pbr(materials[1].object).get("baseColorFactor").?);
    const dark = 5.0 / 255.0 / 12.92;
    try expectNumbers(&.{ dark, dark, dark, 1 }, pbr(materials[2].object).get("baseColorFactor").?);
}

test "GLTF: each material keeps its colour, finish, transparency and role" {
    const source =
        \\shiny = cube(2).material(color: "#FF0000", metallic: 0.5, roughness: 0.2)
        \\clear = sphere(1).translate(x: 5).material(color: "#00FF00", alpha: 0.5)
        \\glass = cylinder(r: 1, h: 2).translate(x: 10).material(color: "#FFFFFF", transmission: 0.8)
        \\lit = cube(1).translate(y: 5).highlight
        \\cube(1).translate(y: 10).ghost
        \\[shiny, clear, glass, lit]
    ;
    const bytes = try api.buildModel(std.testing.allocator, std.testing.io, source, .{ .format = .glb });
    defer std.testing.allocator.free(bytes);
    var glb = try parseGlb(bytes);
    defer glb.deinit();
    const materials = glb.array("materials");
    // The default first, then one per material(...), highlight and ghost, in call order.
    try std.testing.expectEqual(@as(usize, 6), materials.len);

    const shiny = materials[1].object;
    try expectNumbers(&.{ 1, 0, 0, 1 }, pbr(shiny).get("baseColorFactor").?);
    try std.testing.expectEqual(@as(f64, 0.5), number(pbr(shiny).get("metallicFactor").?));
    try std.testing.expectEqual(@as(f64, 0.2), number(pbr(shiny).get("roughnessFactor").?));
    try std.testing.expectEqualStrings("OPAQUE", shiny.get("alphaMode").?.string);

    const clear = materials[2].object;
    try expectNumbers(&.{ 0, 1, 0, 0.5 }, pbr(clear).get("baseColorFactor").?);
    try std.testing.expectEqualStrings("BLEND", clear.get("alphaMode").?.string);

    const glass = materials[3].object;
    const ext = glass.get("extensions").?.object;
    try std.testing.expectEqual(@as(f64, 0.8), number(ext.get("KHR_materials_transmission").?.object.get("transmissionFactor").?));
    try std.testing.expectEqual(@as(f64, 1.5), number(ext.get("KHR_materials_ior").?.object.get("ior").?));
    try std.testing.expectEqualStrings("OPAQUE", glass.get("alphaMode").?.string);
    var used: usize = 0;
    for (glb.array("extensionsUsed")) |name| {
        if (std.mem.startsWith(u8, name.string, "KHR_materials_")) used += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), used);

    try std.testing.expectEqualStrings("highlight", materials[4].object.get("extras").?.object.get("kupcad_role").?.string);
    const ghost = materials[5].object;
    try std.testing.expectEqualStrings("ghost", ghost.get("extras").?.object.get("kupcad_role").?.string);
    try std.testing.expectEqualStrings("BLEND", ghost.get("alphaMode").?.string);
}

fn pbr(material: std.json.ObjectMap) std.json.ObjectMap {
    return material.get("pbrMetallicRoughness").?.object;
}

fn expectNumbers(expected: []const f64, actual: std.json.Value) !void {
    const items = actual.array.items;
    try std.testing.expectEqual(expected.len, items.len);
    for (expected, items) |e, a| try std.testing.expectApproxEqAbs(e, number(a), 1e-12);
}
