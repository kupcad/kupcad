const std = @import("std");
const value = @import("../../core/value.zig");
const vm_mod = @import("../../vm/vm.zig");
const MaterialDef = vm_mod.MaterialDef;
const VM = vm_mod.VM;

pub fn meshMaterial(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return error.RuntimeError;

    var mat_def = MaterialDef{};

    // Enforce that arguments are provided and the last argument is a kwargs Map
    if (args.len == 0 or !args[args.len - 1].isObject() or args[args.len - 1].asObj().obj_type != .map) {
        vm.reportError("ArgumentError: material() requires keyword arguments (e.g., color: \"#FF0000\").\n", .{});
        return error.RuntimeError;
    }

    const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[args.len - 1].asObj())));
    for (map.keys.items, 0..) |k, i| {
        if (k.isObject() and (k.asObj().obj_type == .string or k.asObj().obj_type == .symbol)) {
            const k_str = if (k.asObj().obj_type == .string)
                @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars
            else
                @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;

            const v = map.values.items[i];
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
