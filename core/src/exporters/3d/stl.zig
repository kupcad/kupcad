//! STL: `buildStlBuffer` writes a solid as binary STL, `buildStlOfParts` several as their
//! union (STL holds one mesh), and `parseStlBuffer` reads binary or ASCII STL into a mesh with
//! repeated vertices merged, or says what is wrong with it (a Diagnostic naming the line of
//! an ASCII file, as obj_read does). The script's `export_stl` and `import_stl` are in
//! stdlib/files.zig.

const std = @import("std");
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../core/geometry_handle.zig");
const byte_order_mark = @import("../../core/byte_order_mark.zig");
const imported_mesh = @import("imported_mesh.zig");
const Mesh = imported_mesh.Mesh;
const Builder = imported_mesh.Builder;
pub const Diagnostic = @import("../diagnostic.zig").Diagnostic;

// Binary STL: an 80-byte header and a little-endian u32 triangle count, then per triangle
// a 50-byte record: the normal and three vertices as f32, and a u16 attribute count.
const HEADER_LEN = 80;
const PREAMBLE_LEN = HEADER_LEN + 4;
const RECORD_LEN = 50;
const HEADER_TITLE = "KupCAD Export";
/// The words of an ASCII STL that only frame what it holds (a facet's normal is
/// recomputed, so `facet normal` is read as the facet's start alone).
const FRAMING = std.StaticStringMap(void).initComptime(.{ .{"solid"}, .{"endsolid"}, .{"outer"}, .{"endloop"} });

pub const Error = error{Unreadable} || std.mem.Allocator.Error;

/// Reads binary or ASCII STL, merging repeated vertices; error.Unreadable, `diag` saying
/// why, for a file that is neither. A buffer is binary when its triangle count fits it
/// (bytes after them are left, and so is a header that starts with "solid", as some writers
/// put there); the count is checked in usize, so a huge count can't wrap the length check
/// (in u32, 85_899_346 * 50 wraps to 4).
pub fn parseStlBuffer(allocator: std.mem.Allocator, data: []const u8, diag: *Diagnostic) Error!Mesh {
    if (data.len >= PREAMBLE_LEN) {
        const num_tris = std.mem.readInt(u32, data[HEADER_LEN..PREAMBLE_LEN], .little);
        // Text has no NUL bytes: four of them where the count goes are a binary STL's
        if (num_tris == 0) return diag.fail("it is a binary STL of no triangles", .{});
        if ((data.len - PREAMBLE_LEN) / RECORD_LEN >= num_tris) return parseBinaryStl(allocator, data, num_tris, diag);
    }
    const text = std.mem.trimStart(u8, byte_order_mark.skip(data), &std.ascii.whitespace);
    if (!std.mem.startsWith(u8, text, "solid")) {
        if (data.len < PREAMBLE_LEN) return diag.fail("it isn't STL: too short for a binary STL ({d} bytes at least) and not ASCII STL (which starts with \"solid\")", .{PREAMBLE_LEN});
        return diag.fail("it isn't STL: as binary STL its header counts {d} triangles, and the {d} bytes after it hold {d}; as ASCII STL it doesn't start with \"solid\"", .{ std.mem.readInt(u32, data[HEADER_LEN..PREAMBLE_LEN], .little), data.len - PREAMBLE_LEN, (data.len - PREAMBLE_LEN) / RECORD_LEN });
    }
    return parseAsciiStl(allocator, data, diag);
}

fn parseBinaryStl(allocator: std.mem.Allocator, data: []const u8, num_tris: u32, diag: *Diagnostic) Error!Mesh {
    var mesh: Builder = .{};
    errdefer mesh.deinit(allocator);
    try mesh.faces.ensureTotalCapacity(allocator, num_tris);
    var offset: usize = PREAMBLE_LEN;
    for (0..num_tris) |t| {
        // Past the normal, three vertices of three f32 each
        offset += 12;
        var corners: [3]u32 = undefined;
        for (&corners) |*corner| {
            var p: [3]f64 = undefined;
            for (&p) |*c| {
                c.* = @as(f32, @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little)));
                offset += 4;
            }
            corner.* = mesh.point(allocator, p) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NonFiniteVertex => return diag.fail("triangle {d}: a vertex coordinate isn't finite", .{t + 1}),
            };
        }
        offset += 2;
        mesh.faces.appendAssumeCapacity(corners);
    }
    return mesh.finish(allocator);
}

/// An ASCII STL, facet by facet: each `facet` to its `endfacet` a triangle of the three
/// `vertex` lines in its loop. What doesn't read so is an error naming its line; a vertex
/// that wasn't read was skipped, so every corner after it shifted into the wrong triangle.
fn parseAsciiStl(allocator: std.mem.Allocator, data: []const u8, diag: *Diagnostic) Error!Mesh {
    var mesh: Builder = .{};
    errdefer mesh.deinit(allocator);
    var lines = std.mem.splitScalar(u8, byte_order_mark.skip(data), '\n');
    var number: usize = 0;
    // The line the facet being read starts on, and its corners so far
    var facet: ?usize = null;
    var corners: [3]u32 = undefined;
    var count: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const keyword = words.next() orelse continue;
        if (std.mem.eql(u8, keyword, "facet")) {
            if (facet) |start| return diag.fail("line {d}: a facet starts before the one on line {d} ends (endfacet)", .{ number, start });
            facet = number;
            count = 0;
        } else if (std.mem.eql(u8, keyword, "vertex")) {
            const start = facet orelse return diag.fail("line {d}: a vertex outside a facet", .{number});
            if (count == corners.len) return diag.fail("line {d}: the facet on line {d} has more than 3 vertices: an STL facet is a triangle", .{ number, start });
            var p: [3]f64 = undefined;
            for (&p) |*c| {
                const word = words.next() orelse return diag.fail("line {d}: a vertex needs its x, y and z", .{number});
                // Read as the f32 a binary STL holds, so both merge alike
                const f = std.fmt.parseFloat(f32, word) catch return diag.fail("line {d}: the vertex coordinate \"{s}\" isn't a number", .{ number, word });
                if (!std.math.isFinite(f)) return diag.fail("line {d}: the vertex coordinate \"{s}\" isn't finite as the 32-bit float STL holds", .{ number, word });
                c.* = f;
            }
            if (words.next()) |extra| return diag.fail("line {d}: a vertex has more than its x, y and z: \"{s}\"", .{ number, extra });
            corners[count] = mesh.point(allocator, p) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NonFiniteVertex => unreachable, // read finite
            };
            count += 1;
        } else if (std.mem.eql(u8, keyword, "endfacet")) {
            const start = facet orelse return diag.fail("line {d}: an endfacet ends no facet", .{number});
            if (count != corners.len) return diag.fail("line {d}: the facet on line {d} has {d} vertices: an STL facet is a triangle", .{ number, start, count });
            try mesh.triangle(allocator, corners);
            facet = null;
        } else if (!FRAMING.has(keyword)) {
            return diag.fail("line {d}: \"{s}\" isn't a word of ASCII STL", .{ number, keyword[0..@min(keyword.len, 40)] });
        }
    }
    if (facet) |start| return diag.fail("the facet on line {d} doesn't end (endfacet)", .{start});
    if (mesh.faces.items.len == 0) return diag.fail("it has no facet", .{});
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
