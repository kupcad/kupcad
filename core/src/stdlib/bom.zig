//! The parts-list methods: `bom` on a Solid or an Assembly lists the parts its Solids are
//! copies of (exporters/parts.zig groups and measures them), and `named` names a Solid's
//! part, or a Sketch for a drawing.

const std = @import("std");
const value = @import("../core/value.zig");
const assembly_mod = @import("assembly.zig");
const VM = @import("../vm/vm.zig").VM;
const HandleScope = @import("../vm/scope.zig").HandleScope;
const arguments = @import("arguments.zig");
const parts_mod = @import("../exporters/parts.zig");
const Part = parts_mod.Part;

/// Appends `receiver`'s Solids to `solids`: itself, or an Assembly's, its assemblies' too.
pub fn solidsOf(vm: *VM, receiver: value.Value, method: []const u8, solids: *std.ArrayList(value.Value)) !void {
    if (receiver.isGeometry()) return solids.append(vm.allocator, receiver);
    if (receiver.isAssembly()) return assembly_mod.appendSolids(vm, solids, receiver);
    return arguments.notDefinedFor(vm, method, receiver);
}

/// solid.bom / assembly.bom -> its parts list: an Array of a Map per part, {name:, count:,
/// volume:, size: [x, y, z], density:, mass:} (nil where it has none).
pub fn meshBom(vm: *VM, receiver: value.Value) !value.Value {
    var solids: std.ArrayList(value.Value) = .empty;
    defer solids.deinit(vm.allocator);
    try solidsOf(vm, receiver, "bom", &solids);
    const parts = try parts_mod.collect(vm, vm.allocator, solids.items);
    defer vm.allocator.free(parts);

    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const rows = try scope.array();
    try rows.items.ensureTotalCapacity(vm.gc.trackingAllocator(), parts.len);
    for (parts) |part| rows.items.appendAssumeCapacity(try rowOf(vm, part));
    return value.Value.initObj(&rows.obj);
}

/// solid.mass / assembly.mass -> its mass in grams: each part's volume times its material's
/// density (`material(density:)`, g/cm³), as the parts list counts it, copies and all. A
/// part with no density is a ValueError naming it.
pub fn meshMass(vm: *VM, receiver: value.Value) !value.Value {
    var solids: std.ArrayList(value.Value) = .empty;
    defer solids.deinit(vm.allocator);
    try solidsOf(vm, receiver, "mass", &solids);
    const parts = try parts_mod.collect(vm, vm.allocator, solids.items);
    defer vm.allocator.free(parts);
    var total: f64 = 0;
    for (parts) |part| {
        const mass = part.mass() orelse {
            if (part.name) |name| return vm.fail(.ValueError, "mass: part '{s}' has no density; give it one with material(density:), in g/cm³", .{name});
            return vm.fail(.ValueError, "mass: the Solid has no density; give it one with material(density:), in g/cm³", .{});
        };
        total += mass * @as(f64, @floatFromInt(part.count));
    }
    return value.Value.initNumber(total);
}

/// `part` as a Map with Symbol keys (parts.FIELDS).
fn rowOf(vm: *VM, part: Part) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const row = try scope.map();
    const size = try scope.array();
    try size.items.ensureTotalCapacity(vm.gc.trackingAllocator(), part.size.len);
    for (part.size) |extent| size.items.appendAssumeCapacity(value.Value.initNumber(extent));
    const name = if (part.name) |text| try vm.allocateString(text) else value.Value.initNil();
    vm.push(name);
    const fields = [parts_mod.FIELDS.len]value.Value{
        name,
        value.Value.initNumber(@floatFromInt(part.count)),
        value.Value.initNumber(part.volume),
        value.Value.initObj(&size.obj),
        if (part.density()) |d| value.Value.initNumber(d) else value.Value.initNil(),
        if (part.mass()) |m| value.Value.initNumber(m) else value.Value.initNil(),
    };
    for (parts_mod.FIELDS, fields) |field, v| {
        const key = try vm.allocateSymbol(field);
        vm.push(key);
        try vm.mapSet(row, key, v);
    }
    return value.Value.initObj(&row.obj);
}

/// solid.named(name) -> the Solid, its part named `name` in the parts list. The shape is
/// the same: a name changes nothing a viewport or an export shows.
/// `solid.named(name)` and `sketch.named(name)`: the part's name in the parts list, or the
/// sketch's in a drawing.
pub fn meshNamed(vm: *VM, receiver: value.Value, name: []const u8) !value.Value {
    if (!receiver.isGeometry() and !receiver.isCrossSection()) return arguments.notDefinedFor(vm, "named", receiver);
    const id = try vm.dag_builder.internPartName(try arguments.requireNonBlankName(vm, name, "named"));
    if (receiver.isCrossSection()) return vm.allocateCrossSection(try vm.dag_builder.addSketchName(receiver.asCrossSection().dag_idx, id));
    return vm.allocateGeometry(.{ .symbolic = try vm.dag_builder.addSetName(receiver.asGeometry().dag_idx, id) });
}
