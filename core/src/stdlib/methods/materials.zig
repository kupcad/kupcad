const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const MaterialDef = @import("../../core/material.zig").MaterialDef;
const kernel = @import("../../kernel/kernel.zig");
const util = @import("util.zig");

pub fn meshMaterial(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;

    const parsed = try util.parseKwargs(struct {
        color: ?[]const u8 = null,
        alpha: ?f64 = null,
        roughness: ?f64 = null,
        metallic: ?f64 = null,
        transmission: ?f64 = null,
    }, vm, args, "material");
    if (parsed.positional.len == args.len) {
        _ = vm.raiseError(.ArgumentError, "material requires keyword arguments (e.g. color: \"#FF0000\")", .{});
        return error.RuntimeError;
    }
    const opts = parsed.opts;
    const defaults = MaterialDef{};
    const mat_def = MaterialDef{
        .color_hex = opts.color orelse defaults.color_hex,
        .alpha = opts.alpha orelse defaults.alpha,
        .roughness = opts.roughness orelse defaults.roughness,
        .metallic = opts.metallic orelse defaults.metallic,
        .transmission = opts.transmission orelse defaults.transmission,
    };

    // Insert into VM registry to get an ID
    const material_id: u32 = @intCast(vm.materials.items.len);
    try vm.materials.append(vm.allocator, mat_def);

    const new_idx = try vm.dag_builder.addSetMaterial(receiver.asGeometry().dag_idx, material_id);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

/// ensureConcrete only BORROWS the handle from vm.dag_cache, and nothing roots
/// `ghost_geom`, so the next GC would evict (free) it before export. The display
/// list therefore stores its own copy, destroyed in VM.deinit.
fn appendToDisplayList(vm: *VM, ghost_geom: value.Value) !void {
    const borrowed = try vm.ensureConcrete(ghost_geom);
    const owned = kernel.clone(borrowed) orelse return error.RuntimeError;
    vm.display_list.append(vm.allocator, owned) catch |err| {
        kernel.destruct(owned);
        return err;
    };
}

// --- Chained Methods ---

pub fn meshHighlight(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    _ = args;
    if (!receiver.isGeometry()) return error.RuntimeError;

    const material_id: u32 = @intCast(vm.materials.items.len);
    // Pure semantic tagging. Let the viewer handle the visuals.
    try vm.materials.append(vm.allocator, .{ .role = .highlight });

    const new_idx = try vm.dag_builder.addSetMaterial(receiver.asGeometry().dag_idx, material_id);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshGhost(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    _ = args;
    if (!receiver.isGeometry()) return error.RuntimeError;

    const material_id: u32 = @intCast(vm.materials.items.len);
    // Pure semantic tagging
    try vm.materials.append(vm.allocator, .{ .role = .ghost });

    const new_idx = try vm.dag_builder.addSetMaterial(receiver.asGeometry().dag_idx, material_id);
    const ghost_geom = try vm.allocateGeometry(.{ .symbolic = new_idx });

    // Force JIT evaluation and push directly to the standalone display list
    try appendToDisplayList(vm, ghost_geom);

    // Return NIL so it drops completely out of the CSG math tree!
    return value.Value.initNil();
}

// --- Global Block Modifiers ---

/// highlight { ... } -> the block's Solid, tagged for the viewer to show in high contrast
pub fn globalHighlight(vm: *VM, block: ?*value.ObjClosure) !value.Value {
    const result = try vm.callClosureSync(try requireBlock(vm, block, "highlight"), &.{});
    if (!result.isGeometry()) return result;

    const material_id: u32 = @intCast(vm.materials.items.len);
    try vm.materials.append(vm.allocator, .{ .role = .highlight });

    const new_idx = try vm.dag_builder.addSetMaterial(result.asGeometry().dag_idx, material_id);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

/// ghost { ... } -> shows the block's Solid as a translucent reference, outside the model
pub fn globalGhost(vm: *VM, block: ?*value.ObjClosure) !value.Value {
    const result = try vm.callClosureSync(try requireBlock(vm, block, "ghost"), &.{});
    if (!result.isGeometry()) return value.Value.initNil();

    const material_id: u32 = @intCast(vm.materials.items.len);
    try vm.materials.append(vm.allocator, .{ .role = .ghost });

    const new_idx = try vm.dag_builder.addSetMaterial(result.asGeometry().dag_idx, material_id);
    const ghost_geom = try vm.allocateGeometry(.{ .symbolic = new_idx });

    try appendToDisplayList(vm, ghost_geom);

    return value.Value.initNil();
}

fn requireBlock(vm: *VM, block: ?*value.ObjClosure, comptime name: []const u8) !*value.ObjClosure {
    return block orelse {
        _ = vm.raiseError(.ArgumentError, name ++ " requires a block", .{});
        return error.RuntimeError;
    };
}
