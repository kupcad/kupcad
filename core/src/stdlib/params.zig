//! The `param` built-in (`nativeParam`): `param(:name)` reads a parameter, and with
//! `default:` and `validate:` declares it, taking the host's injected value over the default,
//! checking its type, range and choices with `core/params/`, and recording it in the VM's
//! parameter registry.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const parameters = @import("../core/parameters.zig");
const util = @import("methods/util.zig");

const number_param = @import("../core/params/number.zig");
const boolean_param = @import("../core/params/boolean.zig");
const string_param = @import("../core/params/string.zig");
const choice_param = @import("../core/params/choice.zig");

/// param(:name) reads a parameter; param(:name, default: v, validate: { min:, max:, in: })
/// declares it, taking the host's injected value (`--param name=v`) over the default.
pub fn nativeParam(vm: *VM, args: []const value.Value) anyerror!value.Value {
    const parsed = try util.parseKwargs(struct { default: ?value.Value = null, validate: ?value.Value = null }, vm, args, "param");
    if (parsed.positional.len != 1) {
        return vm.fail(.ArgumentError, "param expects a parameter name (and keywords), got {d} positional arguments", .{parsed.positional.len});
    }

    const name = try util.requireName(vm, parsed.positional[0], "param", "the parameter name");
    const sym_key = try vm.allocateSymbol(name);
    vm.push(sym_key);
    defer _ = vm.pop();
    const sym_chars = sym_key.asSymbol().chars;

    // --- GETTER MODE ---
    if (args.len == 1) {
        if (vm.param_lookup.get(sym_key)) |idx| {
            return vm.param_registry.items(.current_value)[idx];
        }
        return vm.fail(.NameError, "parameter :{s} is used before it is defined", .{sym_chars});
    }

    // --- SETTER MODE (Extract Configs) ---
    const default_val = parsed.opts.default orelse value.Value.initNil();
    var p_type: parameters.ParamType = .number;
    if (default_val.isNumber()) p_type = .number;
    if (default_val.isString()) p_type = .string;
    if (default_val.isBool()) p_type = .boolean;
    if (default_val.isSymbol()) p_type = .symbol;

    var min_val: f64 = std.math.nan(f64);
    var max_val: f64 = std.math.nan(f64);
    var choices_array: ?*value.ObjArray = null;
    if (parsed.opts.validate) |rules| {
        if (!rules.isMap()) {
            return vm.fail(.TypeError, "param expects a Map for validate, got {s}", .{util.typeName(vm, rules)});
        }
        const checks = try util.parseKwargs(struct { min: ?f64 = null, max: ?f64 = null, in: ?value.Value = null }, vm, &.{rules}, "param validate");
        if (checks.opts.min) |n| min_val = n;
        if (checks.opts.max) |n| max_val = n;
        if (checks.opts.in) |choices| {
            _ = try util.requireArray(vm, choices, "param validate", "in");
            choices_array = choices.asArray();
        }
    }

    // --- CLI / HOST INJECTION ---
    var injected_val = default_val;
    if (vm.globals.get("params")) |global_params| {
        if (global_params.isObject() and global_params.asObj().obj_type == .map) {
            const p_map: *value.ObjMap = @alignCast(@fieldParentPtr("obj", global_params.asObj()));
            if (vm.findMapKey(p_map, sym_key)) |idx| {
                injected_val = p_map.map.values()[idx];
            }
        }
    }

    // --- MODULAR NORMALIZATION & VALIDATION ---
    switch (p_type) {
        .number => {
            const num = number_param.normalize(injected_val) catch {
                return vm.fail(.TypeError, "parameter :{s} expects a number", .{sym_chars});
            };
            injected_val = value.Value.initNumber(num);

            number_param.validate(num, min_val, max_val) catch |err| {
                switch (err) {
                    error.BelowMin => return vm.fail(.ValueError, "parameter :{s} value {f} is below its minimum {f}", .{ sym_chars, value.fmtNumber(num), value.fmtNumber(min_val) }),
                    error.AboveMax => return vm.fail(.ValueError, "parameter :{s} value {f} is above its maximum {f}", .{ sym_chars, value.fmtNumber(num), value.fmtNumber(max_val) }),
                    else => unreachable,
                }
            };
        },
        .boolean => {
            const b = boolean_param.normalize(injected_val) catch {
                return vm.fail(.TypeError, "parameter :{s} expects true or false", .{sym_chars});
            };
            injected_val = value.Value.initBool(b);
        },
        .string, .symbol => {
            const str = string_param.normalize(injected_val) catch {
                return vm.fail(.TypeError, "parameter :{s} expects a String", .{sym_chars});
            };
            injected_val = try vm.allocateString(str);
        },
    }

    if (choices_array) |arr| {
        choice_param.validate(vm, injected_val, arr) catch {
            return vm.fail(.ValueError, "parameter :{s} value is not one of its allowed choices", .{sym_chars});
        };
    }

    // --- DOD REGISTRY UPSERT ---
    if (vm.param_lookup.get(sym_key)) |idx| {
        vm.param_registry.items(.param_type)[idx] = p_type;
        vm.param_registry.items(.min_val)[idx] = min_val;
        vm.param_registry.items(.max_val)[idx] = max_val;
        vm.param_registry.items(.current_value)[idx] = injected_val;
    } else {
        const new_idx = vm.param_registry.items(.name).len;
        try vm.param_registry.append(vm.allocator, .{
            .name = sym_key,
            .param_type = p_type,
            .current_value = injected_val,
            .min_val = min_val,
            .max_val = max_val,
            .choices = null, // Extractor schema handles serialization; runtime just needs validation block
        });
        // Cache the index for O(1) reads
        try vm.param_lookup.put(vm.allocator, sym_key, new_idx);
    }

    return injected_val;
}
