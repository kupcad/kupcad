//! A model's parts list (bill of materials): its Solids grouped into parts, a copy being the
//! same part placed elsewhere. `named` names a part, `material(density:)` gives it a mass,
//! and `bom` on a Solid or an Assembly (and `kupcad build --bom`) lists them.
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
const util = @import("methods/util.zig");

/// mm³ in a cm³: volumes are in mm³, densities in g/cm³, masses in g.
const MM3_PER_CM3 = 1000.0;
/// The fields of a part, in the order a script and the JSON list them.
const FIELDS = [_][]const u8{ "name", "count", "volume", "size", "density", "mass" };

pub const Part = struct {
    /// The node of its shape under its placement (CONCRETE_NODE_SENTINEL for a Solid made
    /// outside the graph, which is a part of its own).
    shape: dag.DAGNodeIndex,
    /// In the graph's name table, or null when it has none.
    name: ?[]const u8,
    material: ?MaterialDef,
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

/// The parts `solids` (Solids, rooted by the caller) are copies of, in the order each first
/// appears, measured. Owned by `allocator`; the names are the graph's.
pub fn collect(vm: *VM, allocator: std.mem.Allocator, solids: []const value.Value) ![]Part {
    var parts: std.ArrayList(Part) = .empty;
    errdefer parts.deinit(allocator);
    var by_identity: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    defer by_identity.deinit(allocator);
    for (solids) |solid| {
        const part = partOf(vm, solid);
        const entry = try by_identity.getOrPut(allocator, identity(vm, part));
        if (entry.found_existing) {
            parts.items[entry.value_ptr.*].count += 1;
            continue;
        }
        entry.value_ptr.* = parts.items.len;
        try parts.append(allocator, part);
    }
    for (parts.items) |*part| try measure(vm, part);
    return parts.toOwnedSlice(allocator);
}

/// The part `solid` is a copy of, before it is measured: down through its placement to
/// the shape, and on through a mirror or a scale of a named or a made-of part for its name
/// and material.
fn partOf(vm: *const VM, solid: value.Value) Part {
    const b = &vm.dag_builder;
    var part: Part = .{ .shape = solid.asGeometry().dag_idx, .name = null, .material = null, .first = solid };
    var placed = true; // still in the placement, above the shape
    var at = part.shape;
    // Every node walked through has its operand first in its payload
    while (at != dag.CONCRETE_NODE_SENTINEL) : (at = b.extra_data.items[b.nodes.items[at].data]) {
        const node = b.nodes.items[at];
        switch (node.tag) {
            .translate, .rotate => {},
            .set_name => if (part.name == null) {
                part.name = b.partName(b.getNamePayload(node).name_id);
            },
            // A material of an earlier run (a session's) is no longer known
            .set_material => if (part.material == null) {
                const id = b.getMaterialPayload(node).material_id;
                if (id < vm.materials.items.len) part.material = vm.materials.items[id];
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
    return part;
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

/// Its volume and size, from the shape as it is made.
fn measure(vm: *VM, part: *Part) !void {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const shape = if (part.shape == dag.CONCRETE_NODE_SENTINEL) part.first else try vm.allocateGeometry(.{ .symbolic = part.shape });
    vm.push(shape);
    const solid = try vm.ensureConcrete(shape);
    try vm.requireFeature(solid.engine, .volume);
    try vm.requireFeature(solid.engine, .bounding_box);
    part.volume = kernel.volume(solid);
    const box = kernel.boundingBox(solid) orelse return vm.fail(.GeometryError, "bom could not compute the bounding box of a part", .{});
    for (&part.size, box.min, box.max) |*extent, low, high| extent.* = high - low;
}

/// `receiver`'s Solids: itself, or an Assembly's parts.
pub fn solidsOf(vm: *VM, receiver: value.Value, method: []const u8, single: *[1]value.Value) ![]const value.Value {
    if (receiver.isGeometry()) {
        single.* = .{receiver};
        return single;
    }
    if (receiver.isAssembly()) return receiver.asAssembly().parts.items.items;
    return util.notDefinedFor(vm, method, receiver);
}

/// solid.bom / assembly.bom -> its parts list: an Array of a Map per part, {name:, count:,
/// volume:, size: [x, y, z], density:, mass:} (nil where it has none).
pub fn meshBom(vm: *VM, receiver: value.Value) !value.Value {
    var single: [1]value.Value = undefined;
    const parts = try collect(vm, vm.allocator, try solidsOf(vm, receiver, "bom", &single));
    defer vm.allocator.free(parts);

    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const rows = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&rows.obj));
    try rows.items.ensureTotalCapacity(vm.gc.trackingAllocator(), parts.len);
    for (parts) |part| rows.items.appendAssumeCapacity(try rowOf(vm, part));
    return value.Value.initObj(&rows.obj);
}

/// `part` as a Map with Symbol keys (FIELDS).
fn rowOf(vm: *VM, part: Part) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const row = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&row.obj));
    const size = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&size.obj));
    try size.items.ensureTotalCapacity(vm.gc.trackingAllocator(), part.size.len);
    for (part.size) |extent| size.items.appendAssumeCapacity(value.Value.initNumber(extent));
    const name = if (part.name) |text| try vm.allocateString(text) else value.Value.initNil();
    vm.push(name);
    const fields = [FIELDS.len]value.Value{
        name,
        value.Value.initNumber(@floatFromInt(part.count)),
        value.Value.initNumber(part.volume),
        value.Value.initObj(&size.obj),
        if (part.density()) |d| value.Value.initNumber(d) else value.Value.initNil(),
        if (part.mass()) |m| value.Value.initNumber(m) else value.Value.initNil(),
    };
    for (FIELDS, fields) |field, v| {
        const key = try vm.allocateSymbol(field);
        vm.push(key);
        try vm.mapSet(row, key, v);
    }
    return value.Value.initObj(&row.obj);
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

/// solid.named(name) -> the Solid, its part named `name` in the parts list. The shape is
/// the same: a name changes nothing a viewport or an export shows.
pub fn meshNamed(vm: *VM, receiver: value.Value, name: []const u8) !value.Value {
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "named", receiver);
    if (std.mem.trim(u8, name, &std.ascii.whitespace).len == 0) {
        return vm.fail(.ValueError, "named expects a name, got \"{s}\"", .{name});
    }
    const id = try vm.dag_builder.internPartName(name);
    return vm.allocateGeometry(.{ .symbolic = try vm.dag_builder.addSetName(receiver.asGeometry().dag_idx, id) });
}
