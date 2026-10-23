//! STL: `buildStlBuffer` writes a solid as binary STL, `buildStlOfParts` several as their
//! union (STL holds one mesh), and `parseStlBuffer` reads binary or ASCII STL into a mesh with
//! repeated vertices merged. The script's `export_stl` and `import_stl` are in stdlib/files.zig.

const std = @import("std");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../core/geometry_handle.zig");
const error_kind = @import("../../vm/error_kind.zig");

// Binary STL: an 80-byte header and a little-endian u32 triangle count, then per triangle
// a 50-byte record: the normal and three vertices as f32, and a u16 attribute count.
const HEADER_LEN = 80;
const PREAMBLE_LEN = HEADER_LEN + 4;
const RECORD_LEN = 50;
const HEADER_TITLE = "KupCAD Export";

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

/// Reads binary or ASCII STL, merging repeated vertices. A buffer is binary when its
/// triangle count fits it; the count is checked in usize, so a huge count can't wrap the
/// length check (in u32, 85_899_346 * 50 wraps to 4).
pub fn parseStlBuffer(allocator: std.mem.Allocator, data: []const u8) !StlMesh {
    if (data.len >= PREAMBLE_LEN) {
        const num_tris = std.mem.readInt(u32, data[HEADER_LEN..PREAMBLE_LEN], .little);
        if (num_tris > 0 and (data.len - PREAMBLE_LEN) / RECORD_LEN >= num_tris) {
            return parseBinaryStl(allocator, data, num_tris);
        }
    }
    return parseAsciiStl(allocator, data);
}

/// The index of the vertex at `coords`, added unless an earlier triangle has it (merged by
/// bits, as the file wrote it). NaN or an infinity is error.NonFiniteVertex: the kernel
/// can't place it, and the mesh with it crashed the build (found by the importer fuzz test).
fn addVertex(allocator: std.mem.Allocator, points: *std.ArrayList([3]f64), point_map: *std.AutoHashMap(PointKey, u32), coords: [3]f32) !u32 {
    for (coords) |c| if (!std.math.isFinite(c)) return error.NonFiniteVertex;
    const gop = try point_map.getOrPut(.{ .x = @bitCast(coords[0]), .y = @bitCast(coords[1]), .z = @bitCast(coords[2]) });
    if (!gop.found_existing) {
        gop.value_ptr.* = @intCast(points.items.len);
        try points.append(allocator, .{ coords[0], coords[1], coords[2] });
    }
    return gop.value_ptr.*;
}

fn parseBinaryStl(allocator: std.mem.Allocator, data: []const u8, num_tris: u32) !StlMesh {
    var points = std.ArrayList([3]f64).empty;
    defer points.deinit(allocator);
    var faces = try allocator.alloc([3]u32, num_tris);
    errdefer allocator.free(faces);

    var point_map = std.AutoHashMap(PointKey, u32).init(allocator);
    defer point_map.deinit();

    var offset: usize = PREAMBLE_LEN;
    for (0..num_tris) |i| {
        offset += 12;

        var tri_indices: [3]u32 = undefined;
        for (0..3) |v| {
            const ix = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;
            const iy = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;
            const iz = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;

            tri_indices[v] = try addVertex(allocator, &points, &point_map, .{ @bitCast(ix), @bitCast(iy), @bitCast(iz) });
        }
        offset += 2;

        faces[i] = tri_indices;
    }

    return StlMesh{
        .points = try points.toOwnedSlice(allocator),
        .faces = faces,
    };
}

fn parseAsciiStl(allocator: std.mem.Allocator, data: []const u8) !StlMesh {
    var points = std.ArrayList([3]f64).empty;
    defer points.deinit(allocator);
    var faces = std.ArrayList([3]u32).empty;
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

            current_tri_indices[current_tri_verts] = try addVertex(allocator, &points, &point_map, .{ x, y, z });
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

/// Binary STL of `handle`, little-endian as the format requires on any host (bytes used
/// to be copied in native order). Normals are left zero; readers recompute them. An empty
/// solid is error.NoGeometry, as for glTF: it used to be an 84-byte file with no
/// triangles, which KupCAD's own importer rejects.
pub fn buildStlBuffer(allocator: std.mem.Allocator, handle: geom.GeometryHandle) ![]const u8 {
    if (!kernel.supports(handle.engine, .mesh)) return error.EngineCannotTessellate;
    const mesh = kernel.getMesh(allocator, handle) orelse return error.MeshExtractionFailed;
    defer allocator.free(mesh.vert_props);
    defer allocator.free(mesh.tri_verts);

    const tri_count = mesh.tri_verts.len / 3;
    if (tri_count == 0) return error.NoGeometry;
    const out = try allocator.alloc(u8, PREAMBLE_LEN + tri_count * RECORD_LEN);
    errdefer allocator.free(out);

    @memset(out[0..HEADER_LEN], 0);
    @memcpy(out[0..HEADER_TITLE.len], HEADER_TITLE);
    std.mem.writeInt(u32, out[HEADER_LEN..PREAMBLE_LEN], @intCast(tri_count), .little);

    for (0..tri_count) |t| {
        const record = out[PREAMBLE_LEN + t * RECORD_LEN ..][0..RECORD_LEN];
        @memset(record[0..12], 0); // normal
        for (0..3) |v| {
            const first = mesh.tri_verts[t * 3 + v] * mesh.num_prop;
            for (0..3) |axis| {
                const at = 12 + (v * 3 + axis) * 4;
                std.mem.writeInt(u32, record[at..][0..4], @bitCast(mesh.vert_props[first + axis]), .little);
            }
        }
        std.mem.writeInt(u16, record[48..50], 0, .little); // attribute byte count
    }
    return out;
}

/// The STL of `parts`: STL holds one mesh, so several parts are written as their union.
pub fn buildStlOfParts(allocator: std.mem.Allocator, vm: *VM, parts: []const geom.GeometryHandle) ![]const u8 {
    for (parts) |h| try vm.requireFeature(h.engine, .mesh);
    switch (parts.len) {
        0 => return error.NoGeometry,
        1 => return buildStlBuffer(allocator, parts[0]),
        else => {
            try vm.requireFeature(parts[0].engine, .boolean);
            const united = kernel.batchBoolean(allocator, parts, .union_op) orelse {
                return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"union"});
            };
            defer kernel.destruct(united);
            return buildStlBuffer(allocator, united);
        },
    }
}
