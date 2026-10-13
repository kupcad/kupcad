const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const MaterialDef = @import("../../core/material.zig").MaterialDef;
const kernel = @import("../../kernel/kernel.zig");

pub fn meshMaterial(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;

    var mat_def = MaterialDef{};

    // Enforce that arguments are provided and the last argument is a kwargs Map
    if (args.len == 0 or !args[args.len - 1].isObject() or args[args.len - 1].asObj().obj_type != .map) {
        vm.reportError("ArgumentError: material() requires keyword arguments (e.g., color: \"#FF0000\").\n", .{});
        return error.RuntimeError;
    }

    const map: *value.ObjMap = @alignCast(@fieldParentPtr("obj", args[args.len - 1].asObj()));
    var it = map.map.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (k.isObject() and (k.asObj().obj_type == .string or k.asObj().obj_type == .symbol)) {
            const k_str = if (k.asObj().obj_type == .string)
                @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars
            else
                @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;

            const v = entry.value_ptr.*;
            if (std.mem.eql(u8, k_str, "color") and v.isString()) mat_def.color_hex = v.asString().chars;
            if (std.mem.eql(u8, k_str, "color") and v.isSymbol()) mat_def.color_hex = v.asSymbol().chars;
            if (std.mem.eql(u8, k_str, "alpha") and v.isNumber()) mat_def.alpha = v.asNumber();
            if (std.mem.eql(u8, k_str, "roughness") and v.isNumber()) mat_def.roughness = v.asNumber();
            if (std.mem.eql(u8, k_str, "metallic") and v.isNumber()) mat_def.metallic = v.asNumber();
            if (std.mem.eql(u8, k_str, "transmission") and v.isNumber()) mat_def.transmission = v.asNumber();
        }
    }

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

pub fn globalHighlight(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count == 0 or !args[0].isClosure()) return error.RuntimeError;

    const result = try vm.callClosureSync(args[0].asClosure(), &.{});
    if (!result.isGeometry()) return result;

    const material_id: u32 = @intCast(vm.materials.items.len);
    try vm.materials.append(vm.allocator, .{ .role = .highlight });

    const new_idx = try vm.dag_builder.addSetMaterial(result.asGeometry().dag_idx, material_id);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn globalGhost(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count == 0 or !args[0].isClosure()) return error.RuntimeError;

    const result = try vm.callClosureSync(args[0].asClosure(), &.{});
    if (!result.isGeometry()) return value.Value.initNil();

    const material_id: u32 = @intCast(vm.materials.items.len);
    try vm.materials.append(vm.allocator, .{ .role = .ghost });

    const new_idx = try vm.dag_builder.addSetMaterial(result.asGeometry().dag_idx, material_id);
    const ghost_geom = try vm.allocateGeometry(.{ .symbolic = new_idx });

    try appendToDisplayList(vm, ghost_geom);

    return value.Value.initNil();
}
