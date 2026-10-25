//! The `param` built-in (`nativeParam`): `param(:name)` reads a parameter, and with
//! `default:` and `validate:` declares it, taking the host's injected value over the default,
//! reading it as its default's type (`readNumber`, `readBoolean`), checking its range and
//! choices, and recording it in the VM's parameter registry. A value it refuses names its
//! parameter in the run's report (`refuse`), for a host's control to mark.

const std = @import("std");
const value = @import("../core/value.zig");
const vm_mod = @import("../vm/vm.zig");
const VM = vm_mod.VM;
const parameters = @import("../core/parameters.zig");
const arguments = @import("arguments.zig");

/// param(:name) reads a parameter; param(:name, default: v, validate: { min:, max:, in: })
/// declares it, taking the host's value (`-p name=text`, `-P file.json`) over the default
/// and reading it as the default's type: text from `-p` becomes a number, a boolean, a
/// String or a Symbol as the parameter is one. `step:`, `unit:`, `group:`, `title:` and
/// `description:` are for a host's controls.
pub fn nativeParam(vm: *VM, args: []const value.Value) anyerror!value.Value {
    const parsed = try arguments.parseKwargs(struct {
        default: ?value.Value = null,
        validate: ?value.Value = null,
        // For a host's controls (`kupcad doc`): checked here, not applied to the value
        step: ?f64 = null,
        unit: ?[]const u8 = null,
        group: ?[]const u8 = null,
        title: ?[]const u8 = null,
        description: ?[]const u8 = null,
    }, vm, args, "param");
    if (parsed.positional.len != 1) {
        return vm.fail(.ArgumentError, "param expects a parameter name (and keywords), got {d} positional arguments", .{parsed.positional.len});
    }

    const name = try arguments.requireName(vm, parsed.positional[0], "param", "the parameter name");
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

    if (parsed.opts.step) |step| {
        if (!(step > 0) or !std.math.isFinite(step)) return vm.fail(.ValueError, "parameter :{s} step must be a number greater than 0, got {f}", .{ sym_chars, value.fmtNumber(step) });
    }
    if (p_type != .number and (parsed.opts.step != null or parsed.opts.unit != null)) {
        return vm.fail(.ArgumentError, "parameter :{s} is a {s} by its default, and {s} is for a number", .{ sym_chars, @tagName(p_type), if (parsed.opts.step != null) "step:" else "unit:" });
    }

    var min_val: f64 = std.math.nan(f64);
    var max_val: f64 = std.math.nan(f64);
    var choices_array: ?*value.ObjArray = null;
    if (parsed.opts.validate) |rules| {
        if (!rules.isMap()) {
            return vm.fail(.TypeError, "param expects a Map for validate, got {s}", .{arguments.typeName(vm, rules)});
        }
        const checks = try arguments.parseKwargs(struct { min: ?f64 = null, max: ?f64 = null, in: ?value.Value = null }, vm, &.{rules}, "param validate");
        if (checks.opts.min) |n| min_val = n;
        if (checks.opts.max) |n| max_val = n;
        if (checks.opts.in) |choices| {
            _ = try arguments.requireArray(vm, choices, "param validate", "in");
            choices_array = choices.asArray();
        }
    }

    // --- CLI / HOST INJECTION ---
    var injected_val = default_val;
    if (vm.globals.get("params")) |global_params| {
        if (global_params.isMap()) {
            const p_map = global_params.asMap();
            if (vm.findMapKey(p_map, sym_key)) |idx| {
                injected_val = p_map.map.values()[idx];
            }
        }
    }

    // --- MODULAR NORMALIZATION & VALIDATION ---
    switch (p_type) {
        .number => {
            const num = readNumber(injected_val) orelse return typeMismatch(vm, sym_chars, "a number", injected_val);
            injected_val = value.Value.initNumber(num);
            // An unset bound is NaN, which no comparison passes
            if (num < min_val) return refuse(vm, sym_chars, .ValueError, "parameter :{s} value {f} is below its minimum {f}", .{ sym_chars, value.fmtNumber(num), value.fmtNumber(min_val) });
            if (num > max_val) return refuse(vm, sym_chars, .ValueError, "parameter :{s} value {f} is above its maximum {f}", .{ sym_chars, value.fmtNumber(num), value.fmtNumber(max_val) });
        },
        .boolean => {
            const b = readBoolean(injected_val) orelse return typeMismatch(vm, sym_chars, "true or false", injected_val);
            injected_val = value.Value.initBool(b);
        },
        // A symbol parameter's value is a Symbol: a String compared unequal to the symbols in
        // its `in:` choices, so `param(:size, default: :m3, validate: { in: [:m3, :m4] })`
        // refused even its own default.
        .string => {
            const str = injected_val.nameChars() orelse return typeMismatch(vm, sym_chars, "a String", injected_val);
            injected_val = try vm.allocateString(str);
        },
        .symbol => {
            const str = injected_val.nameChars() orelse return typeMismatch(vm, sym_chars, "a Symbol", injected_val);
            injected_val = try vm.allocateSymbol(str);
        },
    }

    if (choices_array) |arr| {
        for (arr.items.items) |choice| {
            if (vm.valuesEqual(injected_val, choice)) break;
        } else return refuse(vm, sym_chars, .ValueError, "parameter :{s} value is not one of its allowed choices", .{sym_chars});
    }

    // Choices aren't kept: the extractor's schema lists them, and the run checked the value
    try vm.declareParam(.{
        .name = sym_key,
        .param_type = p_type,
        .current_value = injected_val,
        .min_val = min_val,
        .max_val = max_val,
        .choices = null,
    });

    return injected_val;
}

/// A number parameter's value: a number, or text from the host (`-p width=10.5`) that reads
/// as a finite one, as a script's numbers are (parseFloat reads "inf" and "nan" too).
fn readNumber(val: value.Value) ?f64 {
    if (val.isNumber()) return val.asNumber();
    if (!val.isString()) return null;
    const num = std.fmt.parseFloat(f64, val.asString().chars) catch return null;
    return if (std.math.isFinite(num)) num else null;
}

/// A boolean parameter's value: true or false, the numbers 1 and 0, or the text "true",
/// "false", "1" and "0".
fn readBoolean(val: value.Value) ?bool {
    if (val.isBool()) return val.asBool();
    if (val.isNumber()) {
        if (val.asNumber() == 1) return true;
        if (val.asNumber() == 0) return false;
    }
    if (val.isString()) {
        const text = val.asString().chars;
        if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1")) return true;
        if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0")) return false;
    }
    return null;
}

/// The TypeError for a value parameter `name` can't take: "parameter :w expects a number,
/// got "abc"", the text quoted as `-p` gave it.
fn typeMismatch(vm: *VM, name: []const u8, expected: []const u8, got: value.Value) error{RuntimeError} {
    if (got.isString()) return refuse(vm, name, .TypeError, "parameter :{s} expects {s}, got \"{s}\"", .{ name, expected, got.asString().chars });
    return refuse(vm, name, .TypeError, "parameter :{s} expects {s}, got {s}", .{ name, expected, arguments.typeName(vm, got) });
}

/// The error of the value parameter `name` refused, `kind` saying `fmt`, with the
/// parameter noted in the run's report as the one that stopped it.
fn refuse(vm: *VM, name: []const u8, comptime kind: vm_mod.ErrorKind, comptime fmt: []const u8, args: anytype) error{RuntimeError} {
    // The report only names it: out of memory, the run still fails with its own error
    vm.report.refuse(vm.allocator, name) catch {};
    return vm.fail(kind, fmt, args);
}
