//! OBJ export: `build` writes a model as Wavefront OBJ, one `o` object per Solid, named as
//! the parts list names its copies (bom.CopyNames: the part's name, numbered from its second
//! copy on). The vertices are in millimetres and Z up, as the script made them (OBJ has no unit
//! or up axis), and each face carries its own normal so a viewer keeps CAD edges sharp. No
//! material is named unless a library is asked for: most tools apply their own, and a `.mtl`
//! beside the file breaks when the file is moved. With one, `buildMaterialLibrary` writes
//! the `.mtl` and the faces name their materials (`usemtl`), the colours as diffuse and
//! ambient.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const kernel = @import("../../kernel/kernel.zig");
const vec3 = @import("../../core/vec3.zig");
const bom = @import("../../stdlib/bom.zig");
const material_groups = @import("material_groups.zig");
const MaterialDef = @import("../../core/material.zig").MaterialDef;

const HEADER = "# KupCAD Export\n# millimetres, Z up\n";
/// The material of faces without one (kernel.DEFAULT_MATERIAL_SLOT), neutral grey as the
/// glTF export's.
const DEFAULT_MATERIAL_NAME = "default";
const DEFAULT_GREY = 0.8;

/// `solids` (rooted by the caller) as OBJ text, owned by `allocator`; `title` is a comment
/// at the top (an assembly's name). With `mtl_name`, the file names that library
/// (`mtllib`) and each run of faces its material. error.NoGeometry when no Solid has a
/// triangle.
pub fn build(allocator: std.mem.Allocator, vm: *VM, solids: []const value.Value, title: ?[]const u8, mtl_name: ?[]const u8) ![]u8 {
    const grouping = try bom.group(vm, allocator, solids);
    defer grouping.deinit(allocator);
    var names = try bom.CopyNames.init(allocator, &grouping);
    defer names.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll(HEADER);
    if (title) |t| {
        try w.writeAll("# ");
        try writeLineText(w, t);
        try w.writeByte('\n');
    }
    if (mtl_name) |name| {
        try w.writeAll("mtllib ");
        try writeLineText(w, name);
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

        const name = try names.next(allocator, copy);
        defer allocator.free(name);
        try w.writeAll("o ");
        try writeLineText(w, name);
        try w.writeByte('\n');
        var v: usize = 0;
        while (v < mesh.vert_props.len) : (v += mesh.num_prop) {
            const p = mesh.vert_props[v..][0..3];
            try w.print("v {d} {d} {d}\n", .{ p[0], p[1], p[2] });
        }
        // The faces by material, each run under its `usemtl`; a normal per face, in the
        // faces' order
        var groups = try material_groups.Groups.collect(allocator, mesh);
        defer groups.deinit(allocator);
        for (0..groups.count()) |g| {
            for (groups.at(g).tri_starts) |tri| {
                const n = faceNormal(mesh.vert_props, mesh.num_prop, mesh.tri_verts[tri..][0..3].*);
                try w.print("vn {d} {d} {d}\n", .{ n[0], n[1], n[2] });
            }
        }
        for (0..groups.count()) |g| {
            const group = groups.at(g);
            if (mtl_name != null) {
                try w.writeAll("usemtl ");
                try writeMaterialName(w, group.slot);
                try w.writeByte('\n');
            }
            for (group.tri_starts) |tri| {
                normals_written += 1;
                try w.writeByte('f');
                for (mesh.tri_verts[tri..][0..3]) |vertex| try w.print(" {d}//{d}", .{ vertices_written + vertex + 1, normals_written });
                try w.writeByte('\n');
            }
        }
        vertices_written += @intCast(mesh.vert_props.len / mesh.num_prop);
    }
    if (normals_written == 0) return error.NoGeometry;
    return out.toOwnedSlice();
}

/// The material library (`.mtl`) of a model: the default material, then each of the
/// script's (`materials`, in the VM's order, so a face's slot is its number), its colour as
/// the diffuse and ambient colour and its alpha as the dissolve.
pub fn buildMaterialLibrary(allocator: std.mem.Allocator, materials: []const MaterialDef) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("# KupCAD Export\n");
    try writeMaterial(w, kernel.DEFAULT_MATERIAL_SLOT, .{ DEFAULT_GREY, DEFAULT_GREY, DEFAULT_GREY }, 1.0);
    for (materials, 1..) |def, slot| {
        var rgb: [3]f64 = undefined;
        for (def.rgb, &rgb) |byte, *channel| channel.* = @as(f64, @floatFromInt(byte)) / 255.0;
        try writeMaterial(w, @intCast(slot), rgb, std.math.clamp(def.alpha, 0, 1));
    }
    return out.toOwnedSlice();
}

fn writeMaterial(w: *std.Io.Writer, slot: u32, rgb: [3]f64, alpha: f64) !void {
    try w.writeAll("newmtl ");
    try writeMaterialName(w, slot);
    try w.print("\nKd {d} {d} {d}\nKa {d} {d} {d}\nd {d}\n", .{ rgb[0], rgb[1], rgb[2], rgb[0], rgb[1], rgb[2], alpha });
}

/// The name of material slot `slot`, in the library and after `usemtl`.
fn writeMaterialName(w: *std.Io.Writer, slot: u32) !void {
    if (slot == kernel.DEFAULT_MATERIAL_SLOT) return w.writeAll(DEFAULT_MATERIAL_NAME);
    try w.print("material_{d}", .{slot});
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
    return vec3.triangleNormal(p[0], p[1], p[2]);
}
