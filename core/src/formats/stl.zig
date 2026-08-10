const std = @import("std");
const value = @import("../core/value.zig");

pub const StlData = struct {
    vertices: []value.Vec3,
    faces: [][3]u32,

    pub fn deinit(self: *StlData, allocator: std.mem.Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.faces);
    }
};

pub fn readBinary(allocator: std.mem.Allocator, data: []const u8) !StlData {
    if (data.len < 84) return error.InvalidStl;

    var offset: usize = 80; // Skip the 80-byte ASCII header

    const num_triangles = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;

    // 84 bytes header + 50 bytes per triangle
    if (data.len < 84 + num_triangles * 50) return error.InvalidStl;

    // A raw STL duplicates 3 vertices per triangle without indexing
    var vertices = std.ArrayListUnmanaged(value.Vec3).empty;
    try vertices.ensureTotalCapacity(allocator, num_triangles * 3);
    errdefer vertices.deinit(allocator);

    var faces = std.ArrayListUnmanaged([3]u32).empty;
    try faces.ensureTotalCapacity(allocator, num_triangles);
    errdefer faces.deinit(allocator);

    var i: u32 = 0;
    while (i < num_triangles) : (i += 1) {
        // Skip the normal vector (12 bytes) — Manifold/KupCAD will recalculate it anyway
        offset += 12;

        // Read the 3 vertices (each is 3x f32)
        const v1_x: f32 = @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little));
        offset += 4;
        const v1_y: f32 = @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little));
        offset += 4;
        const v1_z: f32 = @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little));
        offset += 4;

        const v2_x: f32 = @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little));
        offset += 4;
        const v2_y: f32 = @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little));
        offset += 4;
        const v2_z: f32 = @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little));
        offset += 4;

        const v3_x: f32 = @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little));
        offset += 4;
        const v3_y: f32 = @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little));
        offset += 4;
        const v3_z: f32 = @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little));
        offset += 4;

        // Skip the attribute byte count (2 bytes)
        offset += 2;

        const base_idx = @as(u32, @intCast(vertices.items.len));

        vertices.appendAssumeCapacity(.{ .x = v1_x, .y = v1_y, .z = v1_z });
        vertices.appendAssumeCapacity(.{ .x = v2_x, .y = v2_y, .z = v2_z });
        vertices.appendAssumeCapacity(.{ .x = v3_x, .y = v3_y, .z = v3_z });

        faces.appendAssumeCapacity(.{ base_idx, base_idx + 1, base_idx + 2 });
    }

    return StlData{
        .vertices = try vertices.toOwnedSlice(allocator),
        .faces = try faces.toOwnedSlice(allocator),
    };
}

// We use `anytype` for writer to perfectly duck-type whatever Io.Writer zig passes it
pub fn write(mesh: *value.ObjMesh, writer: anytype) !void {
    // 80-byte header
    var header: [80]u8 = [_]u8{0} ** 80;
    const title = "KupCAD Export";
    @memcpy(header[0..title.len], title);
    try writer.writeAll(&header);

    // Triangle count
    var count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_buf, @as(u32, @intCast(mesh.faces.len)), .little);
    try writer.writeAll(&count_buf);

    // Triangles
    var tri_buf: [50]u8 = undefined;
    for (mesh.faces) |face| {
        // Mock Normal (0,0,0) since Manifold drops it on export
        std.mem.writeInt(u32, tri_buf[0..4], 0, .little);
        std.mem.writeInt(u32, tri_buf[4..8], 0, .little);
        std.mem.writeInt(u32, tri_buf[8..12], 0, .little);

        // 3 Vertices (3x f32 each)
        var t_off: usize = 12;
        for (0..3) |i| {
            const v = mesh.vertices[face[i]];
            std.mem.writeInt(u32, tri_buf[t_off..][0..4], @bitCast(@as(f32, @floatCast(v.x))), .little);
            t_off += 4;
            std.mem.writeInt(u32, tri_buf[t_off..][0..4], @bitCast(@as(f32, @floatCast(v.y))), .little);
            t_off += 4;
            std.mem.writeInt(u32, tri_buf[t_off..][0..4], @bitCast(@as(f32, @floatCast(v.z))), .little);
            t_off += 4;
        }

        // Attribute byte count (usually 0)
        std.mem.writeInt(u16, tri_buf[48..50], 0, .little);

        try writer.writeAll(&tri_buf);
    }
}
