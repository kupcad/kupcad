//! The values a host gives a script's parameters (`param(:name, default: ...)`): `kupcad
//! build -p name=text` and `-P file.json`, the API's BuildOptions, wasm's build and preview,
//! the language server's `kupcad.setParams`. `ParamValues`
//! holds them by name; the VM receives them in its `params` Map (api.injectParams), and
//! `param()` reads each by the parameter's type. A preview frame gives the values a run took
//! back as the same JSON (`jsonStringify`, the inverse of `putJson`).

const std = @import("std");
const json_input = @import("json_input.zig");
const param_rules = @import("param_rules.zig");
const Literal = param_rules.Literal;
const MAX_DEPTH = param_rules.MAX_DEPTH;

/// A value for one parameter: a Literal (param_rules.zig) without nil or a Symbol. Text is
/// what `-p name=text` gives, and what a JSON string is: `param()` reads it by the
/// parameter's rules, so "10.5" is a number for a number parameter, "true" a boolean for a
/// boolean one, "m4" the symbol :m4 for a symbol one, and "[10, 20]" an Array for an Array
/// one. It was a tree of its own, with converters of its own beside the Literal's.
pub const ParamValue = Literal;

/// Parameter values by name, each name and text owned; a later value for a name replaces
/// the earlier one, so of `-P file.json -p width=50` the `-p` wins, and of `-p` then `-P`
/// the file. Kept in the order first given, so they reach the script in that order.
pub const ParamValues = struct {
    map: std.array_hash_map.String(ParamValue) = .empty,

    pub fn deinit(self: *ParamValues, allocator: std.mem.Allocator) void {
        for (self.map.keys(), self.map.values()) |name, v| {
            allocator.free(name);
            v.free(allocator);
        }
        self.map.deinit(allocator);
        self.* = .{};
    }

    /// Sets `name` to `v`, copying both, over any value it had.
    pub fn put(self: *ParamValues, allocator: std.mem.Allocator, name: []const u8, v: ParamValue) !void {
        const owned = try v.copy(allocator);
        errdefer owned.free(allocator);
        const gop = try self.map.getOrPut(allocator, name);
        if (gop.found_existing) {
            gop.value_ptr.free(allocator);
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
        entry.value.free(allocator);
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
            if (!std.mem.eql(u8, name, other_name) or !v.deepEql(other_v)) return false;
        }
        return true;
    }

    /// The values as the JSON object putJson reads: names to numbers, booleans, strings, and
    /// arrays and objects of them, in their order.
    pub fn jsonStringify(self: ParamValues, jw: *std.json.Stringify) !void {
        try jw.beginObject();
        for (self.map.keys(), self.map.values()) |name, v| {
            try jw.objectField(name);
            try v.jsonStringify(jw);
        }
        try jw.endObject();
    }

    /// Sets the parameters a JSON object of names and values gives (a `-P` file), over any
    /// they had; a null gives none, so the parameter takes its script's value. Text that
    /// isn't JSON, JSON that isn't one object, or a value no parameter takes (values nested
    /// deeper than a list of objects) is refused with error.InvalidParams, and `why`
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
            const param = try Literal.ofJsonValue(arena.allocator(), v, MAX_DEPTH, &refused) orelse {
                why.* = allocator.print("parameter '{s}' {s} {s}; a parameter takes numbers, strings, true or false, and arrays and objects of them, two deep at most", .{ name, if (v == .array or v == .object) "holds" else "is", kindOf(refused) }) catch null;
                return error.InvalidParams;
            };
            try self.put(allocator, name, param);
        }
    }
};

/// What kind of JSON value `v`, which no parameter takes, is, for a refusal ("null").
fn kindOf(v: std.json.Value) []const u8 {
    return switch (v) {
        .array, .object => "values nested too deep",
        .null => "null",
        else => "a number past the largest (1.8e308)",
    };
}
