const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const parameters = @import("../core/parameters.zig");

pub fn nativeParam(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (arg_count == 0) return error.RuntimeError;

    // Get the Parameter Name
    const key_val = args[0];
    if (!key_val.isObject() or (key_val.asObj().obj_type != .symbol and key_val.asObj().obj_type != .string)) {
        vm.reportError("Runtime Error: param() key must be a Symbol or String.\n", .{});
        return error.RuntimeError;
    }

    // Convert to Symbol for fast identity comparisons
    const sym_key = if (key_val.asObj().obj_type == .symbol)
        key_val
    else
        try vm.allocateSymbol(@as(*value.ObjString, @alignCast(@fieldParentPtr("obj", key_val.asObj()))).chars);

    vm.push(sym_key); // Protect from GC
    defer _ = vm.pop();

    // ==========================================
    // GETTER MODE: param(:width)
    // ==========================================
    if (arg_count == 1) {
        const names = vm.param_registry.items(.name);
        for (names, 0..) |n, i| {
            if (vm.valuesEqual(n, sym_key)) {
                return vm.param_registry.items(.current_value)[i];
            }
        }
        const sym_chars = @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", sym_key.asObj()))).chars;
        vm.reportError("Runtime Error: Parameter '{s}' is not defined.\n", .{sym_chars});
        return error.RuntimeError;
    }

    // ==========================================
    // SETTER MODE: param(:width, default: 20)
    // ==========================================
    var default_val = value.Value.initNil();
    var min_val: f64 = std.math.nan(f64);
    var max_val: f64 = std.math.nan(f64);
    var p_type: parameters.ParamType = .number;

    if (arg_count > 1 and args[arg_count - 1].isObject() and args[arg_count - 1].asObj().obj_type == .map) {
        const kwargs_map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[arg_count - 1].asObj())));

        if (vm.findMapKeyByString(kwargs_map, "default")) |idx| {
            default_val = kwargs_map.values.items[idx];
            if (default_val.isNumber()) p_type = .number;
            if (default_val.isString()) p_type = .string;
            if (default_val.isBool()) p_type = .boolean;
        }

        if (vm.findMapKeyByString(kwargs_map, "validate")) |v_idx| {
            const val_map_val = kwargs_map.values.items[v_idx];
            if (val_map_val.isObject() and val_map_val.asObj().obj_type == .map) {
                const val_map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", val_map_val.asObj())));

                if (vm.findMapKeyByString(val_map, "min")) |min_idx| {
                    if (val_map.values.items[min_idx].isNumber()) {
                        min_val = val_map.values.items[min_idx].asNumber();
                    }
                }
                if (vm.findMapKeyByString(val_map, "max")) |max_idx| {
                    if (val_map.values.items[max_idx].isNumber()) {
                        max_val = val_map.values.items[max_idx].asNumber();
                    }
                }
            }
        }
    }

    // Inject Value (For now, use default. We will wire up CLI injection later)
    const injected_val = default_val;

    // Strict Validation
    if (p_type == .number) {
        if (!injected_val.isNumber()) {
            vm.reportError("Validation Error: Parameter expected a Number.\n", .{});
            return error.RuntimeError;
        }
        const num = injected_val.asNumber();
        if (!std.math.isNan(min_val) and num < min_val) {
            vm.reportError("Validation Error: Value {d} is less than minimum allowed ({d}).\n", .{ num, min_val });
            return error.RuntimeError;
        }
        if (!std.math.isNan(max_val) and num > max_val) {
            vm.reportError("Validation Error: Value {d} exceeds maximum allowed ({d}).\n", .{ num, max_val });
            return error.RuntimeError;
        }
    }

    // Save to the DOD Registry
    vm.retainValue(sym_key);
    vm.retainValue(injected_val);

    try vm.param_registry.append(vm.allocator, .{
        .name = sym_key,
        .param_type = p_type,
        .current_value = injected_val,
        .min_val = min_val,
        .max_val = max_val,
        .choices = null,
    });

    return value.Value.initNil();
}
