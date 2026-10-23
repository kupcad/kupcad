//! OBJ export: `build` writes a model as Wavefront OBJ, one `o` object per Solid, named
//! after its part in the parts list (stdlib/bom.zig) and numbered when the part has several
//! copies. The vertices are in millimetres and Z up, as the script made them (OBJ has no unit
//! or up axis), each face carries its own normal so a viewer keeps CAD edges sharp, and no
//! material is named: most tools apply their own, and a `.mtl` beside the file breaks when
//! the file is moved.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const bom = @import("../../stdlib/bom.zig");

const HEADER = "# KupCAD Export\n# millimetres, Z up\n";
/// What a copy after the first is called when its part has a name: "lid 2".
const COPY_SEPARATOR = " ";

/// `solids` (rooted by the caller) as OBJ text, owned by `allocator`; `title` is a comment
/// at the top (an assembly's name). error.NoGeometry when no Solid has a triangle.
pub fn build(allocator: std.mem.Allocator, vm: *VM, solids: []const value.Value, title: ?[]const u8) ![]u8 {
    const grouping = try bom.group(vm, allocator, solids);
    defer grouping.deinit(allocator);
    // How many copies of each part are written so far, to number them
    const copies_written = try allocator.alloc(u32, grouping.parts.len);
    defer allocator.free(copies_written);
    @memset(copies_written, 0);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll(HEADER);
    if (title) |t| {
        try w.writeAll("# ");
        try writeLineText(w, t);
        try w.writeByte('\n');
    }

    // OBJ indexes vertices and normals from 1, across every object in the file
    var vertices_written: u32 = 0;
    var normals_written: u32 = 0;
    for (solids, grouping.copies) |solid, copy| {
        const handle = try vm.ensureConcrete(solid);
        try vm.requireFeature(handle.engine, .mesh);
        const mesh = kernel.getMesh(allocator, handle) orelse return error.MeshExtractionFailed;
        defer allocator.free(mesh.vert_props);
        defer allocator.free(mesh.tri_verts);
        if (mesh.tri_verts.len == 0) continue;

        copies_written[copy.part] += 1;
        try writeObjectName(w, grouping.parts[copy.part].name, copy.part + 1, copies_written[copy.part]);
        var v: usize = 0;
        while (v < mesh.vert_props.len) : (v += mesh.num_prop) {
            const p = mesh.vert_props[v..][0..3];
            try w.print("v {d} {d} {d}\n", .{ p[0], p[1], p[2] });
        }
        var t: usize = 0;
        while (t < mesh.tri_verts.len) : (t += 3) {
            const n = faceNormal(mesh.vert_props, mesh.num_prop, mesh.tri_verts[t..][0..3].*);
            try w.print("vn {d} {d} {d}\n", .{ n[0], n[1], n[2] });
        }
        t = 0;
        while (t < mesh.tri_verts.len) : (t += 3) {
            normals_written += 1;
            try w.writeByte('f');
            for (mesh.tri_verts[t..][0..3]) |vertex| try w.print(" {d}//{d}", .{ vertices_written + vertex + 1, normals_written });
            try w.writeByte('\n');
        }
        vertices_written += @intCast(mesh.vert_props.len / mesh.num_prop);
    }
    if (normals_written == 0) return error.NoGeometry;
    return out.toOwnedSlice();
}

/// `o name`: the part's name, or "part N" by its place in the parts list, with the copy's
/// number from the second copy on ("lid 2").
fn writeObjectName(w: *std.Io.Writer, name: ?[]const u8, part_number: usize, copy_number: u32) !void {
    try w.writeAll("o ");
    if (name) |n| try writeLineText(w, n) else try w.print("part {d}", .{part_number});
    if (copy_number > 1) try w.print(COPY_SEPARATOR ++ "{d}", .{copy_number});
    try w.writeByte('\n');
}

/// `text` on the current line: a script's name can hold a line break, which would start
/// another statement of the file.
fn writeLineText(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| try w.writeByte(if (c == '\n' or c == '\r') ' ' else c);
}

/// The unit normal of triangle `tri` by its winding, or zero for a degenerate one; a
/// negative zero is written as zero.
fn faceNormal(vert_props: []const f32, num_prop: usize, tri: [3]u32) [3]f64 {
    var p: [3][3]f64 = undefined;
    for (tri, &p) |vertex, *point| {
        for (vert_props[vertex * num_prop ..][0..3], point) |c, *out| out.* = c;
    }
    const a = .{ p[1][0] - p[0][0], p[1][1] - p[0][1], p[1][2] - p[0][2] };
    const b = .{ p[2][0] - p[0][0], p[2][1] - p[0][1], p[2][2] - p[0][2] };
    var n = [3]f64{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
    const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    for (&n) |*c| c.* = if (len > 0) c.* / len + 0.0 else 0.0;
    return n;
}
