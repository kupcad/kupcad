const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const parameters = @import("../core/parameters.zig");
const chunk = @import("../vm/chunk.zig");

const number_param = @import("../core/params/number.zig");
const boolean_param = @import("../core/params/boolean.zig");
const string_param = @import("../core/params/string.zig");
const choice_param = @import("../core/params/choice.zig");

// Formats precise line/col error messages for standard halting
fn reportValidationFail(vm_ctx: *VM, loc: []const u8, comptime fmt: []const u8, err_args: anytype) error{RuntimeError} {
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, err_args) catch "Validation Error.";
    vm_ctx.reportError("\n[Runtime Error] Parameter Validation Failed\n{s}Error: {s}\n", .{ loc, msg });
    return error.RuntimeError;
}

pub fn nativeParam(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    if (arg_count == 0) return error.RuntimeError;

    const key_val = args[0];
    if (!key_val.isObject() or (key_val.asObj().obj_type != .symbol and key_val.asObj().obj_type != .string)) {
        vm.reportError("Runtime Error: param() key must be a Symbol or String.\n", .{});
        return error.RuntimeError;
    }

    const sym_key = if (key_val.asObj().obj_type == .symbol)
        key_val
    else
        try vm.allocateSymbol(@as(*value.ObjString, @alignCast(@fieldParentPtr("obj", key_val.asObj()))).chars);

    vm.push(sym_key);
    defer _ = vm.pop();

    const sym_chars = @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", sym_key.asObj()))).chars;

    // --- GETTER MODE ---
    if (arg_count == 1) {
        const names = vm.param_registry.items(.name);
        for (names, 0..) |n, i| {
            if (vm.valuesEqual(n, sym_key)) {
                return vm.param_registry.items(.current_value)[i];
            }
        }
        vm.reportError("Runtime Error: Parameter ':{s}' used before definition.\n", .{sym_chars});
        return error.RuntimeError;
    }

    // --- EXTRACT STACK TRACE LOCATION ---
    var loc_buf: [128]u8 = undefined;
    var loc_prefix: []const u8 = "";
    if (vm.frames.items.len > 0) {
        const frame = &vm.frames.items[vm.frames.items.len - 1];
        if (frame.closure.function.chunk) |chunk_ptr| {
            const exec_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(chunk_ptr)));
            const instruction_ip = if (frame.ip > 0) frame.ip - 1 else 0;
            const source_offset = exec_chunk.getOffset(instruction_ip);
            if (vm.line_index) |li| {
                const line = li.getLine(source_offset) + 1;
                const col = li.getUtf8Column(source_offset) + 1;
                loc_prefix = std.fmt.bufPrint(&loc_buf, "  --> line {d}, col {d}\n   | \n   | ", .{ line, col }) catch "";
            }
        }
    }

    // --- SETTER MODE (Extract Configs) ---
    var default_val = value.Value.initNil();
    var min_val: f64 = std.math.nan(f64);
    var max_val: f64 = std.math.nan(f64);
    var p_type: parameters.ParamType = .number;
    var choices_array: ?*value.ObjArray = null;

    if (args[arg_count - 1].isObject() and args[arg_count - 1].asObj().obj_type == .map) {
        const kwargs_map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[arg_count - 1].asObj())));

        if (vm.findMapKeyByString(kwargs_map, "default")) |idx| {
            default_val = kwargs_map.values.items[idx];
            if (default_val.isNumber()) p_type = .number;
            if (default_val.isString()) p_type = .string;
            if (default_val.isBool()) p_type = .boolean;
            if (default_val.isObject() and default_val.asObj().obj_type == .symbol) p_type = .symbol;
        }

        if (vm.findMapKeyByString(kwargs_map, "validate")) |v_idx| {
            const val_map_val = kwargs_map.values.items[v_idx];
            if (val_map_val.isObject() and val_map_val.asObj().obj_type == .map) {
                const val_map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", val_map_val.asObj())));
                if (vm.findMapKeyByString(val_map, "min")) |min_idx| {
                    if (val_map.values.items[min_idx].isNumber()) min_val = val_map.values.items[min_idx].asNumber();
                }
                if (vm.findMapKeyByString(val_map, "max")) |max_idx| {
                    if (val_map.values.items[max_idx].isNumber()) max_val = val_map.values.items[max_idx].asNumber();
                }
                if (vm.findMapKeyByString(val_map, "in")) |in_idx| {
                    const in_val = val_map.values.items[in_idx];
                    if (in_val.isObject() and in_val.asObj().obj_type == .array) {
                        choices_array = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", in_val.asObj())));
                    }
                }
            }
        }
    }

    // --- CLI / HOST INJECTION ---
    var injected_val = default_val;
    if (vm.globals.get("params")) |global_params| {
        if (global_params.isObject() and global_params.asObj().obj_type == .map) {
            const p_map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", global_params.asObj())));
            if (vm.findMapKey(p_map, sym_key)) |idx| {
                injected_val = p_map.values.items[idx];
            }
        }
    }

    // --- MODULAR NORMALIZATION & VALIDATION ---
    switch (p_type) {
        .number => {
            const num = number_param.normalize(injected_val) catch {
                return reportValidationFail(vm, loc_prefix, "Parameter ':{s}' expected a Number.", .{sym_chars});
            };
            injected_val = value.Value.initNumber(num);

            number_param.validate(num, min_val, max_val) catch |err| {
                switch (err) {
                    error.BelowMin => return reportValidationFail(vm, loc_prefix, "Parameter ':{s}' value {d} is below minimum ({d}).", .{ sym_chars, num, min_val }),
                    error.AboveMax => return reportValidationFail(vm, loc_prefix, "Parameter ':{s}' value {d} exceeds maximum ({d}).", .{ sym_chars, num, max_val }),
                    else => unreachable,
                }
            };
        },
        .boolean => {
            const b = boolean_param.normalize(injected_val) catch {
                return reportValidationFail(vm, loc_prefix, "Parameter ':{s}' expected a Boolean.", .{sym_chars});
            };
            injected_val = value.Value.initBool(b);
        },
        .string, .symbol => {
            const str = string_param.normalize(injected_val) catch {
                return reportValidationFail(vm, loc_prefix, "Parameter ':{s}' expected a String.", .{sym_chars});
            };
            injected_val = try vm.allocateString(str);
        },
    }

    if (choices_array) |arr| {
        choice_param.validate(vm, injected_val, arr) catch {
            return reportValidationFail(vm, loc_prefix, "Parameter ':{s}' value is not in the allowed choices.", .{sym_chars});
        };
    }

    // --- DOD REGISTRY UPSERT ---
    var existing_idx: ?usize = null;
    const names = vm.param_registry.items(.name);
    for (names, 0..) |n, i| {
        if (vm.valuesEqual(n, sym_key)) {
            existing_idx = i;
            break;
        }
    }

    if (existing_idx) |idx| {
        vm.param_registry.items(.param_type)[idx] = p_type;
        vm.param_registry.items(.min_val)[idx] = min_val;
        vm.param_registry.items(.max_val)[idx] = max_val;

        const old_val = vm.param_registry.items(.current_value)[idx];
        vm.releaseValue(old_val);
        vm.retainValue(injected_val);
        vm.param_registry.items(.current_value)[idx] = injected_val;
    } else {
        vm.retainValue(sym_key);
        vm.retainValue(injected_val);
        try vm.param_registry.append(vm.allocator, .{
            .name = sym_key,
            .param_type = p_type,
            .current_value = injected_val,
            .min_val = min_val,
            .max_val = max_val,
            .choices = null, // Extractor schema handles serialization; runtime just needs validation block
        });
    }

    return value.Value.initNil();
}
