//! The values a host gives a script's parameters (`param(:name, default: ...)`): `kupcad
//! build -p name=text` and `-P file.json`, the API's BuildOptions, wasm's build. `ParamValues`
//! holds them by name; the VM receives them in its `params` Map (api.injectParams), and
//! `param()` reads each by the type its default declares. A preview frame gives the values a
//! run took back as the same JSON (`jsonStringify`, the inverse of `putJson`).

const std = @import("std");
const json_input = @import("json_input.zig");

/// A value for one parameter. Text is what `-p name=text` gives, and what a JSON string is:
/// `param()` reads it by the parameter's type, so "10.5" is a number for a number parameter,
/// "true" a boolean for a boolean one, and "m4" the symbol :m4 for a symbol one.
pub const ParamValue = union(enum) {
    number: f64,
    boolean: bool,
    text: []const u8,
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
        const owned: ParamValue = switch (v) {
            .text => |t| .{ .text = try allocator.dupe(u8, t) },
            else => v,
        };
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

    /// The values as the JSON object putJson reads: names to numbers, booleans and strings,
    /// in their order.
    pub fn jsonStringify(self: ParamValues, jw: *std.json.Stringify) !void {
        try jw.beginObject();
        for (self.map.keys(), self.map.values()) |name, v| {
            try jw.objectField(name);
            switch (v) {
                .number => |n| try jw.write(n),
                .boolean => |b| try jw.write(b),
                .text => |t| try jw.write(t),
            }
        }
        try jw.endObject();
    }

    /// Sets the parameters a JSON object of names and values gives (a `-P` file), over any
    /// they had. Text that isn't JSON, JSON that isn't one object, or a value no parameter
    /// takes (an Array, an object, null: Arrays and objects are data, not parameters) is
    /// refused with error.InvalidParams, and `why` receives the reason, worded for a person
    /// and owned by `allocator` (null when there was no room to word it). A refused file
    /// stops whatever reads it, so the values before the refusal may be set.
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
        for (object.keys(), object.values()) |name, v| {
            const param = paramValue(v) orelse {
                why.* = allocator.print("parameter '{s}' is {s}; a parameter takes a number, a string, true or false", .{ name, kindOf(v) }) catch null;
                return error.InvalidParams;
            };
            try self.put(allocator, name, param);
        }
    }
};

fn freeValue(allocator: std.mem.Allocator, v: ParamValue) void {
    switch (v) {
        .text => |t| allocator.free(t),
        else => {},
    }
}

/// A JSON value as a parameter's (its text borrowed), or null for one no parameter takes.
fn paramValue(v: std.json.Value) ?ParamValue {
    return switch (v) {
        .integer => |n| .{ .number = @floatFromInt(n) },
        .float => |f| .{ .number = f },
        // Digits too many for an i64; past 1.8e308 they are no number a script holds
        .number_string => |s| blk: {
            const f = std.fmt.parseFloat(f64, s) catch break :blk null;
            break :blk if (std.math.isFinite(f)) .{ .number = f } else null;
        },
        .bool => |b| .{ .boolean = b },
        .string => |s| .{ .text = s },
        .null, .array, .object => null,
    };
}

/// What kind of JSON value `v` is, for a refusal ("an array", "null").
fn kindOf(v: std.json.Value) []const u8 {
    return switch (v) {
        .array => "an array",
        .object => "an object",
        .null => "null",
        else => "a number past the largest (1.8e308)",
    };
}
