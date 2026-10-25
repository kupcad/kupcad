//! A model's parts: its Solids grouped into parts, a copy being the same part placed
//! elsewhere, each measured (volume, size, mass from `material(density:)`) and named
//! (`named`, or a fallback: fallbackName, CopyNames), for the parts list (`bom`,
//! `kupcad build --bom`, writeJson), the files that keep parts apart (3MF, OBJ, glTF,
//! `--split`) and a drawing's shapes (sketchLabel). The `bom` and `named` methods are
//! stdlib/bom.zig's.
//!
//! A part is what a Solid is made of under its placement: the node of the geometry graph
//! below its translates and rotates, with the name and the material on the way down (the
//! outermost of each, as the viewport shows it). Two Solids are copies of one part when
//! that node is the same (by its hash, its content's) and so are their name and material.
//! A mirrored or scaled copy is a part of its own (a left and a right bracket), with the
//! name and material of what it was made from; a union of copies is one fused Solid.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const dag = @import("../vm/dag.zig");
const kernel = @import("../kernel/kernel.zig");
const MaterialDef = @import("../core/material.zig").MaterialDef;
const HandleScope = @import("../vm/scope.zig").HandleScope;
const Placement = @import("../core/placement.zig").Placement;
const naming = @import("names.zig");

/// mm³ in a cm³: volumes are in mm³, densities in g/cm³, masses in g.
const MM3_PER_CM3 = 1000.0;
/// The fields of a part, in the order a script and the JSON list them.
pub const FIELDS = [_][]const u8{ "name", "count", "volume", "size", "density", "mass" };

pub const Part = struct {
    /// The node of its shape under its placement (CONCRETE_NODE_SENTINEL for a Solid made
    /// outside the graph, which is a part of its own).
    shape: dag.DAGNodeIndex,
    /// In the graph's name table, or null when it has none.
    name: ?[]const u8,
    material: ?MaterialDef,
    /// The material's index in the VM's (a set_material node's), with `material`.
    material_id: ?u32 = null,
    count: u32 = 1,
    /// mm³
    volume: f64 = 0,
    /// The extent of its bounding box along x, y and z, in mm, as the part is made (before
    /// its placement).
    size: [3]f64 = .{ 0, 0, 0 },
    /// The first of its copies, measured in place of the shape when it has no node.
    first: value.Value,

    pub fn density(self: Part) ?f64 {
        return (self.material orelse return null).density;
    }

    /// g, when its material has a density.
    pub fn mass(self: Part) ?f64 {
        return self.volume * (self.density() orelse return null) / MM3_PER_CM3;
    }
};

/// A Solid as a copy of a part: the part (an index into Grouping.parts) and where its
/// placement puts the part's shape.
pub const Copy = struct {
    part: u32,
    placement: Placement,
};

/// What an unnamed shape is called where a name is needed (a split's file, an OBJ's object,
/// a glTF's node, a drawing's layer): "part_N" for a Solid or a Sketch, "path_N" for a Path,
/// numbered in order; a name used again gets a number too ("lid_2"). One scheme for all.
pub const ShapeKind = enum {
    part,
    path,

    fn fallback(self: ShapeKind) []const u8 {
        return switch (self) {
            .part => "part",
            .path => "path",
        };
    }
};

/// "part_3", "path_1": the name of the `number`th unnamed shape of its kind (the first is
/// numbered too). Caller owns it.
pub fn fallbackName(allocator: std.mem.Allocator, kind: ShapeKind, number: usize) ![]u8 {
    return allocator.print("{s}" ++ naming.NAME_NUMBER_SEPARATOR ++ "{d}", .{ kind.fallback(), number });
}

/// The names a file that keeps parts apart (an OBJ's objects, a glTF's nodes) gives the
/// model's Solids, in their order: the part's name, or "part_N" by its place in the parts
/// list (fallbackName), numbered from the second copy on ("lid_2").
pub const CopyNames = struct {
    grouping: *const Grouping,
    /// How many copies of each part are named so far.
    named: []u32,
    /// The number each unnamed part got ("part_N"), in the order they first appear; 0 before.
    fallbacks: []u32,
    unnamed_so_far: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, grouping: *const Grouping) !CopyNames {
        const named = try allocator.alloc(u32, grouping.parts.len);
        errdefer allocator.free(named);
        @memset(named, 0);
        const fallbacks = try allocator.alloc(u32, grouping.parts.len);
        @memset(fallbacks, 0);
        return .{ .grouping = grouping, .named = named, .fallbacks = fallbacks };
    }

    pub fn deinit(self: *CopyNames, allocator: std.mem.Allocator) void {
        allocator.free(self.named);
        allocator.free(self.fallbacks);
    }

    /// The name of the next copy of `copy`'s part (the copies are named in the Solids'
    /// order); caller owns it.
    pub fn next(self: *CopyNames, allocator: std.mem.Allocator, copy: Copy) ![]u8 {
        self.named[copy.part] += 1;
        const number = self.named[copy.part];
        if (self.grouping.parts[copy.part].name) |name| return naming.numberedName(allocator, name, number);
        if (self.fallbacks[copy.part] == 0) {
            self.unnamed_so_far += 1;
            self.fallbacks[copy.part] = self.unnamed_so_far;
        }
        const first = try fallbackName(allocator, .part, self.fallbacks[copy.part]);
        defer allocator.free(first);
        return naming.numberedName(allocator, first, number);
    }
};

/// Solids grouped into parts, the parts not measured yet.
pub const Grouping = struct {
    /// In the order each first appears.
    parts: []Part,
    /// One per Solid, in their order.
    copies: []Copy,

    pub fn deinit(self: Grouping, allocator: std.mem.Allocator) void {
        allocator.free(self.parts);
        allocator.free(self.copies);
    }
};

/// The parts `solids` (Solids, rooted by the caller) are copies of, and each one's copy.
/// Owned by `allocator`; the names are the graph's.
pub fn group(vm: *const VM, allocator: std.mem.Allocator, solids: []const value.Value) !Grouping {
    var parts: std.ArrayList(Part) = .empty;
    errdefer parts.deinit(allocator);
    const copies = try allocator.alloc(Copy, solids.len);
    errdefer allocator.free(copies);
    var by_identity: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer by_identity.deinit(allocator);
    for (solids, copies) |solid, *copy| {
        const found = copyOf(vm, solid);
        const entry = try by_identity.getOrPut(allocator, identity(vm, found.part));
        if (entry.found_existing) {
            parts.items[entry.value_ptr.*].count += 1;
        } else {
            entry.value_ptr.* = @intCast(parts.items.len);
            try parts.append(allocator, found.part);
        }
        copy.* = .{ .part = entry.value_ptr.*, .placement = found.placement };
    }
    return .{ .parts = try parts.toOwnedSlice(allocator), .copies = copies };
}

/// The parts `solids` are copies of, as `group` finds them, measured (their volume and
/// size). Owned by `allocator`.
pub fn collect(vm: *VM, allocator: std.mem.Allocator, solids: []const value.Value) ![]Part {
    const grouping = try group(vm, allocator, solids);
    allocator.free(grouping.copies);
    errdefer allocator.free(grouping.parts);
    for (grouping.parts) |*part| try measure(vm, part);
    return grouping.parts;
}

/// The part `solid` is a copy of, before it is measured, and where the copy is: down
/// through its placement (its translates and rotates, composed) to the shape, and on
/// through a mirror or a scale of a named or a made-of part for its name and material.
fn copyOf(vm: *const VM, solid: value.Value) struct { part: Part, placement: Placement } {
    const b = &vm.dag_builder;
    var part: Part = .{ .shape = solid.asGeometry().dag_idx, .name = null, .material = null, .first = solid };
    var placement = Placement.identity;
    var placed = true; // still in the placement, above the shape
    var at = part.shape;
    // Every node walked through has its operand first in its payload
    while (at != dag.CONCRETE_NODE_SENTINEL) : (at = b.extra_data.items[b.nodes.items[at].data]) {
        const node = b.nodes.items[at];
        switch (node.tag) {
            // Outermost first: each places what the ones inside it placed
            .translate, .rotate => if (placed) {
                const p = b.getTranslatePayload(node);
                const step = if (node.tag == .translate) Placement.translation(p.x, p.y, p.z) else Placement.rotation(p.x, p.y, p.z);
                placement = placement.then(step);
            },
            .set_name => if (part.name == null) {
                part.name = b.partName(b.getNamePayload(node).name_id);
            },
            .set_material => if (part.material == null) {
                if (knownMaterial(vm, node)) |known| {
                    part.material = known.def;
                    part.material_id = known.id;
                }
            },
            .mirror, .scale, .transform_matrix => if (placed) {
                part.shape = at;
                placed = false;
            },
            else => {
                if (placed) part.shape = at;
                break;
            },
        }
    }
    return .{ .part = part, .placement = placement };
}

/// What makes two Solids copies of one part: the shape's content, the name and the material.
fn identity(vm: *const VM, part: Part) u64 {
    var hasher = std.hash.Wyhash.init(0);
    if (part.shape == dag.CONCRETE_NODE_SENTINEL) {
        hasher.update(std.mem.asBytes(&part.first.val));
    } else {
        hasher.update(std.mem.asBytes(&vm.dag_builder.node_hashes.items[part.shape]));
    }
    if (part.name) |name| {
        hasher.update(&.{1});
        hasher.update(name);
    } else hasher.update(&.{0});
    if (part.material) |mat| {
        hasher.update(&.{1});
        mat.hashInto(&hasher);
    } else hasher.update(&.{0});
    return hasher.final();
}

/// A part's volume (mm³) and the extent of its bounding box along x, y and z (mm), as it
/// is made.
pub const Measures = struct { volume: f64, size: [3]f64 };

/// What a part's measures are when its engine can't take them: refused (the bill of
/// materials, whose numbers they are), or left out (a preview, which shows the part anyway).
pub const Unmeasurable = enum { refuse, leave_out };

/// Its volume and size, from the shape as it is made; for a shape whose engine can't take
/// them, a NotImplementedError, or null, as `unmeasurable` says.
pub fn measuresOf(vm: *VM, part: Part, unmeasurable: Unmeasurable) !?Measures {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const shape = try shapeOf(vm, part);
    vm.push(shape);
    const solid = try vm.ensureConcrete(shape);
    for ([_]kernel.Feature{ .volume, .bounding_box }) |feature| {
        if (kernel.supports(solid.engine, feature)) continue;
        if (unmeasurable == .leave_out) return null;
        try vm.requireFeature(solid.engine, feature);
    }
    const box = kernel.boundingBox(solid) orelse return switch (unmeasurable) {
        .leave_out => null,
        .refuse => vm.fail(.GeometryError, "bom could not compute the bounding box of a part", .{}),
    };
    var size: [3]f64 = undefined;
    for (&size, box.min, box.max) |*extent, low, high| extent.* = high - low;
    return .{ .volume = kernel.volume(solid), .size = size };
}

/// Its volume and size, which the bill of materials gives: an engine that can't take them
/// is refused.
fn measure(vm: *VM, part: *Part) !void {
    const measured = (try measuresOf(vm, part.*, .refuse)).?;
    part.volume = measured.volume;
    part.size = measured.size;
}

/// `part`'s shape, as made, before its placement: a new Solid the caller roots while it
/// uses it (or what it evaluates to: the result cache keeps a mesh no live Solid refers to
/// only until the next collection).
pub fn shapeOf(vm: *VM, part: Part) !value.Value {
    if (part.shape == dag.CONCRETE_NODE_SENTINEL) return part.first;
    return vm.allocateGeometry(.{ .symbolic = part.shape });
}

/// `part` as made, without its placement but with its material and name: what a file of
/// it alone holds (`kupcad build --split`, a 3MF object's mesh). A new Solid the caller
/// roots, as shapeOf's.
pub fn madeOf(vm: *VM, part: Part) !value.Value {
    if (part.shape == dag.CONCRETE_NODE_SENTINEL) return part.first;
    const b = &vm.dag_builder;
    var node = part.shape;
    if (part.material_id) |id| node = try b.addSetMaterial(node, id);
    if (part.name) |name| node = try b.addSetName(node, try b.internPartName(name));
    return vm.allocateGeometry(.{ .symbolic = node });
}

/// `parts` as `kupcad build --bom` writes them, indented: {"parts": [{"name": ...,
/// "count": ...}]}, with null where a part has no name, density or mass (FIELDS).
pub fn writeJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, parts: []const Part) !void {
    const Row = struct { name: ?[]const u8, count: u32, volume: f64, size: [3]f64, density: ?f64, mass: ?f64 };
    comptime for (FIELDS, @typeInfo(Row).@"struct".field_names) |field, row_field| {
        if (!std.mem.eql(u8, field, row_field)) @compileError("a part's JSON fields are FIELDS, in order");
    };
    const rows = try allocator.alloc(Row, parts.len);
    defer allocator.free(rows);
    for (parts, rows) |part, *row| {
        row.* = .{ .name = part.name, .count = part.count, .volume = part.volume, .size = part.size, .density = part.density(), .mass = part.mass() };
    }
    try std.json.Stringify.value(.{ .parts = rows }, .{ .whitespace = .indent_2 }, writer);
    try writer.writeByte('\n');
}

/// What a Sketch carries for a drawing (SVG, DXF): the outermost `named` and `material`
/// on it, through its transforms (as a Solid's part has them), none through an operation
/// that makes another shape (an offset, a boolean).
pub const Label = struct {
    name: ?[]const u8 = null,
    material: ?MaterialDef = null,
};

pub fn sketchLabel(vm: *const VM, sketch: value.Value) Label {
    const b = &vm.dag_builder;
    var label: Label = .{};
    var at = sketch.asCrossSection().dag_idx;
    while (at != dag.CONCRETE_NODE_SENTINEL) : (at = b.extra_data.items[b.nodes.items[at].data]) {
        const node = b.nodes.items[at];
        switch (node.tag) {
            .cs_set_name => if (label.name == null) {
                label.name = b.partName(b.getNamePayload(node).name_id);
            },
            .cs_set_material => if (label.material == null) {
                if (knownMaterial(vm, node)) |known| label.material = known.def;
            },
            .cs_transform => {},
            else => break,
        }
    }
    return label;
}

/// The material a set_material node names, if the VM still has it (one of an earlier
/// run, a session's, is no longer known).
fn knownMaterial(vm: *const VM, node: dag.DAGNode) ?struct { def: MaterialDef, id: u32 } {
    const id = vm.dag_builder.getMaterialPayload(node).material_id;
    if (id >= vm.materials.items.len) return null;
    return .{ .def = vm.materials.items[id], .id = id };
}
