//! The values a host gives a script's parameters (`param(:name, default: ...)`): `kupcad
//! build -p name=text` and `-P file.json`, the API's BuildOptions, wasm's build and preview,
//! the language server's `kupcad.setParams`. `ParamValues`
//! holds them by name; the VM receives them in its `params` Map (api.injectParams), and
//! `param()` reads each by the parameter's type. A preview frame gives the values a run took
//! back as the same JSON (`jsonStringify`, the inverse of `putJson`).

const std = @import("std");
const json_input = @import("json_input.zig");

/// Arrays nested deeper than this are no parameter's value: a point list is two deep.
pub const MAX_ARRAY_DEPTH = 32;

/// A value for one parameter. Text is what `-p name=text` gives, and what a JSON string is:
/// `param()` reads it by the parameter's type, so "10.5" is a number for a number parameter,
/// "true" a boolean for a boolean one, "m4" the symbol :m4 for a symbol one, and "[10, 20]"
/// an Array for an Array one.
pub const ParamValue = union(enum) {
    number: f64,
    boolean: bool,
    text: []const u8,
    /// An Array parameter's elements, as JSON gives them (a `-P` file, a host's values).
    array: []const ParamValue,

    /// `json` as a parameter's value, its strings borrowed and its arrays in `arena`; null
    /// for what no parameter takes (an object, a null in an array, arrays nested past
    /// MAX_ARRAY_DEPTH, a number past 1.8e308), which `refused` then receives.
    pub fn ofJson(arena: std.mem.Allocator, json: std.json.Value, refused: *std.json.Value) !?ParamValue {
        return ofJsonAt(arena, json, refused, MAX_ARRAY_DEPTH);
    }

    fn ofJsonAt(arena: std.mem.Allocator, json: std.json.Value, refused: *std.json.Value, depth: usize) !?ParamValue {
        const taken: ?ParamValue = switch (json) {
            .integer => |n| .{ .number = @floatFromInt(n) },
            .float => |f| .{ .number = f },
            // Digits too many for an i64; past 1.8e308 they are no number a script holds
            .number_string => |text| blk: {
                const f = std.fmt.parseFloat(f64, text) catch break :blk null;
                break :blk if (std.math.isFinite(f)) .{ .number = f } else null;
            },
            .bool => |b| .{ .boolean = b },
            .string => |text| .{ .text = text },
            .array => |items| blk: {
                if (depth == 0) break :blk null;
                const elements = try arena.alloc(ParamValue, items.items.len);
                for (items.items, elements) |item, *element| {
                    element.* = try ofJsonAt(arena, item, refused, depth - 1) orelse return null;
                }
                break :blk .{ .array = elements };
            },
            .null, .object => null,
        };
        if (taken == null) refused.* = json;
        return taken;
    }
};

/// Parameter values by name, each name and text owned; a later value for a name replaces
/// the earlier one, so of `-P file.json -p width=50` the `-p` wins, and of `-p` then `-P`
/// the file. Kept in the order first given, so they reach the script in that order.
pub const ParamValues = struct {
    map: std.array_hash_map.String(ParamValue) = .empty,

    pub fn deinit(self: *ParamValues, allocator: std.mem.Allocator) void {
        for (self.map.keys(), self.map.values()) |name, v| {
            allocator.free(name);
            freeValue(allocator, v);
        }
        self.map.deinit(allocator);
        self.* = .{};
    }

    /// Sets `name` to `v`, copying both, over any value it had.
    pub fn put(self: *ParamValues, allocator: std.mem.Allocator, name: []const u8, v: ParamValue) !void {
        const owned = try copyValue(allocator, v);
        errdefer freeValue(allocator, owned);
        const gop = try self.map.getOrPut(allocator, name);
        if (gop.found_existing) {
            freeValue(allocator, gop.value_ptr.*);
        } else {
            gop.key_ptr.* = allocator.dupe(u8, name) catch |err| {
                self.map.swapRemoveAt(gop.index);
                return err;
            };
        }
        gop.value_ptr.* = owned;
    }

    /// Drops `name`'s value, if it has one: the parameter takes its script's again.
    pub fn remove(self: *ParamValues, allocator: std.mem.Allocator, name: []const u8) void {
        const entry = self.map.fetchOrderedRemove(name) orelse return;
        allocator.free(entry.key);
        freeValue(allocator, entry.value);
    }

    /// A copy, owned by `allocator`.
    pub fn clone(self: ParamValues, allocator: std.mem.Allocator) !ParamValues {
        var copy: ParamValues = .{};
        errdefer copy.deinit(allocator);
        for (self.map.keys(), self.map.values()) |name, v| try copy.put(allocator, name, v);
        return copy;
    }

    /// Whether `other` gives the same names the same values, in the same order (the order
    /// they reach the script in).
    pub fn eql(self: ParamValues, other: ParamValues) bool {
        if (self.map.count() != other.map.count()) return false;
        for (self.map.keys(), self.map.values(), other.map.keys(), other.map.values()) |name, v, other_name, other_v| {
            if (!std.mem.eql(u8, name, other_name) or !valueEql(v, other_v)) return false;
        }
        return true;
    }

    /// The values as the JSON object putJson reads: names to numbers, booleans, strings and
    /// arrays of them, in their order.
    pub fn jsonStringify(self: ParamValues, jw: *std.json.Stringify) !void {
        try jw.beginObject();
        for (self.map.keys(), self.map.values()) |name, v| {
            try jw.objectField(name);
            try writeValue(jw, v);
        }
        try jw.endObject();
    }

    /// Sets the parameters a JSON object of names and values gives (a `-P` file), over any
    /// they had; a null gives none, so the parameter takes its script's value. Text that
    /// isn't JSON, JSON that isn't one object, or a value no parameter takes (an object:
    /// that is data, not a parameter) is refused with error.InvalidParams, and `why`
    /// receives the reason, worded for a person and owned by `allocator` (null when there
    /// was no room to word it). A refused file stops whatever reads it, so the values before
    /// the refusal may be set.
    pub fn putJson(self: *ParamValues, allocator: std.mem.Allocator, text: []const u8, why: *?[]u8) !void {
        why.* = null;
        var at: json_input.Position = undefined;
        const parsed = json_input.parse(std.json.Value, allocator, text, &at) catch |err| {
            const what = json_input.describeSyntaxError(err) orelse return err;
            why.* = allocator.print("line {d}, column {d}: {s}", .{ at.line, at.column, what }) catch null;
            return error.InvalidParams;
        };
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |o| o,
            else => {
                why.* = allocator.dupe(u8, "a parameter file holds one JSON object of names and values, as {\"width\": 40}") catch null;
                return error.InvalidParams;
            },
        };
        return self.putObject(allocator, object, why);
    }

    /// Sets the parameters a parsed JSON object gives (its strings copied), over any they
    /// had; a null drops one's value, and a value no parameter takes is refused as putJson
    /// refuses it.
    pub fn putObject(self: *ParamValues, allocator: std.mem.Allocator, object: std.json.ObjectMap, why: *?[]u8) !void {
        why.* = null;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        for (object.keys(), object.values()) |name, v| {
            if (v == .null) {
                self.remove(allocator, name);
                continue;
            }
            var refused: std.json.Value = undefined;
            const param = try ParamValue.ofJson(arena.allocator(), v, &refused) orelse {
                why.* = allocator.print("parameter '{s}' {s} {s}; a parameter takes a number, a string, true or false, or an array of them", .{ name, if (v == .array) "holds" else "is", kindOf(refused) }) catch null;
                return error.InvalidParams;
            };
            try self.put(allocator, name, param);
        }
    }
};

fn valueEql(a: ParamValue, b: ParamValue) bool {
    return switch (a) {
        .number => |n| b == .number and b.number == n,
        .boolean => |flag| b == .boolean and b.boolean == flag,
        .text => |t| b == .text and std.mem.eql(u8, b.text, t),
        .array => |items| b == .array and items.len == b.array.len and for (items, b.array) |x, y| {
            if (!valueEql(x, y)) break false;
        } else true,
    };
}

/// `v` owned by `allocator`, its text and arrays copied.
fn copyValue(allocator: std.mem.Allocator, v: ParamValue) !ParamValue {
    switch (v) {
        .text => |t| return .{ .text = try allocator.dupe(u8, t) },
        .array => |items| {
            const copies = try allocator.alloc(ParamValue, items.len);
            var made: usize = 0;
            errdefer {
                for (copies[0..made]) |copy| freeValue(allocator, copy);
                allocator.free(copies);
            }
            for (items, copies) |item, *copy| {
                copy.* = try copyValue(allocator, item);
                made += 1;
            }
            return .{ .array = copies };
        },
        else => return v,
    }
}

fn freeValue(allocator: std.mem.Allocator, v: ParamValue) void {
    switch (v) {
        .text => |t| allocator.free(t),
        .array => |items| {
            for (items) |item| freeValue(allocator, item);
            allocator.free(items);
        },
        else => {},
    }
}

fn writeValue(jw: *std.json.Stringify, v: ParamValue) !void {
    switch (v) {
        .number => |n| try jw.write(n),
        .boolean => |b| try jw.write(b),
        .text => |t| try jw.write(t),
        .array => |items| {
            try jw.beginArray();
            for (items) |item| try writeValue(jw, item);
            try jw.endArray();
        },
    }
}

/// What kind of JSON value `v`, which no parameter takes, is, for a refusal ("an object").
fn kindOf(v: std.json.Value) []const u8 {
    return switch (v) {
        .array => "arrays nested too deep",
        .object => "an object",
        .null => "null",
        else => "a number past the largest (1.8e308)",
    };
}
