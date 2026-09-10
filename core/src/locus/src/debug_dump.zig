const std = @import("std");
const math = @import("math.zig");

pub const DebugDumper = struct {
    /// Dumps a raw 3D seam or point cloud to an OBJ file for Blender / VS Code viewing.
    pub fn dumpSeamToObj(filepath: []const u8, points_3d: []const math.Vec3) !void {
        var file = try std.fs.cwd().createFile(filepath, .{});
        defer file.close();
        var out = file.writer();

        // Write vertices
        for (points_3d) |pt| {
            try out.print("v {d:.6} {d:.6} {d:.6}\n", .{ pt[0], pt[1], pt[2] });
        }

        // Connect them as a continuous line
        try out.writeAll("l ");
        for (points_3d, 1..) |_, i| {
            try out.print("{} ", .{i});
        }
        try out.writeAll("\n");
    }

    /// Dumps parametric UV coordinates to an SVG file.
    /// Essential for visualizing p-curve loops and trimming constraints.
    pub fn dumpParametricToSvg(filepath: []const u8, uvs: []const math.Vec2, width: usize, height: usize) !void {
        var file = try std.fs.cwd().createFile(filepath, .{});
        defer file.close();
        var out = file.writer();

        try out.print(
            \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1" width="{}" height="{}">
            \\<rect width="1" height="1" fill="#1e1e1e" />
            \\<polyline fill="none" stroke="#007acc" stroke-width="0.005" points="
        , .{ width, height });

        for (uvs) |uv| {
            // Y inverted so (0,0) is bottom-left visually
            try out.print("{d:.6},{d:.6} ", .{ uv[0], 1.0 - uv[1] });
        }

        try out.writeAll("\" />\n</svg>");
    }
};
