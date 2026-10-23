//! OBJ import: `read` reads a Wavefront OBJ file's faces as meshes, one per object (`o`,
//! as obj.zig writes a part each; the faces before any `o` are one of their own), its
//! vertices in millimetres (OBJ has no unit; obj.zig writes millimetres). A vertex is
//! `v x y z` (what follows, a weight or a colour, left out); a face (`f`) names its
//! corners by their vertices' numbers, from 1, or back from the last vertex read for a
//! negative one, each with its texture and normal numbers after slashes left out; a face of
//! more than three corners is cut into triangles by core/triangulate.zig, and one with no
//! area is left out. A line ending in a backslash goes on on the next, and `#` starts a
//! comment. What isn't a face (points, lines, curves and surfaces, texture coordinates,
//! normals, groups, smoothing and materials) is left out. The writer is obj.zig.

const std = @import("std");
const imported_mesh = @import("imported_mesh.zig");
const triangulate = @import("../../core/triangulate.zig");
const vec3 = @import("../../core/vec3.zig");
const limits = @import("../../core/limits.zig");
pub const Diagnostic = @import("../diagnostic.zig").Diagnostic;

/// The name of the object the faces before any `o` are in.
const UNNAMED = "";

/// An object of the file: its name (`o`'s; empty for the faces before any) and its mesh.
pub const Object = struct { name: []const u8, mesh: imported_mesh.Mesh };

/// The objects read that have a face, in the file's order, owned by `arena`.
pub const Model = struct {
    objects: []Object,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Model) void {
        self.arena.deinit();
    }
};

pub const Error = error{Unreadable} || std.mem.Allocator.Error;

/// A face as the file gives it: its object, its corners (indices into the vertices, a
/// positive number's not yet checked against how many there are) and its line.
const Face = struct { object: usize, corners: []const u32, line: usize };

/// The objects of the OBJ `text`.
pub fn read(allocator: std.mem.Allocator, text: []const u8, diag: *Diagnostic) Error!Model {
    var model = Model{ .objects = &.{}, .arena = .init(allocator) };
    errdefer model.deinit();
    const arena = model.arena.allocator();

    var vertices: std.ArrayList([3]f64) = .empty;
    var faces: std.ArrayList(Face) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var lines = Lines{ .text = text, .arena = arena };
    while (try lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line.text, " \t");
        const keyword = words.next() orelse continue;
        if (std.mem.eql(u8, keyword, "v")) {
            var p: [3]f64 = undefined;
            for (&p) |*c| {
                const word = words.next() orelse return diag.fail("line {d}: a vertex needs its x, y and z", .{line.number});
                c.* = std.fmt.parseFloat(f64, word) catch return diag.fail("line {d}: the vertex coordinate \"{s}\" isn't a number", .{ line.number, word });
                if (!std.math.isFinite(c.*)) return diag.fail("line {d}: the vertex coordinate \"{s}\" isn't finite", .{ line.number, word });
            }
            try vertices.append(arena, p);
        } else if (std.mem.eql(u8, keyword, "o")) {
            try names.append(arena, std.mem.trim(u8, line.text[keyword.len..], " \t"));
        } else if (std.mem.eql(u8, keyword, "f")) {
            if (names.items.len == 0) try names.append(arena, UNNAMED);
            var corners: std.ArrayList(u32) = .empty;
            while (words.next()) |word| {
                if (corners.items.len == limits.MAX_FACE_CORNERS) return diag.fail("line {d}: a face has more than {d} corners", .{ line.number, limits.MAX_FACE_CORNERS });
                try corners.append(arena, try cornerOf(word, vertices.items.len, line.number, diag));
            }
            if (corners.items.len < 3) return diag.fail("line {d}: a face needs at least 3 corners, got {d}", .{ line.number, corners.items.len });
            try faces.append(arena, .{ .object = names.items.len - 1, .corners = corners.items, .line = line.number });
        }
    }
    for (faces.items) |face| for (face.corners) |corner| {
        if (corner >= vertices.items.len) return diag.fail("line {d}: a face names vertex {d}, and the file has {d}", .{ face.line, @as(u64, corner) + 1, vertices.items.len });
    };

    var objects: std.ArrayList(Object) = .empty;
    var first: usize = 0;
    for (names.items, 0..) |name, index| {
        // The faces are in their objects' order: this one's run on to the next object's
        var end = first;
        while (end < faces.items.len and faces.items[end].object == index) end += 1;
        defer first = end;
        if (end == first) continue;
        try objects.append(arena, .{ .name = name, .mesh = try meshOf(arena, vertices.items, faces.items[first..end], diag) });
    }
    if (objects.items.len == 0) return diag.fail("it has no faces", .{});
    model.objects = objects.items;
    return model;
}

/// The vertex index of the face corner `word` (`v`, `v/vt`, `v/vt/vn` or `v//vn`), when
/// `count` vertices have been read.
fn cornerOf(word: []const u8, count: usize, line: usize, diag: *Diagnostic) error{Unreadable}!u32 {
    const number = word[0 .. std.mem.findScalar(u8, word, '/') orelse word.len];
    const n = std.fmt.parseInt(i64, number, 10) catch return diag.fail("line {d}: the face corner \"{s}\" isn't a vertex's number", .{ line, word });
    if (n == 0) return diag.fail("line {d}: a face names vertex 0; they count from 1", .{line});
    // A negative number counts back from the last vertex read
    const index = if (n > 0) n - 1 else @as(i64, @intCast(count)) + n;
    if (index < 0) return diag.fail("line {d}: a face names vertex {d}, back past the first of the {d} read", .{ line, n, count });
    if (index > std.math.maxInt(u32)) return diag.fail("line {d}: a face names vertex {d}, past the most a mesh holds", .{ line, n });
    return @intCast(index);
}

/// The mesh of `faces`, its points those of `vertices` they name (each once).
fn meshOf(arena: std.mem.Allocator, vertices: []const [3]f64, faces: []const Face, diag: *Diagnostic) Error!imported_mesh.Mesh {
    var mesh: imported_mesh.Builder = .{};
    var corners: std.ArrayList(u32) = .empty;
    for (faces) |face| {
        corners.clearRetainingCapacity();
        for (face.corners) |corner| {
            const index = mesh.point(arena, vertices[corner]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NonFiniteVertex => unreachable, // read finite
            };
            // A corner on the one before it (or a repeated vertex) adds nothing
            if (corners.items.len > 0 and corners.items[corners.items.len - 1] == index) continue;
            try corners.append(arena, index);
        }
        if (corners.items.len > 1 and corners.items[0] == corners.items[corners.items.len - 1]) _ = corners.pop();
        if (corners.items.len < 3) continue;
        if (corners.items.len == 3 and noArea(mesh.points.items, corners.items[0..3].*)) continue;
        triangulate.face(arena, mesh.points.items, corners.items, &mesh.faces) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // No area: nothing of the surface
            error.Degenerate => {},
            error.SelfIntersecting => return diag.fail("line {d}: a face's outline crosses itself", .{face.line}),
        };
    }
    return mesh.finish(arena);
}

/// Whether the triangle of `points` at `corners` has its corners in a line.
fn noArea(points: []const [3]f64, corners: [3]u32) bool {
    const a = points[corners[0]];
    const n = vec3.cross(vec3.sub(points[corners[1]], a), vec3.sub(points[corners[2]], a));
    return vec3.dot(n, n) == 0;
}

/// The file's lines, a line ending in a backslash joined to the next, without comments.
const Lines = struct {
    text: []const u8,
    arena: std.mem.Allocator,
    pos: usize = 0,
    number: usize = 0,

    const Line = struct { text: []const u8, number: usize };

    fn next(self: *Lines) !?Line {
        if (self.pos >= self.text.len) return null;
        var joined: std.ArrayList(u8) = .empty;
        const first = self.number + 1;
        while (self.pos < self.text.len) {
            const end = std.mem.findScalarPos(u8, self.text, self.pos, '\n') orelse self.text.len;
            var line = std.mem.trimEnd(u8, self.text[self.pos..end], "\r");
            self.pos = end + 1;
            self.number += 1;
            if (std.mem.findScalar(u8, line, '#')) |hash| line = line[0..hash];
            const goes_on = std.mem.endsWith(u8, line, "\\");
            if (!goes_on and joined.items.len == 0) return .{ .text = line, .number = first };
            try joined.appendSlice(self.arena, if (goes_on) line[0 .. line.len - 1] else line);
            if (!goes_on) break;
            try joined.append(self.arena, ' ');
        }
        return .{ .text = joined.items, .number = first };
    }
};
