//! 3MF export: a model as a 3D Manufacturing Format package, a zip (exporters/zip.zig) of a
//! content types file, a relationship and the model's XML. Each part (export.zig makes them
//! from the parts list, exporters/parts.zig) is one object's mesh, and each copy of it one
//! build item placed by the copy's transform, so a slicer gets a part once with all its
//! copies (an STL holds them merged). Units are millimetres; the materials' colours are
//! base materials, by triangle.

const std = @import("std");
const kernel = @import("../../kernel/kernel.zig");
const material = @import("../../core/material.zig");
const MaterialDef = material.MaterialDef;
const Placement = @import("../../core/placement.zig").Placement;
const mesh_part = @import("mesh_part.zig");
const MeshPart = mesh_part.MeshPart;
const material_groups = @import("material_groups.zig");
const zip = @import("../zip.zig");

pub const MODEL_PATH = "3D/3dmodel.model";
const CONTENT_TYPES =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>
    \\
;
const RELATIONSHIPS =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/
++ MODEL_PATH ++
    \\" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
    \\
;
/// The resource id of the base materials; the objects' ids follow it.
const MATERIALS_ID = 1;
/// The colour of a triangle with no material, as the glTF export's default.
const DEFAULT_COLOR = [4]u8{ 0xCC, 0xCC, 0xCC, 0xFF };

/// A copy of a part: the index of its part among `build`'s `parts`, and where it is placed.
pub const Item = struct { part: u32, placement: Placement };

/// `parts` (each as made: its material, no placement; an engine that tessellates, which the
/// caller checks) placed by `items` as a 3MF package, owned by `allocator`; `materials` are
/// what the meshes' material slots index (kernel.materialSlot), the VM's, and `title`
/// names the model (an assembly's name). error.NoGeometry when no part has a triangle.
pub fn build(allocator: std.mem.Allocator, parts: []const MeshPart, items: []const Item, materials: []const MaterialDef, title: ?[]const u8) ![]u8 {
    // A part with no triangles has no object, nor items
    const object_ids = try allocator.alloc(?u32, parts.len);
    defer allocator.free(object_ids);

    var model: std.Io.Writer.Allocating = .init(allocator);
    defer model.deinit();
    const w = &model.writer;
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">\n");
    if (title) |t| {
        try w.writeAll(" <metadata name=\"Title\">");
        try writeEscaped(w, t);
        try w.writeAll("</metadata>\n");
    }
    // The objects first, aside: they number the materials they use, which come before them
    var objects: std.Io.Writer.Allocating = .init(allocator);
    defer objects.deinit();
    var used: material_groups.UsedSlots = .{};
    defer used.deinit(allocator);
    // The default is every object's own (pindex 0), whether a triangle of it shows it or not
    _ = try used.numberOf(allocator, kernel.DEFAULT_MATERIAL_SLOT);
    var next_id: u32 = MATERIALS_ID + 1;
    for (parts, object_ids) |part, *id| {
        id.* = if (try writeObject(allocator, &objects.writer, part, next_id, materials.len, &used)) next_id else null;
        if (id.* != null) next_id += 1;
    }
    try w.writeAll(" <resources>\n");
    try writeMaterials(w, materials, used.inOrder());
    try w.writeAll(objects.written());
    try w.writeAll(" </resources>\n <build>\n");
    var written: usize = 0;
    for (items) |item| {
        const id = object_ids[item.part] orelse continue;
        try w.print("  <item objectid=\"{d}\" transform=\"", .{id});
        try writeTransform(w, item.placement);
        try w.writeAll("\"/>\n");
        written += 1;
    }
    if (written == 0) return error.NoGeometry;
    try w.writeAll(" </build>\n</model>\n");

    return zip.write(allocator, &.{
        .{ .name = "[Content_Types].xml", .data = CONTENT_TYPES },
        .{ .name = "_rels/.rels", .data = RELATIONSHIPS },
        .{ .name = MODEL_PATH, .data = model.written() },
    });
}

/// The base materials of `slots` (kernel.materialSlot, of `defs`), in the order that
/// numbers them as the triangles do: the default first, then those the objects use.
fn writeMaterials(w: *std.Io.Writer, defs: []const MaterialDef, slots: []const u32) !void {
    try w.print("  <basematerials id=\"{d}\">\n", .{MATERIALS_ID});
    for (slots, 0..) |slot, number| {
        if (slot == kernel.DEFAULT_MATERIAL_SLOT) {
            try writeBase(w, "default", DEFAULT_COLOR);
            continue;
        }
        const def = defs[slot - 1];
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "material {d}", .{number});
        const alpha: u8 = @intFromFloat(@round(std.math.clamp(def.alpha, 0, 1) * 255));
        try writeBase(w, name, .{ def.rgb[0], def.rgb[1], def.rgb[2], alpha });
    }
    try w.writeAll("  </basematerials>\n");
}

fn writeBase(w: *std.Io.Writer, name: []const u8, color: [4]u8) !void {
    try w.print("   <base name=\"{s}\" displaycolor=\"{s}\"/>\n", .{ name, &material.hexRgba(color) });
}

/// `part`'s mesh as the object `id`, its triangles in the materials they have (of
/// `material_count`), each by its number in `used`; false (and nothing written) when the
/// mesh has none.
fn writeObject(allocator: std.mem.Allocator, w: *std.Io.Writer, part: MeshPart, id: u32, material_count: usize, used: *material_groups.UsedSlots) !bool {
    const mesh = try mesh_part.floatMesh(allocator, part.handle, part.preview);
    defer allocator.free(mesh.vert_props);
    defer allocator.free(mesh.tri_verts);
    if (mesh.tri_verts.len == 0) return false;

    try w.print("  <object id=\"{d}\" type=\"model\" pid=\"{d}\" pindex=\"{d}\"", .{ id, MATERIALS_ID, kernel.DEFAULT_MATERIAL_SLOT });
    if (part.name) |name| {
        try w.writeAll(" name=\"");
        try writeEscaped(w, name);
        try w.writeByte('"');
    }
    try w.writeAll(">\n   <mesh>\n    <vertices>\n");
    var v: usize = 0;
    while (v < mesh.vert_props.len) : (v += mesh.num_prop) {
        const p = mesh.vert_props[v..][0..3];
        try w.print("     <vertex x=\"{d}\" y=\"{d}\" z=\"{d}\"/>\n", .{ p[0], p[1], p[2] });
    }
    try w.writeAll("    </vertices>\n    <triangles>\n");
    var t: usize = 0;
    while (t < mesh.tri_verts.len) : (t += 3) {
        const tri = mesh.tri_verts[t..][0..3];
        try w.print("     <triangle v1=\"{d}\" v2=\"{d}\" v3=\"{d}\"", .{ tri[0], tri[1], tri[2] });
        const slot = material_groups.slotOf(mesh, t, material_count);
        if (slot != kernel.DEFAULT_MATERIAL_SLOT) try w.print(" pid=\"{d}\" p1=\"{d}\"", .{ MATERIALS_ID, try used.numberOf(allocator, slot) });
        try w.writeAll("/>\n");
    }
    try w.writeAll("    </triangles>\n   </mesh>\n  </object>\n");
    return true;
}

/// A 3MF transform: the images of x, y and z, then the translation (`m00 m01 m02 m10 ...
/// m32`, for a point as a row times the matrix).
fn writeTransform(w: *std.Io.Writer, placement: Placement) !void {
    for (placement.m, 0..) |column, c| {
        for (column, 0..) |entry, r| {
            if (c + r > 0) try w.writeByte(' ');
            // -0 reads as 0, and prints as it
            try w.print("{d}", .{if (entry == 0) 0 else entry});
        }
    }
}

/// `text` as XML text or an attribute's value: the markup characters as entities, a tab and
/// a line break as character references (an attribute's raw one reads back as a space), and
/// the other control characters left out, which XML 1.0 has no way to hold.
fn writeEscaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        '\t', '\n', '\r' => try w.print("&#{d};", .{c}),
        0...8, 0x0B, 0x0C, 0x0E...0x1F => {},
        else => try w.writeByte(c),
    };
}
