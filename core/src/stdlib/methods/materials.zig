const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const MaterialDef = @import("../../core/material.zig").MaterialDef;

pub fn meshMaterial(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;

    var mat_def = MaterialDef{};

    // Enforce that arguments are provided and the last argument is a kwargs Map
    if (args.len == 0 or !args[args.len - 1].isObject() or args[args.len - 1].asObj().obj_type != .map) {
        vm.reportError("ArgumentError: material() requires keyword arguments (e.g., color: \"#FF0000\").\n", .{});
        return error.RuntimeError;
    }

    const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[args.len - 1].asObj())));
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
    const material_id = @as(u32, @intCast(vm.materials.items.len));
    try vm.materials.append(vm.allocator, mat_def);

    const new_idx = try vm.dag_builder.addSetMaterial(receiver.asGeometry().dag_idx, material_id);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

// --- Chained Methods ---

pub fn meshHighlight(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    _ = args;
    if (!receiver.isGeometry()) return error.RuntimeError;

    const material_id = @as(u32, @intCast(vm.materials.items.len));
    // Pure semantic tagging. Let the viewer handle the visuals.
    try vm.materials.append(vm.allocator, .{ .role = .highlight });

    const new_idx = try vm.dag_builder.addSetMaterial(receiver.asGeometry().dag_idx, material_id);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshGhost(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    _ = args;
    if (!receiver.isGeometry()) return error.RuntimeError;

    const material_id = @as(u32, @intCast(vm.materials.items.len));
    // Pure semantic tagging
    try vm.materials.append(vm.allocator, .{ .role = .ghost });

    const new_idx = try vm.dag_builder.addSetMaterial(receiver.asGeometry().dag_idx, material_id);
    const ghost_geom = try vm.allocateGeometry(.{ .symbolic = new_idx });

    // Force JIT evaluation and push directly to the standalone display list
    const handle = try vm.ensureConcrete(ghost_geom);
    try vm.display_list.append(vm.allocator, handle);

    // Return NIL so it drops completely out of the CSG math tree!
    return value.Value.initNil();
}

// --- Global Block Modifiers ---

pub fn globalHighlight(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count == 0 or !args[0].isClosure()) return error.RuntimeError;

    const result = try vm.callClosureSync(args[0].asClosure(), &.{});
    if (!result.isGeometry()) return result;

    const material_id = @as(u32, @intCast(vm.materials.items.len));
    try vm.materials.append(vm.allocator, .{ .role = .highlight });

    const new_idx = try vm.dag_builder.addSetMaterial(result.asGeometry().dag_idx, material_id);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn globalGhost(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count == 0 or !args[0].isClosure()) return error.RuntimeError;

    const result = try vm.callClosureSync(args[0].asClosure(), &.{});
    if (!result.isGeometry()) return value.Value.initNil();

    const material_id = @as(u32, @intCast(vm.materials.items.len));
    try vm.materials.append(vm.allocator, .{ .role = .ghost });

    const new_idx = try vm.dag_builder.addSetMaterial(result.asGeometry().dag_idx, material_id);
    const ghost_geom = try vm.allocateGeometry(.{ .symbolic = new_idx });

    const handle = try vm.ensureConcrete(ghost_geom);
    try vm.display_list.append(vm.allocator, handle);

    return value.Value.initNil();
}
