//! Argument checking for the geometry methods: `require*` for single values, `parsePoint`,
//! `parseNumberArray` and `parseVec3` for coordinates, `parseKwargs` and its variants for
//! keyword arguments, all raising a script error that names the method and the argument.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const limits = @import("../../core/limits.zig");
const kernel = @import("../../kernel/kernel.zig");
const geom = @import("../../kernel/geometry_handle.zig");

// --- Argument validation ---
//
// Every number a script hands to a geometry method goes through these helpers.
// They used to be read as `if (v.isNumber()) v.asNumber() else 0.0`, so a typo
// like `[10, "x"]` silently became a 0 coordinate, and NaN/inf went straight to
// the kernels. Errors are raised with raiseError so `rescue => e` sees the
// real message instead of the generic "Native Execution Error".

/// Room for an element description such as "a coordinate (point 12, component 1)".
const MAX_DESCRIPTION_LEN = 128;

/// Maximum positional components of a vector argument (x, y, z).
const VEC3_LEN = 3;
/// The keywords (and positional names) of a 3D vector: translate, scale and the rest.
pub const VEC3_NAMES = [VEC3_LEN][]const u8{ "x", "y", "z" };

/// The script-facing name of a value's type, for TypeError messages.
pub fn typeName(vm: *VM, val: value.Value) []const u8 {
    return vm.typeName(val);
}

fn typeError(vm: *VM, method: []const u8, expected: []const u8, what: []const u8, got: value.Value) error{RuntimeError} {
    return vm.fail(.TypeError, "{s} expects {s} for {s}, got {s}", .{ method, expected, what, typeName(vm, got) });
}

/// A method for Solids only called on a Sketch, or the other way round: the same
/// NoMethodError as for any method the receiver doesn't have.
pub fn notDefinedFor(vm: *VM, method: []const u8, receiver: value.Value) error{RuntimeError} {
    return vm.fail(.NoMethodError, "undefined method '{s}' for {s}", .{ method, typeName(vm, receiver) });
}

/// The bounding box of a Solid, of a Sketch (flat, at z = 0), or of an Assembly (the box
/// around all its parts).
pub fn boundsOf(vm: *VM, receiver: value.Value, method: []const u8) !geom.BoundingBox {
    if (receiver.isAssembly()) {
        const parts = receiver.asAssembly().parts.items.items;
        if (parts.len == 0) return vm.fail(.ValueError, "{s}: an empty assembly has no bounds", .{method});
        var box = try boundsOf(vm, parts[0], method);
        for (parts[1..]) |part| {
            const b = try boundsOf(vm, part, method);
            for (0..3) |axis| {
                box.min[axis] = @min(box.min[axis], b.min[axis]);
                box.max[axis] = @max(box.max[axis], b.max[axis]);
            }
        }
        return box;
    }
    if (receiver.isCrossSection()) {
        const sketch = try vm.ensureConcreteCrossSection(receiver);
        try vm.requireFeature(sketch.engine, .sketch_measure);
        const rect = kernel.crossSectionBounds(sketch) orelse return vm.fail(.ValueError, "{s}: an empty sketch has no bounds", .{method});
        return .{ .min = .{ rect.min[0], rect.min[1], 0.0 }, .max = .{ rect.max[0], rect.max[1], 0.0 } };
    }
    if (!receiver.isGeometry()) return notDefinedFor(vm, method, receiver);
    const solid = try vm.ensureConcrete(receiver);
    try vm.requireFeature(solid.engine, .bounding_box);
    return kernel.boundingBox(solid) orelse {
        return vm.fail(.GeometryError, "{s} could not compute the bounding box of this shape", .{method});
    };
}

/// Rejects NaN and infinities, which no kernel can place or tessellate.
pub fn requireFinite(vm: *VM, n: f64, method: []const u8, what: []const u8) !void {
    if (!std.math.isFinite(n)) {
        return vm.fail(.ValueError, "{s} expects a finite number for {s}, got {f}", .{ method, what, value.fmtNumber(n) });
    }
}

/// Reads a finite number, raising a TypeError for any other type.
pub fn requireNumber(vm: *VM, val: value.Value, method: []const u8, what: []const u8) !f64 {
    if (!val.isNumber()) return typeError(vm, method, "a number", what, val);
    const n = val.asNumber();
    try requireFinite(vm, n, method, what);
    return n;
}

/// NaN compares false against everything, so `n <= 0` alone lets NaN through;
/// infinities are rejected too since no kernel can tessellate them.
pub fn requirePositive(vm: *VM, n: f64, method: []const u8, what: []const u8) !void {
    if (!std.math.isFinite(n) or n <= 0.0) {
        return vm.fail(.ValueError, "{s} expects {s} to be a finite number greater than zero, got {f}", .{ method, what, value.fmtNumber(n) });
    }
}

/// Reads a flag. nil is false (Ruby truthiness), so a forwarded optional
/// parameter like `center: opts[:center]` keeps working.
pub fn requireBool(vm: *VM, val: value.Value, method: []const u8, what: []const u8) !bool {
    if (val.isNil()) return false;
    if (!val.isBool()) return typeError(vm, method, "true or false", what, val);
    return val.asBool();
}

/// Reads a String or Symbol (scripts use both for names like `halign: :center`).
pub fn requireName(vm: *VM, val: value.Value, method: []const u8, what: []const u8) ![]const u8 {
    if (val.isString()) return val.asString().chars;
    if (val.isSymbol()) return val.asSymbol().chars;
    return typeError(vm, method, "a String or Symbol", what, val);
}

pub fn requireArray(vm: *VM, val: value.Value, method: []const u8, what: []const u8) ![]value.Value {
    if (!val.isArray()) return typeError(vm, method, "an Array", what, val);
    return val.asArray().items.items;
}

/// Describes a numeric Array argument for error messages. Descriptions are only
/// formatted on the error path: validating a 200k-point polygon must not pay for
/// a bufPrint per coordinate.
pub const NumberArray = struct {
    method: []const u8,
    /// Names the whole array in shape errors: "the matrix", or "point"/"face"
    /// when `row` is set.
    name: []const u8,
    /// Position of this array in a list ("point 2" is name "point", row 2);
    /// null for a standalone array.
    row: ?usize = null,
    /// Names one element in type errors: "a coordinate", "a matrix entry".
    elem: []const u8 = "a coordinate",
    /// What an element's index is called: "component", "index", "entry".
    index_label: []const u8 = "component",
};

/// "point 2" / "the matrix".
fn arrayName(buf: []u8, arg: NumberArray) []const u8 {
    const row = arg.row orelse return arg.name;
    return std.mem.print(buf, "{s} {d}", .{ arg.name, row }) catch arg.name;
}

/// Raises the TypeError/ValueError for a bad element `i` (cold path only).
fn elementError(vm: *VM, arg: NumberArray, i: usize, item: value.Value) error{RuntimeError} {
    @branchHint(.cold);
    var name_buf: [MAX_DESCRIPTION_LEN]u8 = undefined;
    var buf: [MAX_DESCRIPTION_LEN]u8 = undefined;
    const what = if (arg.row != null)
        std.mem.print(&buf, "{s} ({s}, {s} {d})", .{ arg.elem, arrayName(&name_buf, arg), arg.index_label, i }) catch arg.elem
    else
        std.mem.print(&buf, "{s} ({s} {d})", .{ arg.elem, arg.index_label, i }) catch arg.elem;
    if (!item.isNumber()) return typeError(vm, arg.method, "a number", what, item);
    return vm.fail(.ValueError, "{s} expects a finite number for {s}, got {f}", .{ arg.method, what, value.fmtNumber(item.asNumber()) });
}

/// Reads an Array of `min_len..N` finite numbers. Missing trailing entries are
/// `fill`, so callers that need an exact length pass `min_len == N`.
pub fn parseNumberArray(comptime N: usize, vm: *VM, val: value.Value, arg: NumberArray, min_len: usize, fill: f64) ![N]f64 {
    std.debug.assert(min_len <= N);
    var name_buf: [MAX_DESCRIPTION_LEN]u8 = undefined;
    if (!val.isArray()) return typeError(vm, arg.method, "an Array", arrayName(&name_buf, arg), val);
    const items = val.asArray().items.items;
    if (items.len < min_len or items.len > N) {
        const name = arrayName(&name_buf, arg);
        if (min_len == N) {
            _ = vm.raiseError(.ValueError, "{s} expects {s} to have {d} numbers, got {d}", .{ arg.method, name, N, items.len });
        } else {
            _ = vm.raiseError(.ValueError, "{s} expects {s} to have {d} to {d} numbers, got {d}", .{ arg.method, name, min_len, N, items.len });
        }
        return error.RuntimeError;
    }
    var out: [N]f64 = @splat(fill);
    for (items, 0..) |item, i| {
        if (item.isNumber()) {
            const n = item.asNumber();
            if (std.math.isFinite(n)) {
                out[i] = n;
                continue;
            }
        }
        return elementError(vm, arg, i, item);
    }
    return out;
}

/// Reads `[x, y]` / `[x, y, z]` entry `index` of a point list (indices are 0-based,
/// as the script indexes the list).
pub fn parsePoint(comptime N: usize, vm: *VM, val: value.Value, method: []const u8, index: usize) ![N]f64 {
    return parseNumberArray(N, vm, val, .{ .method = method, .name = "point", .row = index }, N, 0.0);
}

/// Rejects a plane normal or direction with no usable orientation. The squared
/// length is checked, not each component: a vector like [1e-320, 0, 0] is not
/// exactly zero, but normalizing it underflows and the kernels silently return
/// empty or zero-volume output. Huge components overflow to inf, which is fine.
pub fn requireNonZeroVector(vm: *VM, v: [3]f64, method: []const u8, what: []const u8) !void {
    const len2 = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
    if (!(len2 >= std.math.floatMin(f64))) {
        const f = value.fmtNumber;
        return vm.fail(.ValueError, "{s} expects a non-zero {s}, got [{f}, {f}, {f}]", .{ method, what, f(v[0]), f(v[1]), f(v[2]) });
    }
}

/// Converts a script number to integer type `I`, truncating toward zero (the
/// historical @intFromFloat semantics). @intFromFloat on NaN/inf/out-of-range
/// input panics in Debug and is UB in ReleaseFast, so every user-supplied
/// count must go through this instead.
///
/// It only checks that the number fits `I`; callers check the range that makes sense
/// (`requireSegmentCount`, `EngineConfig.problem`), so the messages here don't quote the
/// type's limits (they read "[0, 4294967295]").
pub fn checkedInt(comptime I: type, vm: *VM, val: f64, name: []const u8) !I {
    const t = @trunc(val);
    const shown = value.fmtNumber(val);
    if (!std.math.isFinite(val)) {
        return vm.fail(.ValueError, "'{s}' must be a finite number, got {f}", .{ name, shown });
    }
    if (t < @as(f64, @floatFromInt(std.math.minInt(I)))) {
        if (std.math.minInt(I) == 0) return vm.fail(.ValueError, "'{s}' can't be negative, got {f}", .{ name, shown });
        return vm.fail(.ValueError, "'{s}' is too small, got {f}", .{ name, shown });
    }
    if (t > @as(f64, @floatFromInt(std.math.maxInt(I)))) {
        return vm.fail(.ValueError, "'{s}' is too large, got {f}", .{ name, shown });
    }
    return @intFromFloat(t);
}

/// Validates a tessellation count (segments/sides/slices). 0 means "auto" for
/// callers that resolve it from the engine config afterwards.
pub fn requireSegmentCount(vm: *VM, segs: i32, name: []const u8) !void {
    if (segs < 0 or segs > limits.MAX_SEGMENTS) {
        return vm.fail(.ValueError, "'{s}' must be between 0 and {d}, got {d}", .{ name, limits.MAX_SEGMENTS, segs });
    }
}

/// The segment count the active resolution gives a circle of `radius` (what `segments: 0`
/// means), within MAX_SEGMENTS: an automatic count is not the script's fault, so it is
/// clamped rather than an error.
pub fn autoSegments(vm: *VM, radius: f64) i32 {
    return @intCast(vm.config().segmentsFor(radius));
}

/// The trailing kwargs map of a native call, if any.
pub fn trailingKwargs(args: []const value.Value) ?*value.ObjMap {
    if (args.len > 0 and args[args.len - 1].isMap()) {
        return args[args.len - 1].asMap();
    }
    return null;
}

/// The string of a String or Symbol map key, or null for any other key type.
fn keyName(k: value.Value) ?[]const u8 {
    if (!k.isObject()) return null;
    return switch (k.asObj().obj_type) {
        .string => k.asString().chars,
        .symbol => k.asSymbol().chars,
        else => null,
    };
}

/// Parses positional arguments and/or `x:`, `y:`, `z:` kwargs into [x, y, z].
/// Unset components are `default_val`; kwargs override positionals.
/// The x, y, z of a transform call: up to three numbers, one Array of two or three
/// (`translate([1, 2, 3])`), and/or `x:`, `y:`, `z:`; axes not given are `default_val`.
pub fn parseVec3(vm: *VM, args: []const value.Value, default_val: f64, method: []const u8) ![VEC3_LEN]f64 {
    // Raw values, so a nil coordinate is a TypeError rather than an unset axis.
    const parsed = try parseKwargsSubset(struct { x: ?value.Value = null, y: ?value.Value = null, z: ?value.Value = null }, &VEC3_NAMES, vm, args, method);
    const positional = if (parsed.positional.len == 1 and parsed.positional[0].isArray()) parsed.positional[0].asArray().items.items else parsed.positional;
    if (positional.len > VEC3_LEN) {
        return vm.fail(.ArgumentError, "{s} expects at most {d} numbers (x, y, z), got {d}", .{ method, VEC3_LEN, positional.len });
    }

    var vec: [VEC3_LEN]f64 = @splat(default_val);
    for (positional, 0..) |arg, i| vec[i] = try requireNumber(vm, arg, method, VEC3_NAMES[i]);
    inline for (VEC3_NAMES, 0..) |axis, i| {
        if (@field(parsed.opts, axis)) |v| vec[i] = try requireNumber(vm, v, method, axis);
    }
    return vec;
}

/// Whether a transform call gave one bare number and nothing else (`scale(2)`,
/// `rotate(45)`): the shorthands with a meaning of their own.
pub fn singleNumber(args: []const value.Value) bool {
    return args.len == 1 and args[0].isNumber();
}

/// A native call's arguments split into positionals and keyword options.
pub fn Parsed(comptime T: type) type {
    return struct {
        opts: T,
        /// The arguments before the trailing kwargs map.
        positional: []const value.Value,
    };
}

/// Splits `args` into positionals and the keyword options `T`, whose fields are the
/// keywords `method` accepts. See parseKwargsOver.
pub fn parseKwargs(comptime T: type, vm: *VM, args: []const value.Value, method: []const u8) !Parsed(T) {
    return parseKwargsOver(T, .{}, comptime nameList(T), vm, args, method);
}

/// parseKwargs for options shared by several methods: only the `accepted` fields of `T`
/// are keywords of `method`, the rest keep their defaults.
pub fn parseKwargsSubset(comptime T: type, comptime accepted: []const []const u8, vm: *VM, args: []const value.Value, method: []const u8) !Parsed(T) {
    return parseKwargsOver(T, .{}, accepted, vm, args, method);
}

/// parseKwargs over `initial`, which holds what the positional arguments set (see
/// parseKwargsOver): a keyword wins over the same option given positionally.
pub fn parseKwargsOnto(comptime T: type, initial: T, vm: *VM, args: []const value.Value, method: []const u8) !Parsed(T) {
    return parseKwargsOver(T, initial, comptime nameList(T), vm, args, method);
}

/// The arguments before a trailing kwargs map.
pub fn positionalArgs(args: []const value.Value) []const value.Value {
    return if (trailingKwargs(args) != null) args[0 .. args.len - 1] else args;
}

/// Applies the `accepted` keywords of a call over `initial`, which holds what the
/// positional arguments set: a keyword wins over the same option given positionally
/// (`cube(5, z: 3)` is 5 x 5 x 3), as it does for every method.
///
/// Any other keyword is an ArgumentError listing the accepted ones, so a typo such as
/// `revolve(angle: 90)` or `translate(X: 5)` fails loudly instead of being ignored. A
/// value of the wrong type is a TypeError naming `method` and the keyword; floats must be
/// finite, integers are range-checked via checkedInt, an enum field takes the String or
/// Symbol of one of its tags, and a `value.Value` field takes anything (nil included). `nil`
/// leaves any other optional field unset and reads as false for a flag.
pub fn parseKwargsOver(comptime T: type, initial: T, comptime accepted: []const []const u8, vm: *VM, args: []const value.Value, method: []const u8) !Parsed(T) {
    inline for (accepted) |name| {
        if (!@hasField(T, name)) @compileError("parseKwargsOver: " ++ @typeName(T) ++ " has no field '" ++ name ++ "'");
    }
    const map = trailingKwargs(args) orelse return .{ .opts = initial, .positional = args };

    var opts = initial;
    var it = map.map.iterator();
    next_key: while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const name = keyName(key) orelse {
            return vm.fail(.ArgumentError, "{s} keywords must be names, got a {s} key", .{ method, typeName(vm, key) });
        };
        inline for (accepted) |field_name| {
            if (std.mem.eql(u8, name, field_name)) {
                @field(opts, field_name) = try readKwarg(@FieldType(T, field_name), vm, entry.value_ptr.*, method, field_name);
                continue :next_key;
            }
        }
        return vm.fail(.ArgumentError, "{s} does not take a keyword '{s}' (it accepts: {s})", .{ method, name, comptime joinNames(accepted) });
    }
    return .{ .opts = opts, .positional = args[0 .. args.len - 1] };
}

/// Fails when the call's keywords name one option twice (`r:` and `d:`): which one won was
/// an accident of the order they were read in.
pub fn requireOneOf(vm: *VM, args: []const value.Value, comptime names: []const []const u8, method: []const u8) !void {
    const map = trailingKwargs(args) orelse return;
    var first: ?[]const u8 = null;
    var it = map.map.iterator();
    while (it.next()) |entry| {
        const name = keyName(entry.key_ptr.*) orelse continue;
        inline for (names) |alias| {
            if (std.mem.eql(u8, name, alias)) {
                if (first) |earlier| return vm.fail(.ArgumentError, "{s} takes {s} or {s}, not both", .{ method, earlier, name });
                first = name;
            }
        }
    }
}

fn readKwarg(comptime F: type, vm: *VM, v: value.Value, method: []const u8, name: []const u8) !F {
    // Raw values come through as passed, nil included; null means "not passed".
    if (F == value.Value or F == ?value.Value) return v;
    if (@typeInfo(F) == .optional) {
        if (v.isNil()) return null;
        return try readKwarg(@typeInfo(F).optional.child, vm, v, method, name);
    }
    if (F == f64) return requireNumber(vm, v, method, name);
    if (@typeInfo(F) == .int) {
        if (!v.isNumber()) return typeError(vm, method, "a number", name, v);
        return checkedInt(F, vm, v.asNumber(), name);
    }
    if (F == bool) return requireBool(vm, v, method, name);
    if (F == []const u8) return requireName(vm, v, method, name);
    if (@typeInfo(F) == .@"enum") {
        const tag = try requireName(vm, v, method, name);
        return std.meta.stringToEnum(F, tag) orelse {
            return vm.fail(.ValueError, "{s} {s} must be {s}, got '{s}'", .{ method, name, comptime joinChoices(nameList(F)), tag });
        };
    }
    @compileError("parseKwargs: unsupported field type " ++ @typeName(F));
}

/// The field (or tag) names of `T` as plain slices.
fn nameList(comptime T: type) []const []const u8 {
    const names = switch (@typeInfo(T)) {
        inline .@"struct", .@"enum" => |info| info.field_names,
        else => @compileError("nameList: " ++ @typeName(T) ++ " has no fields"),
    };
    var list: [names.len][]const u8 = undefined;
    for (names, &list) |name, *slot| slot.* = name;
    const final = list;
    return &final;
}

/// "a, b, c", for listing the keywords a method accepts.
fn joinNames(comptime names: []const []const u8) []const u8 {
    var list: []const u8 = "";
    for (names, 0..) |name, i| list = list ++ (if (i == 0) "" else ", ") ++ name;
    return list;
}

/// "a, b or c", for listing the values an option allows.
fn joinChoices(comptime names: []const []const u8) []const u8 {
    var list: []const u8 = "";
    for (names, 0..) |name, i| {
        const sep = if (i == 0) "" else if (i == names.len - 1) " or " else ", ";
        list = list ++ sep ++ name;
    }
    return list;
}
