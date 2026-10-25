//! The `param` built-in (`nativeParam`): `param(:name)` reads a parameter, and with keywords
//! declares it, taking the host's injected value over the default, reading it as the
//! parameter's type (`typeOf`: `type:`'s, else the default's), checking its range and
//! choices, and recording it in the VM's parameter registry. A value it refuses names its
//! parameter in the run's report (`refuse`), for a host's control to mark.

const std = @import("std");
const value = @import("../core/value.zig");
const vm_mod = @import("../vm/vm.zig");
const VM = vm_mod.VM;
const parameters = @import("../core/parameters.zig");
const param_values = @import("../core/param_values.zig");
const ParamValue = param_values.ParamValue;
const json_input = @import("../core/json_input.zig");
const HandleScope = @import("../vm/scope.zig").HandleScope;
const arguments = @import("arguments.zig");

/// param(:name) reads a parameter; param(:name, default: v, type: :t, validate: { min:, max:,
/// in: }) declares it, taking the host's value (`-p name=text`, `-P file.json`) over the
/// default and reading it as the parameter's type (`typeOf`): text from `-p` becomes a
/// number, a boolean, a String, a Symbol or an Array as the parameter is one. One with no
/// default is nil until a host gives it a value. `step:`, `unit:`, `group:`, `title:` and
/// `description:` are for a host's controls.
pub fn nativeParam(vm: *VM, args: []const value.Value) anyerror!value.Value {
    const parsed = try arguments.parseKwargs(struct {
        default: ?value.Value = null,
        type: ?value.Value = null,
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

    const default_val = parsed.opts.default orelse value.Value.initNil();
    const choices = if (choices_array) |arr| arr.items.items else &.{};
    const p_type = try typeOf(vm, sym_chars, parsed.opts.type, default_val, choices);

    if (parsed.opts.step) |step| {
        if (!(step > 0) or !std.math.isFinite(step)) return vm.fail(.ValueError, "parameter :{s} step must be a number greater than 0, got {f}", .{ sym_chars, value.fmtNumber(step) });
    }
    if (p_type != .number and p_type != .array and (parsed.opts.step != null or parsed.opts.unit != null)) {
        return vm.fail(.ArgumentError, "parameter :{s} is a {s}, and {s} is for numbers", .{ sym_chars, @tagName(p_type), if (parsed.opts.step != null) "step:" else "unit:" });
    }

    // --- CLI / HOST INJECTION ---
    var injected_val = default_val;
    if (vm.globals.get("params")) |global_params| {
        if (global_params.isMap()) {
            const p_map = global_params.asMap();
            if (vm.findMapKey(p_map, sym_key)) |idx| {
                injected_val = p_map.table.values()[idx];
            }
        }
    }

    // --- MODULAR NORMALIZATION & VALIDATION ---
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    // Nil, given no value: none to check
    if (!injected_val.isNil()) switch (p_type) {
        .array => injected_val = try readArray(vm, sym_chars, injected_val, .{
            .kind = sharedKind(if (default_val.isArray()) default_val.asArray().items.items else choices),
            .min = min_val,
            .max = max_val,
            .choices = choices_array,
        }),
        else => {
            injected_val = try readScalar(vm, .{ .name = sym_chars }, p_type, injected_val, min_val, max_val);
            if (choices_array) |arr| if (!isChoice(vm, arr, injected_val)) {
                return refuse(vm, sym_chars, .ValueError, "parameter :{s} value is not one of its allowed choices", .{sym_chars});
            };
        },
    };
    // Made here, it is rooted while the registry takes it
    vm.push(injected_val);

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

/// A host's value, `v`, as the script value `param()` reads: text as a String (read by the
/// parameter's type there), an array as an Array of such values. Unrooted: the caller roots
/// it before allocating again.
pub fn scriptValueOf(vm: *VM, v: ParamValue) !value.Value {
    switch (v) {
        .number => |n| return value.Value.initNumber(n),
        .boolean => |b| return value.Value.initBool(b),
        .text => |t| return vm.allocateString(t),
        .array => |items| {
            var scope = HandleScope.init(vm);
            defer scope.deinit();
            const array = try scope.array();
            try array.items.ensureTotalCapacity(vm.gc.trackingAllocator(), items.len);
            // Each element is in the Array before another is made, which may collect
            for (items) |item| array.items.appendAssumeCapacity(try scriptValueOf(vm, item));
            return value.Value.initObj(&array.obj);
        },
    }
}

/// A parameter's type: `type:`'s, else its default's, else that of the choices `in:` lists
/// (when they are all of one), else a String's: one with neither is text until a host
/// gives it some.
fn typeOf(vm: *VM, name: []const u8, named: ?value.Value, default_val: value.Value, choices: []const value.Value) !parameters.ParamType {
    const of_default: ?parameters.ParamType = if (default_val.isNil()) null else paramTypeOf(default_val, param_values.MAX_ARRAY_DEPTH) orelse {
        const unheld = firstUnheld(default_val, param_values.MAX_ARRAY_DEPTH);
        return vm.fail(.ArgumentError, "parameter :{s}'s default {s} {s}; a parameter's default is a number, a String, true or false, a Symbol, an Array of them, or nil", .{ name, if (unheld.isEqual(default_val)) "is" else "holds", describedValue(vm, unheld) });
    };
    if (named) |t| {
        const type_name = if (t.isSymbol()) t.asSymbol().chars else "";
        const declared = std.meta.stringToEnum(parameters.ParamType, type_name) orelse {
            return vm.fail(.ArgumentError, "parameter :{s} type: is :number, :string, :boolean, :symbol or :array, got {s}", .{ name, describedValue(vm, t) });
        };
        if (of_default) |d| if (d != declared) {
            return vm.fail(.ArgumentError, "parameter :{s} is a{s} {s} by its type:, and its default is a{s} {s}", .{ name, article(declared), @tagName(declared), article(d), @tagName(d) });
        };
        return declared;
    }
    return of_default orelse sharedKind(choices) orelse .string;
}

/// The type of a value a parameter can hold: a number, a String, a boolean, a Symbol, or an
/// Array of such values nested at most `depth` deep; null for any other.
fn paramTypeOf(v: value.Value, depth: usize) ?parameters.ParamType {
    if (v.isNumber()) return .number;
    if (v.isString()) return .string;
    if (v.isBool()) return .boolean;
    if (v.isSymbol()) return .symbol;
    if (!v.isArray() or depth == 0) return null;
    for (v.asArray().items.items) |item| _ = paramTypeOf(item, depth - 1) orelse return null;
    return .array;
}

/// What in `v` no parameter holds: `v` itself, or the first such element in its Arrays (an
/// Array nested too deep, when there is none else).
fn firstUnheld(v: value.Value, depth: usize) value.Value {
    if (!v.isArray() or depth == 0) return v;
    for (v.asArray().items.items) |item| {
        if (paramTypeOf(item, depth - 1) == null) return firstUnheld(item, depth - 1);
    }
    return v;
}

/// The type all of `values` share; null when there are none, or they differ.
fn sharedKind(values: []const value.Value) ?parameters.ParamType {
    if (values.len == 0) return null;
    const first = paramTypeOf(values[0], param_values.MAX_ARRAY_DEPTH) orelse return null;
    for (values[1..]) |v| if (paramTypeOf(v, param_values.MAX_ARRAY_DEPTH) != first) return null;
    return first;
}

/// A parameter, or an element of an Array one, as a refusal names it: `:size`, `:size[1]`.
const Subject = struct {
    name: []const u8,
    index: ?usize = null,

    pub fn format(self: Subject, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(":{s}", .{self.name});
        if (self.index) |i| try writer.print("[{d}]", .{i});
    }
};

/// A scalar parameter's value (or an Array one's element) read as `p_type` from `v` (the
/// default, or a host's), checked against its range.
fn readScalar(vm: *VM, subject: Subject, p_type: parameters.ParamType, v: value.Value, min_val: f64, max_val: f64) anyerror!value.Value {
    switch (p_type) {
        .number => {
            const num = readNumber(v) orelse return typeMismatch(vm, subject, "a number", v);
            // An unset bound is NaN, which no comparison passes
            if (num < min_val) return refuse(vm, subject.name, .ValueError, "parameter {f} value {f} is below its minimum {f}", .{ subject, value.fmtNumber(num), value.fmtNumber(min_val) });
            if (num > max_val) return refuse(vm, subject.name, .ValueError, "parameter {f} value {f} is above its maximum {f}", .{ subject, value.fmtNumber(num), value.fmtNumber(max_val) });
            return value.Value.initNumber(num);
        },
        .boolean => return value.Value.initBool(readBoolean(v) orelse return typeMismatch(vm, subject, "true or false", v)),
        // A symbol parameter's value is a Symbol: a String compared unequal to the symbols in
        // its `in:` choices, so `param(:size, default: :m3, validate: { in: [:m3, :m4] })`
        // refused even its own default.
        .string => return vm.allocateString(v.nameChars() orelse return typeMismatch(vm, subject, "a String", v)),
        .symbol => return vm.allocateSymbol(v.nameChars() orelse return typeMismatch(vm, subject, "a Symbol", v)),
        .array => {
            if (!v.isArray()) return typeMismatch(vm, subject, "an Array", v);
            return readNested(vm, subject, v, min_val, max_val);
        },
    }
}

/// What an Array parameter's elements are checked against: the kind its default's elements
/// (or its choices) share, if they share one, its range for every number in it, and its
/// choices for each element.
const ArrayRules = struct {
    kind: ?parameters.ParamType,
    min: f64,
    max: f64,
    choices: ?*value.ObjArray,
};

/// An Array parameter's value read from `v` (the default, an Array from a `-P` file or a
/// host, or `-p` text, read as JSON): a new Array of its elements, each read as `rules`
/// say. Unrooted.
fn readArray(vm: *VM, name: []const u8, v: value.Value, rules: ArrayRules) !value.Value {
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const given = if (v.isArray()) v else if (v.isString()) try parseArray(vm, name, v) else return typeMismatch(vm, .{ .name = name }, "an Array", v);
    vm.push(given);
    const read = try scope.array();
    for (given.asArray().items.items, 0..) |item, i| {
        const subject: Subject = .{ .name = name, .index = i };
        const element = if (rules.kind) |kind|
            try readScalar(vm, subject, kind, item, rules.min, rules.max)
        else
            try readNested(vm, subject, item, rules.min, rules.max);
        if (rules.choices) |arr| if (!isChoice(vm, arr, element)) {
            return refuse(vm, name, .ValueError, "parameter {f} is not one of its allowed choices", .{subject});
        };
        try read.items.append(vm.gc.trackingAllocator(), element);
    }
    return value.Value.initObj(&read.obj);
}

/// An element of no one kind, or an Array in an Array, as it is: refused when it is no value
/// a parameter holds, or holds a number out of the range.
fn readNested(vm: *VM, subject: Subject, v: value.Value, min_val: f64, max_val: f64) !value.Value {
    _ = paramTypeOf(v, param_values.MAX_ARRAY_DEPTH - 1) orelse {
        return refuse(vm, subject.name, .TypeError, "parameter {f} is {s}; an Array parameter holds numbers, Strings, true or false, Symbols and Arrays of them", .{ subject, describedValue(vm, v) });
    };
    try checkNumbers(vm, subject, v, min_val, max_val);
    return v;
}

/// Refuses a number in `v`, or in the Arrays it holds, that is out of the range.
fn checkNumbers(vm: *VM, subject: Subject, v: value.Value, min_val: f64, max_val: f64) !void {
    if (v.isNumber()) {
        _ = try readScalar(vm, subject, .number, v, min_val, max_val);
        return;
    }
    if (!v.isArray()) return;
    for (v.asArray().items.items) |item| try checkNumbers(vm, subject, item, min_val, max_val);
}

/// The Array `-p name=[10, 20]` gives, read as JSON. Unrooted.
fn parseArray(vm: *VM, name: []const u8, text: value.Value) !value.Value {
    const parsed = json_input.parse(std.json.Value, vm.allocator, text.asString().chars, null) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return typeMismatch(vm, .{ .name = name }, "an Array (as JSON: [10, 20])", text),
    };
    defer parsed.deinit();
    if (parsed.value != .array) return typeMismatch(vm, .{ .name = name }, "an Array (as JSON: [10, 20])", text);
    var arena: std.heap.ArenaAllocator = .init(vm.allocator);
    defer arena.deinit();
    var refused: std.json.Value = undefined;
    const given = try ParamValue.ofJson(arena.allocator(), parsed.value, &refused) orelse {
        return typeMismatch(vm, .{ .name = name }, "an Array of numbers, strings, true or false, and arrays of them", text);
    };
    return scriptValueOf(vm, given);
}

fn isChoice(vm: *VM, choices: *value.ObjArray, v: value.Value) bool {
    for (choices.items.items) |choice| {
        if (vm.valuesEqual(v, choice)) return true;
    }
    return false;
}

/// "a Map", or the value itself where it is one a person writes ("nil", ":x").
fn describedValue(vm: *VM, v: value.Value) []const u8 {
    if (v.isNil()) return "nil";
    if (v.isSymbol()) return vm.scratch_arena.allocator().print(":{s}", .{v.asSymbol().chars}) catch "a Symbol";
    const type_name = arguments.typeName(vm, v);
    return vm.scratch_arena.allocator().print("a{s} {s}", .{ if (startsWithVowel(type_name)) "n" else "", type_name }) catch type_name;
}

fn article(t: parameters.ParamType) []const u8 {
    return if (startsWithVowel(@tagName(t))) "n" else "";
}

fn startsWithVowel(word: []const u8) bool {
    return word.len > 0 and std.mem.findScalar(u8, "aeiouAEIOU", word[0]) != null;
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

/// The TypeError for a value a parameter (or an element of an Array one) can't take:
/// "parameter :w expects a number, got "abc"", the text quoted as `-p` gave it.
fn typeMismatch(vm: *VM, subject: Subject, expected: []const u8, got: value.Value) error{RuntimeError} {
    if (got.isString()) return refuse(vm, subject.name, .TypeError, "parameter {f} expects {s}, got \"{s}\"", .{ subject, expected, got.asString().chars });
    return refuse(vm, subject.name, .TypeError, "parameter {f} expects {s}, got {s}", .{ subject, expected, arguments.typeName(vm, got) });
}

/// The error of the value parameter `name` refused, `kind` saying `fmt`, with the
/// parameter noted in the run's report as the one that stopped it.
fn refuse(vm: *VM, name: []const u8, comptime kind: vm_mod.ErrorKind, comptime fmt: []const u8, args: anytype) error{RuntimeError} {
    // The report only names it: out of memory, the run still fails with its own error
    vm.report.refuse(vm.allocator, name) catch {};
    return vm.fail(kind, fmt, args);
}
