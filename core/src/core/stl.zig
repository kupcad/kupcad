const std = @import("std");
const value = @import("value.zig");

// Helper to write a 32-bit float safely across endianness
fn writeF32(writer: anytype, f: f32) !void {
    try writer.writeInt(u32, @as(u32, @bitCast(f)), .little);
}

pub fn write(mesh: *const value.ObjMesh, writer: anytype) !void {
    // 1. Header (80 bytes)
    var header: [80]u8 = [_]u8{0} ** 80;
    const title = "KupCAD Binary STL Export";
    @memcpy(header[0..title.len], title);
    try writer.writeAll(&header);

    // 2. Total Triangle Count (u32, little-endian)
    try writer.writeInt(u32, @intCast(mesh.faces.len), .little);

    // 3. Write each face (50 bytes each)
    for (mesh.faces) |face| {
        const v1 = mesh.vertices[face[0]];
        const v2 = mesh.vertices[face[1]];
        const v3 = mesh.vertices[face[2]];

        // Calculate Surface Normal using the Cross Product
        const ux = v2.x - v1.x;
        const uy = v2.y - v1.y;
        const uz = v2.z - v1.z;

        const vx = v3.x - v1.x;
        const vy = v3.y - v1.y;
        const vz = v3.z - v1.z;

        const nx = uy * vz - uz * vy;
        const ny = uz * vx - ux * vz;
        const nz = ux * vy - uy * vx;

        // Normalize the vector
        const len = @sqrt(nx * nx + ny * ny + nz * nz);
        var norm = value.Vec3{ .x = 0, .y = 0, .z = 0 };
        if (len > 0.000001) {
            norm.x = nx / len;
            norm.y = ny / len;
            norm.z = nz / len;
        }

        // Write Normal (3x f32)
        try writeF32(writer, norm.x);
        try writeF32(writer, norm.y);
        try writeF32(writer, norm.z);

        // Write Vertices (9x f32)
        try writeF32(writer, v1.x);
        try writeF32(writer, v1.y);
        try writeF32(writer, v1.z);

        try writeF32(writer, v2.x);
        try writeF32(writer, v2.y);
        try writeF32(writer, v2.z);

        try writeF32(writer, v3.x);
        try writeF32(writer, v3.y);
        try writeF32(writer, v3.z);

        // Write Attribute Catch (u16)
        try writer.writeInt(u16, 0, .little);
    }
}
