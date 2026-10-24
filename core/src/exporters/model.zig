//! The model a script leaves: its final value's Solids, Sketches and Paths, an Assembly's
//! parts and Arrays of them (`collectModel`), whether a format can hold it
//! (`requireExportable`), its meshes (`modelParts`) and its parts list
//! (`billOfMaterials`, grouped by parts.zig).

const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const value = @import("../core/value.zig");
const geom = @import("../core/geometry_handle.zig");
const OPEN_PATH_HINT = @import("../core/path.zig").OPEN_PATH_HINT;
const ExportFormat = @import("format.zig").ExportFormat;
const parts_mod = @import("parts.zig");

/// How deep a model's Arrays of shapes inside Arrays are followed (an Array can hold itself).
pub const MAX_MODEL_NESTING = 64;
/// The most items an Array of the model may hold, so an item's number fits its path.
const MAX_MODEL_ITEMS = 1_000_000_000;

/// The meshes of the model the script left: its ghosts (the display list), then its
/// Solids (collectModel), each evaluated. The handles are borrowed (see VM.ensureConcrete).
pub fn modelParts(allocator: std.mem.Allocator, vm: *VM) !std.ArrayList(geom.GeometryHandle) {
    var model = try collectModel(allocator, vm);
    defer model.deinit(allocator);
    return handlesOf(allocator, vm, model.solids.items, model.ghosts);
}

/// `ghosts`, then the meshes of `solids` (evaluated; borrowed, see VM.ensureConcrete).
pub fn handlesOf(allocator: std.mem.Allocator, vm: *VM, solids: []const value.Value, ghosts: []const geom.GeometryHandle) !std.ArrayList(geom.GeometryHandle) {
    var handles: std.ArrayList(geom.GeometryHandle) = .empty;
    errdefer handles.deinit(allocator);
    try handles.ensureTotalCapacity(allocator, ghosts.len + solids.len);
    handles.appendSliceAssumeCapacity(ghosts);
    for (solids) |solid| handles.appendAssumeCapacity(try vm.ensureConcrete(solid));
    return handles;
}

/// The shapes the script left as its model: its final value, a Solid or a Sketch, an
/// Assembly's parts, or an Array's items, Arrays inside it included (they were dropped).
/// `collectModel` fills it and `requireExportable` says whether a format can hold it.
pub const Model = struct {
    solids: std.ArrayList(value.Value) = .empty,
    sketches: std.ArrayList(value.Value) = .empty,
    /// Open paths (`line`, `polyline`, `arc`): a drawing's, which no 3D format holds.
    paths: std.ArrayList(value.Value) = .empty,
    /// The ghosts the script showed (the display list; borrowed from the VM).
    ghosts: []const geom.GeometryHandle = &.{},
    /// The model's name: its Assembly's, if it is one.
    title: ?[]const u8 = null,

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        self.solids.deinit(allocator);
        self.sketches.deinit(allocator);
        self.paths.deinit(allocator);
    }

    pub fn shapeCount(self: *const Model) usize {
        return self.solids.items.len + self.sketches.items.len + self.paths.items.len;
    }
};

/// Whether `val` is what a script ends with to leave a model (collectModel may still refuse
/// an item of an Array): a Solid, a Sketch, a Path, an Assembly, an Array, or nil for none.
pub fn isModel(val: value.Value) bool {
    return val.isNil() or val.isGeometry() or val.isCrossSection() or val.isPath() or val.isAssembly() or val.isArray();
}

/// The model the script left, from its final value. A value that is no model raises in
/// the VM (a TypeError saying what it is) and fails with error.RuntimeError: an item that
/// isn't a shape, such as a Number, was silently left out, and nested Arrays with it.
pub fn collectModel(allocator: std.mem.Allocator, vm: *VM) !Model {
    var model: Model = .{ .ghosts = vm.display_list.items };
    errdefer model.deinit(allocator);
    const final_val = vm.finalValue();
    if (final_val.isNil()) return model;
    if (final_val.isAssembly()) model.title = final_val.asAssembly().name.chars;
    var path = ItemPath{};
    if (!try collectShapes(allocator, vm, &model, final_val, &path)) {
        return vm.fail(.TypeError, "the script's last value ({s}) is not a model: end it with a Solid, a Sketch, a Path, an Assembly or an Array of them", .{vm.typeName(final_val)});
    }
    return model;
}

/// Where an item is in the model's Arrays, for an error naming it: "item 2", "item 2.1".
const ItemPath = struct {
    buf: [MAX_MODEL_NESTING * ITEM_PATH_DIGITS]u8 = undefined,
    len: usize = 0,

    const ITEM_PATH_DIGITS = 12; // ".", then the digits of an index up to MAX_MODEL_ITEMS

    fn push(self: *ItemPath, index: usize) void {
        const written = std.fmt.bufPrint(self.buf[self.len..], "{s}{d}", .{ if (self.len == 0) "" else ".", index }) catch unreachable;
        self.len += written.len;
    }

    fn text(self: *const ItemPath) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Adds the shapes of `val` to `model`: a Solid, a Sketch, an Assembly's parts, or an
/// Array's items (recursively). False for a value that is none of those at the top; inside
/// an Array, such a value raises a TypeError naming its item.
fn collectShapes(allocator: std.mem.Allocator, vm: *VM, model: *Model, val: value.Value, path: *ItemPath) !bool {
    if (val.isGeometry()) {
        try model.solids.append(allocator, val);
    } else if (val.isCrossSection()) {
        try model.sketches.append(allocator, val);
    } else if (val.isPath()) {
        try model.paths.append(allocator, val);
    } else if (val.isAssembly()) {
        // Its Solids, and its assemblies' (assemble keeps them shallower than the limit)
        for (val.asAssembly().parts.items.items) |part| {
            if (part.isAssembly()) _ = try collectShapes(allocator, vm, model, part, path) else try model.solids.append(allocator, part);
        }
    } else if (val.isArray()) {
        if (path.len >= MAX_MODEL_NESTING * (ItemPath.ITEM_PATH_DIGITS - 1)) {
            return vm.fail(.ValueError, "the model's Arrays nest deeper than {d} levels", .{MAX_MODEL_NESTING});
        }
        for (val.asArray().items.items, 1..) |item, index| {
            if (index > MAX_MODEL_ITEMS) return vm.fail(.ValueError, "the model's Array holds more than {d} items", .{MAX_MODEL_ITEMS});
            const mark = path.len;
            defer path.len = mark;
            path.push(index);
            if (!try collectShapes(allocator, vm, model, item, path)) {
                return vm.fail(.TypeError, "the model's item {s} ({s}) is not a shape: a model holds Solids, Sketches, Paths and Arrays of them", .{ path.text(), vm.typeName(item) });
            }
        }
    } else return false;
    return true;
}

/// Whether `format` can hold `model`; raises in the VM (and fails with error.RuntimeError)
/// when it can't: a 3D format refuses a Sketch (extrude it), a Path (close or stroke it)
/// and a model with no Solid, unless the format shows ghosts and there are some; a 2D
/// format draws Sketches, Paths and Solids alike (the Solids projected onto XY) and refuses
/// only a model with none.
pub fn requireExportable(vm: *VM, model: *const Model, format: ExportFormat) !void {
    switch (format.dimension()) {
        .@"2d" => {
            if (model.shapeCount() == 0) {
                return vm.fail(.GeometryError, "the model holds no shape: nothing to draw as {s}", .{@tagName(format)});
            }
        },
        .@"3d" => {
            if (model.paths.items.len > 0) {
                if (model.paths.items.len == model.shapeCount()) {
                    return vm.fail(.TypeError, "the model holds only open paths: {s} (a 3D format) needs Solids; {s}, then extrude it", .{ @tagName(format), OPEN_PATH_HINT });
                }
                return vm.fail(.TypeError, "the model holds a Path, which {s} (a 3D format) can't hold: {s}, then extrude it", .{ @tagName(format), OPEN_PATH_HINT });
            }
            if (model.sketches.items.len > 0) {
                const which = if (model.solids.items.len == 0 and model.sketches.items.len == 1) "is" else "holds";
                return vm.fail(.TypeError, "the model {s} a Sketch, which {s} (a 3D format) can't hold: extrude it (.extrude(h)) to a Solid", .{ which, @tagName(format) });
            }
            if (model.solids.items.len == 0 and !(format.showsGhosts() and model.ghosts.len > 0)) {
                return vm.fail(.GeometryError, "the model holds no Solid: nothing to write as {s}", .{@tagName(format)});
            }
        },
    }
}

/// The parts list (parts.zig) of the model the script left (collectModel), as
/// `kupcad build --bom` writes it; raises in the VM when the model holds no Solid.
pub fn billOfMaterials(allocator: std.mem.Allocator, vm: *VM) ![]u8 {
    var model = try collectModel(allocator, vm);
    defer model.deinit(allocator);
    if (model.solids.items.len == 0) return vm.fail(.GeometryError, "the model holds no Solid: nothing for the parts list", .{});
    const parts = try parts_mod.collect(vm, allocator, model.solids.items);
    defer allocator.free(parts);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try parts_mod.writeJson(allocator, &out.writer, parts);
    return out.toOwnedSlice();
}
