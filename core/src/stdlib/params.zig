const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const parameters = @import("../core/parameters.zig");

/// Native implementation of the `param()` function.
/// Supports dual modes via arity overloading:
/// 1. Getter Mode (arg_count == 1): `param(:width)` -> Returns current value from DOD registry.
/// 2. Setter Mode (arg_count > 1): `param(:width, default: 20, validate: { min: 10, max: 100 })`
pub fn nativeParam(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    // Require at least one positional argument (the parameter name symbol or string)
    if (arg_count == 0) return error.RuntimeError;

    // --- Key Extraction & Symbol Coercion ---
    const key_val = args[0];
    if (!key_val.isObject() or (key_val.asObj().obj_type != .symbol and key_val.asObj().obj_type != .string)) {
        vm.reportError("Runtime Error: param() key must be a Symbol or String.\n", .{});
        return error.RuntimeError;
    }

    // Coerce raw Strings into interned Symbols for fast O(1) pointer identity checks
    const sym_key = if (key_val.asObj().obj_type == .symbol)
        key_val
    else
        try vm.allocateSymbol(@as(*value.ObjString, @alignCast(@fieldParentPtr("obj", key_val.asObj()))).chars);

    // Protect newly allocated or unreferenced symbol from Garbage Collection during execution
    vm.push(sym_key);
    defer _ = vm.pop();

    // =========================================================================
    // GETTER MODE: param(:width)
    // =========================================================================
    if (arg_count == 1) {
        const names = vm.param_registry.items(.name);
        for (names, 0..) |n, i| {
            if (vm.valuesEqual(n, sym_key)) {
                return vm.param_registry.items(.current_value)[i];
            }
        }

        // Strict Definition-Before-Use enforcement
        const sym_chars = @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", sym_key.asObj()))).chars;
        vm.reportError(
            "Runtime Error: Parameter ':{s}' used before definition. Define 'param(:{s}, default: ...)' earlier in the script.\n",
            .{ sym_chars, sym_chars },
        );
        return error.RuntimeError;
    }

    // =========================================================================
    // SETTER MODE: param(:width, default: 20, validate: { min: 10, max: 100 })
    // =========================================================================
    var default_val = value.Value.initNil();
    var min_val: f64 = std.math.nan(f64);
    var max_val: f64 = std.math.nan(f64);
    var p_type: parameters.ParamType = .number;

    // --- Extract Kwargs (`default:` and `validate:`) ---
    if (args[arg_count - 1].isObject() and args[arg_count - 1].asObj().obj_type == .map) {
        const kwargs_map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[arg_count - 1].asObj())));

        // Extract default value & infer primitive parameter type
        if (vm.findMapKeyByString(kwargs_map, "default")) |idx| {
            default_val = kwargs_map.values.items[idx];
            if (default_val.isNumber()) p_type = .number;
            if (default_val.isString()) p_type = .string;
            if (default_val.isBool()) p_type = .boolean;
            if (default_val.isObject() and default_val.asObj().obj_type == .symbol) p_type = .symbol;
        }

        // Extract validation rules map (`validate: { min: X, max: Y }`)
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

    // --- Determine Active Value ---
    // (In future passes, check if CLI/UI host injected a value for this symbol; fallback to default)
    const injected_val = default_val;

    // --- Strict Validation Guards ---
    if (p_type == .number) {
        if (!injected_val.isNumber()) {
            vm.reportError("Validation Error: Parameter ':{s}' expected a Number.\n", .{
                @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", sym_key.asObj()))).chars,
            });
            return error.RuntimeError;
        }
        const num = injected_val.asNumber();
        if (!std.math.isNan(min_val) and num < min_val) {
            vm.reportError("Validation Error: Parameter value {d} is less than minimum allowed ({d}).\n", .{ num, min_val });
            return error.RuntimeError;
        }
        if (!std.math.isNan(max_val) and num > max_val) {
            vm.reportError("Validation Error: Parameter value {d} exceeds maximum allowed ({d}).\n", .{ num, max_val });
            return error.RuntimeError;
        }
    }

    // --- Upsert (Update-or-Insert) into DOD Registry ---
    var existing_idx: ?usize = null;
    const names = vm.param_registry.items(.name);
    for (names, 0..) |n, i| {
        if (vm.valuesEqual(n, sym_key)) {
            existing_idx = i;
            break;
        }
    }

    if (existing_idx) |idx| {
        // UPDATE IN-PLACE: Prevents memory leaks and duplicate registry entries during re-execution
        vm.param_registry.items(.param_type)[idx] = p_type;
        vm.param_registry.items(.min_val)[idx] = min_val;
        vm.param_registry.items(.max_val)[idx] = max_val;

        // Safely release previous value ARC and retain updated active value
        const old_val = vm.param_registry.items(.current_value)[idx];
        vm.releaseValue(old_val);
        vm.retainValue(injected_val);
        vm.param_registry.items(.current_value)[idx] = injected_val;
    } else {
        // INSERT NEW: Retain reference counts so GC doesn't sweep values while in registry
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
    }

    return value.Value.initNil();
}
