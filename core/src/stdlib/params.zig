//! The `param` built-in (`nativeParam`): `param(:name)` reads a parameter, and with keywords
//! declares it: its rules (core/param_rules.zig: `type:`, `validate:`, and what its default
//! implies), the host's value read by them over the default, recorded in the VM's parameter
//! registry. A value it refuses names its parameter, and the place in its value, in the run's
//! report (`refused`), for a host's control to mark.

const std = @import("std");
const value = @import("../core/value.zig");
const vm_mod = @import("../vm/vm.zig");
const VM = vm_mod.VM;
const rules = @import("../core/param_rules.zig");
const Literal = rules.Literal;
const HandleScope = @import("../vm/scope.zig").HandleScope;
const arguments = @import("arguments.zig");

/// What a parameter's value may be made of, for the ArgumentError of a declaration that holds
/// anything else.
const HELD = "a parameter's value is made of numbers, Strings, true or false, Symbols, Arrays and Maps";

/// param(:name) reads a parameter; param(:name, default: v, type: :t, validate: { ... })
/// declares it, taking the host's value (`-p name=text`, `-P file.json`) over the default,
/// read by its rules: text from `-p` becomes a number, a boolean, a String, a Symbol, or an
/// Array or a Map (as JSON) as the parameter is one. One with no default is nil until a host
/// gives it a value. `step:`, `unit:`, `group:`, `title:` and `description:` are for a host's
/// controls.
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

    // --- SETTER MODE ---
    if (parsed.opts.step) |step| {
        if (!(step > 0) or !std.math.isFinite(step)) return vm.fail(.ValueError, "parameter :{s} step must be a number greater than 0, got {f}", .{ sym_chars, value.fmtNumber(step) });
    }
    var arena: std.heap.ArenaAllocator = .init(vm.allocator);
    defer arena.deinit();
    const declared = rules.Declaration{
        .name = sym_chars,
        .type = if (parsed.opts.type) |t| try declarationPart(vm, arena.allocator(), sym_chars, "type:", t) else null,
        .default = if (parsed.opts.default) |d| try declarationPart(vm, arena.allocator(), sym_chars, "default", d) else .nil,
        .validate = if (parsed.opts.validate) |v| try declarationPart(vm, arena.allocator(), sym_chars, "validate:", v) else null,
        .title = parsed.opts.title,
        .unit = parsed.opts.unit,
        .step = parsed.opts.step,
    };
    var why: []const u8 = "";
    const built = rules.build(arena.allocator(), declared, &why) catch |err| switch (err) {
        error.InvalidRule => return vm.fail(.ArgumentError, "{s}", .{why}),
        error.OutOfMemory => |e| return e,
    };

    // --- CLI / HOST INJECTION ---
    var taken = built.default;
    if (hostValue(vm, sym_key)) |given| {
        // A host's is made of what scriptValueOf makes, which a Literal holds
        const literal = literalOf(arena.allocator(), given, rules.MAX_LITERAL_DEPTH) catch |err| switch (err) {
            error.Unheld => return vm.fail(.TypeError, "parameter :{s} was given a value no parameter holds", .{sym_chars}),
            error.OutOfMemory => |e| return e,
        };
        var refusal: rules.Refusal = undefined;
        taken = rules.check(arena.allocator(), built.rule, literal, &refusal) catch |err| switch (err) {
            error.Refused => return refuse(vm, sym_chars, refusal),
            error.OutOfMemory => |e| return e,
        };
    }

    const result = try valueOf(vm, taken);
    // Made here, it is rooted while the registry takes it
    vm.push(result);
    defer _ = vm.pop();
    try vm.declareParam(.{ .name = sym_key, .current_value = result });
    return result;
}

/// The value the host gave the parameter `key`, if it gave one.
fn hostValue(vm: *VM, key: value.Value) ?value.Value {
    const params = vm.globals.get("params") orelse return null;
    if (!params.isMap()) return null;
    const index = vm.findMapKey(params.asMap(), key) orelse return null;
    return params.asMap().table.values()[index];
}

/// A part of a declaration (`what`: its default, `type:`, `validate:`) as a Literal; an
/// ArgumentError for one holding what no parameter's value is made of (a Solid, a Range).
fn declarationPart(vm: *VM, arena: std.mem.Allocator, name: []const u8, comptime what: []const u8, v: value.Value) !Literal {
    var unheld: value.Value = undefined;
    return Literal.ofValue(arena, v, rules.MAX_LITERAL_DEPTH, &unheld) catch |err| switch (err) {
        error.Unheld => {
            if (unheld.isEqual(v)) return vm.fail(.ArgumentError, "parameter :{s}'s " ++ what ++ " is {s}; " ++ HELD, .{ name, described(vm, unheld) });
            return vm.fail(.ArgumentError, "parameter :{s}'s " ++ what ++ " holds {s}; " ++ HELD, .{ name, described(vm, unheld) });
        },
        error.OutOfMemory => |e| return e,
    };
}

fn literalOf(arena: std.mem.Allocator, v: value.Value, depth: usize) error{ Unheld, OutOfMemory }!Literal {
    var unheld: value.Value = undefined;
    return Literal.ofValue(arena, v, depth, &unheld);
}

/// A Literal (a value `param()` read, or a host's for a parameter, read there by its rules)
/// as the script holds it: text as a String, a Map keyed by Symbols. Unrooted: the caller
/// roots it before allocating again.
pub fn valueOf(vm: *VM, literal: Literal) !value.Value {
    switch (literal) {
        .number => |n| return value.Value.initNumber(n),
        .boolean => |b| return value.Value.initBool(b),
        .nil => return value.Value.initNil(),
        .string => |t| return vm.allocateString(t),
        .symbol => |t| return vm.allocateSymbol(t),
        .array => |items| {
            var scope = HandleScope.init(vm);
            defer scope.deinit();
            const array = try scope.array();
            try array.items.ensureTotalCapacity(vm.gc.trackingAllocator(), items.len);
            // Each element is in the Array before another is made, which may collect
            for (items) |item| array.items.appendAssumeCapacity(try valueOf(vm, item));
            return value.Value.initObj(&array.obj);
        },
        .map => |entries| {
            var scope = HandleScope.init(vm);
            defer scope.deinit();
            const map = try scope.map();
            for (entries) |entry| {
                const key = try vm.allocateSymbol(entry.key);
                vm.push(key);
                const item = try valueOf(vm, entry.value);
                vm.push(item);
                try vm.mapSet(map, key, item);
            }
            return value.Value.initObj(&map.obj);
        },
    }
}

/// The error of a value the parameter `name` refused: "parameter :points[1][0] expects a
/// number at most 200, got 250", a TypeError for a value of another kind, else a ValueError,
/// with the parameter and the place noted in the run's report as what stopped it.
fn refuse(vm: *VM, name: []const u8, refusal: rules.Refusal) error{RuntimeError} {
    // The report only names it: out of memory, the run still fails with its own error
    vm.report.refuse(vm.allocator, name, refusal.path) catch {};
    const place: rules.Place = .{ .name = name, .path = refusal.path };
    if (refusal.wrong_kind) return vm.fail(.TypeError, "parameter {f} expects {s}, got {s}", .{ place, refusal.expected, refusal.got });
    return vm.fail(.ValueError, "parameter {f} expects {s}, got {s}", .{ place, refusal.expected, refusal.got });
}

/// "a Solid", or the value itself where it is one a person writes (nil).
fn described(vm: *VM, v: value.Value) []const u8 {
    if (v.isNil()) return "nil";
    const type_name = vm.typeName(v);
    const vowel = type_name.len > 0 and std.mem.findScalar(u8, "AEIOUaeiou", type_name[0]) != null;
    return vm.scratch_arena.allocator().print("a{s} {s}", .{ if (vowel) "n" else "", type_name }) catch type_name;
}
