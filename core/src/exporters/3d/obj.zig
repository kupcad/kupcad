//! OBJ export: `build` writes a model as Wavefront OBJ, one `o` object per part, by the name
//! it is given (export.zig names each copy as the parts list does: the part's name,
//! numbered from its second copy on). The vertices are in millimetres and Z up, as the script made them (OBJ has no unit
//! or up axis), and each face carries its own normal so a viewer keeps CAD edges sharp. No
//! material is named unless a library is asked for: most tools apply their own, and a `.mtl`
//! beside the file breaks when the file is moved. With one, `buildMaterialLibrary` writes
//! the `.mtl` and the faces name their materials (`usemtl`), the colours as diffuse and
//! ambient.

const std = @import("std");
const kernel = @import("../../kernel/kernel.zig");
const vec3 = @import("../../core/vec3.zig");
const material_groups = @import("material_groups.zig");
const mesh_part = @import("mesh_part.zig");
const MeshPart = mesh_part.MeshPart;
const material = @import("../../core/material.zig");
const MaterialDef = material.MaterialDef;

const HEADER = "# KupCAD Export\n# millimetres, Z up\n";
/// The material of faces without one (kernel.DEFAULT_MATERIAL_SLOT), neutral grey as the
/// glTF export's.
const DEFAULT_MATERIAL_NAME = "default";
const DEFAULT_GREY = 0.8;

/// `parts` as OBJ text, owned by `allocator`; their engine must tessellate (the caller
/// checks). `title` is a comment at the top (an assembly's name). With `mtl_name`, the file
/// names that library (`mtllib`, buildMaterialLibrary's) and each run of faces its
/// material, of `materials` (the VM's, which the slots index). error.NoGeometry when no
/// part has a triangle.
pub fn build(allocator: std.mem.Allocator, parts: []const MeshPart, materials: []const MaterialDef, title: ?[]const u8, mtl_name: ?[]const u8) ![]u8 {
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
    for (parts) |part| {
        const mesh = try mesh_part.floatMesh(allocator, part.handle);
        defer allocator.free(mesh.vert_props);
        defer allocator.free(mesh.tri_verts);
        if (mesh.tri_verts.len == 0) continue;

        if (part.name) |name| {
            try w.writeAll("o ");
            try writeLineText(w, name);
            try w.writeByte('\n');
        }
        var v: usize = 0;
        while (v < mesh.vert_props.len) : (v += mesh.num_prop) {
            const p = mesh.vert_props[v..][0..3];
            try w.print("v {d} {d} {d}\n", .{ p[0], p[1], p[2] });
        }
        // The faces by material, each run under its `usemtl`; a normal per face, in the
        // faces' order
        var groups = try material_groups.Groups.collect(allocator, mesh, materials.len);
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
                try writeName(w, keyOf(materials, group.slot));
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

/// The material library (`.mtl`) of the materials of `slots` (kernel.materialSlot, of
/// `materials`), those an OBJ's faces use (material_groups.UsedSlots), each once by its
/// name: its colour as the diffuse and ambient colour and its alpha as the dissolve.
pub fn buildMaterialLibrary(allocator: std.mem.Allocator, materials: []const MaterialDef, slots: []const u32) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("# KupCAD Export\n");
    var written: std.ArrayList(?[4]u8) = .empty;
    defer written.deinit(allocator);
    for (slots) |slot| {
        // Two materials of one colour and alpha are one in a library, which holds no more
        const key = keyOf(materials, slot);
        for (written.items) |known| {
            if (std.meta.eql(known, key)) break;
        } else {
            try written.append(allocator, key);
            var rgb: [3]f64 = @splat(DEFAULT_GREY);
            var alpha: f64 = 1;
            if (key) |rgba| {
                for (rgba[0..3], &rgb) |byte, *channel| channel.* = @as(f64, @floatFromInt(byte)) / 255.0;
                alpha = std.math.clamp(materials[slot - 1].alpha, 0, 1);
            }
            try w.writeAll("newmtl ");
            try writeName(w, key);
            try w.print("\nKd {d} {d} {d}\nKa {d} {d} {d}\nd {d}\n", .{ rgb[0], rgb[1], rgb[2], rgb[0], rgb[1], rgb[2], alpha });
        }
    }
    return out.toOwnedSlice();
}

/// What names the material of `slot` (of `materials`) in an OBJ and its library: null for
/// the default, else its colour and alpha, all a library holds of it. A name by its colour
/// (`material_ff0000ff`) is the same in each file of a split, which share one library, and
/// whatever else the session has made.
fn keyOf(materials: []const MaterialDef, slot: u32) ?[4]u8 {
    if (slot == kernel.DEFAULT_MATERIAL_SLOT) return null;
    const def = materials[slot - 1];
    return .{ def.rgb[0], def.rgb[1], def.rgb[2], @intFromFloat(@round(std.math.clamp(def.alpha, 0, 1) * 255)) };
}

/// The name `key` (keyOf) gives a material, in the library and after `usemtl`.
fn writeName(w: *std.Io.Writer, key: ?[4]u8) !void {
    const rgba = key orelse return w.writeAll(DEFAULT_MATERIAL_NAME);
    const hex = material.hexRgba(rgba);
    try w.print("material_{s}", .{hex[1..]});
}

/// `text` on the current line: a script's name can hold a line break, which would start
/// another statement of the file.
/// `text` on one line of the file: a control character (a line break, which would start
/// another statement; a NUL, a tab) becomes a space, as DXF and 3MF names leave none in.
fn writeLineText(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| try w.writeByte(if (std.ascii.isControl(c)) ' ' else c);
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
