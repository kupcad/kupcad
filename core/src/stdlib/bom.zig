//! The parts-list methods: `bom` on a Solid or an Assembly lists the parts its Solids are
//! copies of (exporters/parts.zig groups and measures them), and `named` names a Solid's
//! part, or a Sketch for a drawing.

const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const HandleScope = @import("../vm/scope.zig").HandleScope;
const util = @import("methods/util.zig");
const parts_mod = @import("../exporters/parts.zig");
const Part = parts_mod.Part;

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
    const parts = try parts_mod.collect(vm, vm.allocator, try solidsOf(vm, receiver, "bom", &single));
    defer vm.allocator.free(parts);

    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const rows = try scope.array();
    try rows.items.ensureTotalCapacity(vm.gc.trackingAllocator(), parts.len);
    for (parts) |part| rows.items.appendAssumeCapacity(try rowOf(vm, part));
    return value.Value.initObj(&rows.obj);
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
    if (!receiver.isGeometry() and !receiver.isCrossSection()) return util.notDefinedFor(vm, "named", receiver);
    const id = try vm.dag_builder.internPartName(try util.requireNonBlankName(vm, name, "named"));
    if (receiver.isCrossSection()) return vm.allocateCrossSection(try vm.dag_builder.addSketchName(receiver.asCrossSection().dag_idx, id));
    return vm.allocateGeometry(.{ .symbolic = try vm.dag_builder.addSetName(receiver.asGeometry().dag_idx, id) });
}
