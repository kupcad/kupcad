//! STL: `buildStlBuffer` writes a solid as binary STL, `buildStlOfParts` several as their
//! union (STL holds one mesh), and `parseStlBuffer` reads binary or ASCII STL into a mesh with
//! repeated vertices merged. The script's `export_stl` and `import_stl` are in stdlib/files.zig.

const std = @import("std");
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../core/geometry_handle.zig");
const imported_mesh = @import("imported_mesh.zig");
const Mesh = imported_mesh.Mesh;
const Builder = imported_mesh.Builder;

// Binary STL: an 80-byte header and a little-endian u32 triangle count, then per triangle
// a 50-byte record: the normal and three vertices as f32, and a u16 attribute count.
const HEADER_LEN = 80;
const PREAMBLE_LEN = HEADER_LEN + 4;
const RECORD_LEN = 50;
const HEADER_TITLE = "KupCAD Export";

/// Reads binary or ASCII STL, merging repeated vertices. A buffer is binary when its
/// triangle count fits it; the count is checked in usize, so a huge count can't wrap the
/// length check (in u32, 85_899_346 * 50 wraps to 4).
pub fn parseStlBuffer(allocator: std.mem.Allocator, data: []const u8) !Mesh {
    if (data.len >= PREAMBLE_LEN) {
        const num_tris = std.mem.readInt(u32, data[HEADER_LEN..PREAMBLE_LEN], .little);
        if (num_tris > 0 and (data.len - PREAMBLE_LEN) / RECORD_LEN >= num_tris) {
            return parseBinaryStl(allocator, data, num_tris);
        }
    }
    return parseAsciiStl(allocator, data);
}

fn parseBinaryStl(allocator: std.mem.Allocator, data: []const u8, num_tris: u32) !Mesh {
    var mesh: Builder = .{};
    errdefer mesh.deinit(allocator);
    try mesh.faces.ensureTotalCapacity(allocator, num_tris);
    var offset: usize = PREAMBLE_LEN;
    for (0..num_tris) |_| {
        // Past the normal, three vertices of three f32 each
        offset += 12;
        var corners: [3]u32 = undefined;
        for (&corners) |*corner| {
            var p: [3]f64 = undefined;
            for (&p) |*c| {
                c.* = @as(f32, @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little)));
                offset += 4;
            }
            corner.* = try mesh.point(allocator, p);
        }
        offset += 2;
        mesh.faces.appendAssumeCapacity(corners);
    }
    return mesh.finish(allocator);
}

fn parseAsciiStl(allocator: std.mem.Allocator, data: []const u8) !Mesh {
    var mesh: Builder = .{};
    errdefer mesh.deinit(allocator);
    var lines = std.mem.tokenizeAny(u8, data, "\r\n");
    var corners: [3]u32 = undefined;
    var count: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "vertex")) continue;
        var tokens = std.mem.tokenizeAny(u8, trimmed[6..], " \t");
        var p: [3]f64 = undefined;
        for (&p) |*c| {
            // Read as the f32 a binary STL holds, so both merge alike
            c.* = std.fmt.parseFloat(f32, tokens.next() orelse break) catch break;
        } else {
            corners[count] = try mesh.point(allocator, p);
            count += 1;
            if (count == 3) {
                try mesh.triangle(allocator, corners);
                count = 0;
            }
        }
    }
    if (mesh.faces.items.len == 0) return error.InvalidStl;
    return mesh.finish(allocator);
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

/// The STL of `parts`: STL holds one mesh, so several parts are written as their union
/// (error.UnionFailed when the kernel can't make it). Their engine must tessellate, and
/// for several parts unite (kernel.supports), which the caller checks.
pub fn buildStlOfParts(allocator: std.mem.Allocator, parts: []const geom.GeometryHandle) ![]const u8 {
    switch (parts.len) {
        0 => return error.NoGeometry,
        1 => return buildStlBuffer(allocator, parts[0]),
        else => {
            const united = kernel.batchBoolean(allocator, parts, .union_op) orelse return error.UnionFailed;
            defer kernel.destruct(united);
            return buildStlBuffer(allocator, united);
        },
    }
}
