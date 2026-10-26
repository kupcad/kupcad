//! A parameter's rules: what kind of value `param(:name, default:, type:, validate:)` holds, and
//! what each part of it may be. One model for the run (stdlib/params.zig checks a value against
//! it) and for `kupcad doc`'s schema (tools/doc/extractor.zig reads it from the script's
//! literals): both give `build` what the script wrote, as `Literal`s, and `check` reads a value
//! (the default, or a host's) as the rules say, as the script then holds it.
//!
//! What `validate:` leaves out is the default's: `[5, 10]` is a list of numbers, `[[0, 0],
//! [10, 0]]` a list of tuples of two numbers, `[{ type: "slot", depth: 5 }]` a list of Maps with
//! those fields. A value nests at most MAX_DEPTH deep: a list (`items:`) or a tuple (`tuple:`)
//! of scalars, of lists or tuples of scalars, or of flat Maps (`fields:`); a Map's fields are
//! scalars.

const std = @import("std");
const json_input = @import("json_input.zig");
const fmtNumber = @import("value.zig").fmtNumber;

/// How deep a value nests: a list of points, or of flat Maps, is two deep.
pub const MAX_DEPTH = 2;
/// How deep a `Literal` made of a script's value or a host's JSON may nest: rules nest more
/// than values do (a Map in a list in a Map), and anything past this is refused.
pub const MAX_LITERAL_DEPTH = 16;
/// The keys `validate:` takes, and those a nested rule takes besides.
const RULE_KEYS = [_][]const u8{ "min", "max", "in", "items", "tuple", "fields", "min_items", "max_items" };
const NESTED_KEYS = [_][]const u8{ "type", "title", "unit", "step" };
const TAKES = "min:, max:, in:, items:, tuple:, fields:, min_items:, max_items:";
const KIND_NAMES = ":number, :string, :boolean, :symbol, :array or :map";

pub const Kind = enum {
    number,
    string,
    boolean,
    symbol,
    array,
    map,

    /// What an error says a place of this kind expects: "a number", "true or false".
    pub fn described(self: Kind) []const u8 {
        return switch (self) {
            .number => "a number",
            .string => "a String",
            .boolean => "true or false",
            .symbol => "a Symbol",
            .array => "an Array",
            .map => "a Map",
        };
    }

    pub fn isScalar(self: Kind) bool {
        return self != .array and self != .map;
    }

    /// The schema's name of it: a Symbol parameter is a "string" with its choices.
    pub fn schemaName(self: Kind) []const u8 {
        return if (self == .symbol) "string" else @tagName(self);
    }
};

/// A value as a declaration writes it (its default, its rules) or a host gives it.
pub const Literal = union(enum) {
    number: f64,
    string: []const u8,
    symbol: []const u8,
    boolean: bool,
    nil,
    array: []const Literal,
    /// A Map's entries, keyed by name (a Symbol's or a String's).
    map: []const Entry,

    pub const Entry = struct { key: []const u8, value: Literal };

    pub fn kind(self: Literal) ?Kind {
        return switch (self) {
            .number => .number,
            .string => .string,
            .symbol => .symbol,
            .boolean => .boolean,
            .array => .array,
            .map => .map,
            .nil => null,
        };
    }

    /// A String's or a Symbol's text.
    pub fn text(self: Literal) ?[]const u8 {
        return switch (self) {
            .string, .symbol => |t| t,
            else => null,
        };
    }

    /// A Map's value under `key`; null when it has none, or isn't a Map.
    pub fn get(self: Literal, key: []const u8) ?Literal {
        if (self != .map) return null;
        for (self.map) |entry| if (std.mem.eql(u8, entry.key, key)) return entry.value;
        return null;
    }

    /// Whether two scalars are one value (a choice and what was given).
    pub fn eql(a: Literal, b: Literal) bool {
        return switch (a) {
            .number => |n| b == .number and b.number == n,
            .boolean => |flag| b == .boolean and b.boolean == flag,
            .string => |t| b == .string and std.mem.eql(u8, b.string, t),
            .symbol => |t| b == .symbol and std.mem.eql(u8, b.symbol, t),
            .nil => b == .nil,
            .array, .map => false,
        };
    }

    /// As JSON: a Symbol as its text, a Map as an object.
    pub fn jsonStringify(self: Literal, jw: *std.json.Stringify) !void {
        switch (self) {
            .number => |n| try jw.write(n),
            .string, .symbol => |t| try jw.write(t),
            .boolean => |b| try jw.write(b),
            .nil => try jw.write(null),
            .array => |items| {
                try jw.beginArray();
                for (items) |item| try item.jsonStringify(jw);
                try jw.endArray();
            },
            .map => |entries| {
                try jw.beginObject();
                for (entries) |entry| {
                    try jw.objectField(entry.key);
                    try entry.value.jsonStringify(jw);
                }
                try jw.endObject();
            },
        }
    }

    /// As an error shows what was given: 5, "abc", :m5, true, nil, an Array, a Map.
    pub fn format(self: Literal, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .number => |n| try writer.print("{f}", .{fmtNumber(n)}),
            .string => |t| try writer.print("\"{s}\"", .{t}),
            .symbol => |t| try writer.print(":{s}", .{t}),
            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
            .nil => try writer.writeAll("nil"),
            .array => try writer.writeAll("an Array"),
            .map => try writer.writeAll("a Map"),
        }
    }

    /// JSON as a Literal, its text borrowed from `json`; null for what no value holds (a
    /// number past 1.8e308, arrays and objects nested past MAX_LITERAL_DEPTH).
    pub fn ofJson(arena: std.mem.Allocator, json: std.json.Value) !?Literal {
        return ofJsonAt(arena, json, MAX_LITERAL_DEPTH);
    }

    fn ofJsonAt(arena: std.mem.Allocator, json: std.json.Value, depth: usize) !?Literal {
        switch (json) {
            .integer => |n| return .{ .number = @floatFromInt(n) },
            .float => |f| return .{ .number = f },
            .number_string => |t| {
                const f = std.fmt.parseFloat(f64, t) catch return null;
                return if (std.math.isFinite(f)) .{ .number = f } else null;
            },
            .bool => |b| return .{ .boolean = b },
            .string => |t| return .{ .string = t },
            .null => return .nil,
            .array => |items| {
                if (depth == 0) return null;
                const out = try arena.alloc(Literal, items.items.len);
                for (items.items, out) |item, *o| o.* = try ofJsonAt(arena, item, depth - 1) orelse return null;
                return .{ .array = out };
            },
            .object => |object| {
                if (depth == 0) return null;
                const out = try arena.alloc(Entry, object.count());
                for (object.keys(), object.values(), out) |key, item, *o| {
                    o.* = .{ .key = key, .value = try ofJsonAt(arena, item, depth - 1) orelse return null };
                }
                return .{ .map = out };
            },
        }
    }
};

/// What a value, or a part of it, may be.
pub const Rule = struct {
    kind: Kind,
    /// A number's bounds.
    min: ?f64 = null,
    max: ?f64 = null,
    /// The values a scalar may be.
    choices: ?[]const Literal = null,
    /// A list's rule for each element...
    items: ?*const Rule = null,
    /// ...or a tuple's for each place.
    tuple: ?[]const Rule = null,
    /// A Map's fields, in order.
    fields: ?[]const Field = null,
    /// How many elements a list may have.
    min_items: ?usize = null,
    max_items: ?usize = null,
    /// For a host's control: what it is labelled, what a number is in, its step.
    title: ?[]const u8 = null,
    unit: ?[]const u8 = null,
    step: ?f64 = null,

    pub const Field = struct { name: []const u8, rule: Rule };

    /// As the schema has it (`ParamSpec`'s fields): a field's rule with its name.
    pub fn jsonStringify(self: Rule, jw: *std.json.Stringify) !void {
        try jw.beginObject();
        try self.writeFields(jw);
        try jw.endObject();
    }

    /// Its fields, into an object begun by the caller.
    pub fn writeFields(self: Rule, jw: *std.json.Stringify) !void {
        try jw.objectField("type");
        try jw.write(self.kind.schemaName());
        try jw.objectField("min");
        try jw.write(self.min);
        try jw.objectField("max");
        try jw.write(self.max);
        try jw.objectField("in");
        try jw.write(self.choices);
        try jw.objectField("items");
        try jw.write(self.items);
        try jw.objectField("tuple");
        try jw.write(self.tuple);
        try jw.objectField("fields");
        if (self.fields) |fields| {
            try jw.beginArray();
            for (fields) |field| {
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(field.name);
                try field.rule.writeFields(jw);
                try jw.endObject();
            }
            try jw.endArray();
        } else try jw.write(null);
        try jw.objectField("min_items");
        try jw.write(self.min_items);
        try jw.objectField("max_items");
        try jw.write(self.max_items);
        try jw.objectField("title");
        try jw.write(self.title);
        try jw.objectField("unit");
        try jw.write(self.unit);
        try jw.objectField("step");
        try jw.write(self.step);
    }
};

/// A step into a value: an element's index, or a field's name.
pub const Step = union(enum) {
    index: usize,
    field: []const u8,

    pub fn jsonStringify(self: Step, jw: *std.json.Stringify) !void {
        switch (self) {
            .index => |i| try jw.write(i),
            .field => |f| try jw.write(f),
        }
    }
};

/// A parameter, or a place in its value, as an error names it: `:points[1][0]`,
/// `:cutouts[0][:depth]`.
pub const Place = struct {
    name: []const u8,
    path: []const Step = &.{},

    pub fn format(self: Place, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(":{s}", .{self.name});
        for (self.path) |step| switch (step) {
            .index => |i| try writer.print("[{d}]", .{i}),
            .field => |f| try writer.print("[:{s}]", .{f}),
        };
    }
};

/// Why `check` refused a value: where in it, what that place takes, what it was given.
pub const Refusal = struct {
    path: []const Step,
    /// "a number at least 10", "one of :m3, :m4", "3 items".
    expected: []const u8,
    /// 5, "abc", :m5, an Array, nothing.
    got: []const u8,
    /// Of another kind (a TypeError), else of its kind but against its rules (a ValueError).
    wrong_kind: bool,
};

/// What a declaration says of its parameter's value.
pub const Declaration = struct {
    /// The parameter's name, for the errors.
    name: []const u8,
    /// `type:`, a Symbol naming the kind.
    type: ?Literal = null,
    default: Literal = .nil,
    /// `validate:`, a Map of rules.
    validate: ?Literal = null,
    /// The parameter's own `title:`, `unit:` and `step:`; a unit and a step are for every
    /// number in it without its own.
    title: ?[]const u8 = null,
    unit: ?[]const u8 = null,
    step: ?f64 = null,
    /// The kind when nothing gives one: a String (one with no default is text until a host
    /// gives it some), or the extractor's guess for a default only the run computes.
    fallback: Kind = .string,
};

/// The rules a declaration gives, and its default read by them (nil for none).
pub const Built = struct {
    rule: Rule,
    default: Literal,
};

pub const BuildError = error{ OutOfMemory, InvalidRule };
pub const CheckError = error{ OutOfMemory, Refused };

/// The rules `declaration` gives, in `arena`; error.InvalidRule, `why` the ArgumentError's
/// message ("parameter :w's validate: takes no colour: ..."), for rules no parameter can have
/// or a default they refuse.
pub fn build(arena: std.mem.Allocator, declaration: Declaration, why: *[]const u8) BuildError!Built {
    var b: Builder = .{ .arena = arena, .name = declaration.name, .why = why };
    const of_default: ?Rule = if (declaration.default == .nil) null else try b.inferred(declaration.default, 0);
    const named: ?Kind = if (declaration.type) |t| try b.kindNamed(t, "type:") else null;
    if (named) |n| if (of_default) |d| if (d.kind != n) {
        return b.fail(" is {s} by its type:, and its default is {s}", .{ n.described(), d.kind.described() });
    };
    var rule = if (declaration.validate) |v|
        try b.declared(v, 0, of_default, named, "validate:", true, declaration.fallback)
    else
        of_default orelse try b.bare(named orelse declaration.fallback, "type:");
    rule.title = declaration.title;
    if (declaration.unit != null or declaration.step != null) {
        if (!holdsNumbers(rule)) return b.fail(" is {s}, and {s} is for numbers", .{ rule.kind.described(), if (declaration.step != null) "step:" else "unit:" });
        rule = try b.withNumbers(rule, declaration.unit, declaration.step);
    }
    var refusal: Refusal = undefined;
    const default = if (declaration.default == .nil) Literal.nil else check(arena, rule, declaration.default, &refusal) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Refused => return b.fail("'s default doesn't meet its rules: {f} expects {s}, got {s}", .{ Place{ .name = declaration.name, .path = refusal.path }, refusal.expected, refusal.got }),
    };
    return .{ .rule = rule, .default = default };
}

/// `value` read by `rule`, in `arena`, as the script holds it: text from a host read as the
/// place's kind (`-p w=10` a number, `-p xs=[1, 2]` an Array, as JSON), a String a Symbol where
/// the rule says so, a Map's keys its fields' names, in their order. error.Refused, `refusal`
/// saying where and why, for a value the rules don't take.
pub fn check(arena: std.mem.Allocator, rule: Rule, value: Literal, refusal: *Refusal) CheckError!Literal {
    var path: std.ArrayList(Step) = .empty;
    var c: Checker = .{ .arena = arena, .refusal = refusal, .path = &path };
    return c.read(rule, value, true);
}

/// Whether a value of `rule` holds a number anywhere.
fn holdsNumbers(rule: Rule) bool {
    if (rule.kind == .number) return true;
    if (rule.items) |items| return holdsNumbers(items.*);
    for (rule.tuple orelse &.{}) |place| if (holdsNumbers(place)) return true;
    for (rule.fields orelse &.{}) |field| if (holdsNumbers(field.rule)) return true;
    return false;
}

const Builder = struct {
    arena: std.mem.Allocator,
    name: []const u8,
    why: *[]const u8,

    fn fail(self: *Builder, comptime fmt: []const u8, args: anytype) BuildError {
        self.why.* = std.fmt.allocPrint(self.arena, "parameter :{s}" ++ fmt, .{self.name} ++ args) catch return error.OutOfMemory;
        return error.InvalidRule;
    }

    fn ptr(self: *Builder, rule: Rule) !*const Rule {
        const p = try self.arena.create(Rule);
        p.* = rule;
        return p;
    }

    /// The kind `t` (`:number`) names.
    fn kindNamed(self: *Builder, t: Literal, comptime where: []const u8) BuildError!Kind {
        const name = if (t == .symbol) t.symbol else "";
        return std.meta.stringToEnum(Kind, name) orelse self.fail("'s " ++ where ++ " is " ++ KIND_NAMES ++ ", got {f}", .{t});
    }

    /// A rule of `kind` with nothing else to go by: an Array a list of Strings; a Map has
    /// none, so is refused.
    fn bare(self: *Builder, kind: Kind, where: []const u8) BuildError!Rule {
        return switch (kind) {
            .array => .{ .kind = .array, .items = try self.ptr(.{ .kind = .string }) },
            .map => self.fail("'s {s} makes it a Map, with no fields: (nor a default to give them)", .{where}),
            else => .{ .kind = kind },
        };
    }

    /// The rules a default implies: its kind, and its parts'. At the top an Array is a list,
    /// whose elements must all be alike; an Array in it is a tuple, each place of its own kind.
    fn inferred(self: *Builder, v: Literal, depth: usize) BuildError!Rule {
        switch (v) {
            .nil => return self.fail("'s default holds nil: a parameter's value is made of numbers, Strings, true or false and Symbols", .{}),
            .array => |items| {
                if (depth == MAX_DEPTH) return self.fail("'s default nests deeper than a list of tuples or of Maps", .{});
                if (depth > 0) {
                    const places = try self.arena.alloc(Rule, items.len);
                    for (items, places) |item, *at| at.* = try self.inferred(item, depth + 1);
                    return .{ .kind = .array, .tuple = places };
                }
                if (items.len == 0) return self.bare(.array, "default");
                const first = try self.inferred(items[0], depth + 1);
                for (items[1..], 1..) |item, i| {
                    if (!alike(first, try self.inferred(item, depth + 1))) {
                        return self.fail("'s default holds elements unlike each other ([0] and [{d}]): give its rules, validate: {{ items: ... }} or {{ tuple: [...] }}", .{i});
                    }
                }
                return .{ .kind = .array, .items = try self.ptr(first) };
            },
            .map => |entries| {
                if (depth == MAX_DEPTH) return self.fail("'s default nests deeper than a list of tuples or of Maps", .{});
                const fields = try self.arena.alloc(Rule.Field, entries.len);
                for (entries, fields) |entry, *field| {
                    const kind = entry.value.kind() orelse return self.fail("'s default holds nil in its field :{s}", .{entry.key});
                    if (!kind.isScalar()) return self.fail("'s default holds {s} in its field :{s}: a Map's fields are numbers, Strings, true or false and Symbols", .{ kind.described(), entry.key });
                    field.* = .{ .name = entry.key, .rule = .{ .kind = kind } };
                }
                return .{ .kind = .map, .fields = fields };
            },
            else => return .{ .kind = v.kind().? },
        }
    }

    /// The rules `v` (a Map, or a part's kind's name) declares at `where`, over what the
    /// default implies there (`hint`); of the kind `named` when its parameter's `type:` names
    /// one. `top` is `validate:` itself, which takes no `type:` (the parameter's does that).
    fn declared(self: *Builder, v: Literal, depth: usize, hint: ?Rule, named: ?Kind, where: []const u8, top: bool, fallback: Kind) BuildError!Rule {
        if (v == .symbol and !top) {
            const kind = try self.kindNamed(v, "rule");
            try self.within(kind, depth, where);
            if (hint) |h| {
                if (h.kind == kind) return h;
                return self.fail("'s {s} is for {s}{s}", .{ where, kind.described(), try self.againstDefault(hint, top) });
            }
            return self.bare(kind, where);
        }
        if (v != .map) return self.fail("'s {s} is a Map of rules, as {{ min: 0 }}, got {f}", .{ where, v });
        for (v.map) |entry| {
            if (isKey(&RULE_KEYS, entry.key) or (!top and isKey(&NESTED_KEYS, entry.key))) continue;
            return self.fail("'s {s} takes no {s}: (it takes " ++ TAKES ++ "{s})", .{ where, entry.key, if (top) "" else ", type:, title:, unit:, step:" });
        }

        // The rule's own word for its kind, else what its rules are for, else the default's
        const own: ?Kind = if (v.get("type")) |t| try self.kindNamed(t, "rule's type:") else null;
        const stated = named orelse own orelse structural(v);
        if (stated) |kind| if (hint) |h| if (h.kind != kind) {
            return self.fail("'s {s} is for {s}{s}", .{ where, kind.described(), try self.againstDefault(hint, top) });
        };
        const numeric: ?Kind = if (v.get("min") != null or v.get("max") != null or v.get("unit") != null or v.get("step") != null) .number else null;
        const kind = stated orelse (if (hint) |h| h.kind else null) orelse choicesKind(v) orelse numeric orelse fallback;
        try self.within(kind, depth, where);
        var rule: Rule = if (hint) |h| h else if (kind == .map) .{ .kind = .map } else try self.bare(kind, where);

        if (v.get("min")) |m| rule.min = try self.number(where, "min", m, kind);
        if (v.get("max")) |m| rule.max = try self.number(where, "max", m, kind);
        if (v.get("in")) |listed| rule.choices = try self.choices(where, listed, kind);
        if (v.get("title")) |t| rule.title = t.text() orelse return self.fail("'s {s} title: is a String, got {f}", .{ where, t });
        if (v.get("unit")) |u| {
            if (kind != .number) return self.fail("'s {s} unit: is for numbers, and it is {s}", .{ where, kind.described() });
            rule.unit = u.text() orelse return self.fail("'s {s} unit: is a String, got {f}", .{ where, u });
        }
        if (v.get("step")) |s| {
            const step = try self.number(where, "step", s, kind);
            if (!(step > 0)) return self.fail("'s {s} step: is a number above 0, got {f}", .{ where, s });
            rule.step = step;
        }

        const items = v.get("items");
        const tuple = v.get("tuple");
        if (items != null and tuple != null) return self.fail("'s {s} has both items: and tuple: (a list's rules, or a tuple's)", .{where});
        for ([_][]const u8{ "items", "tuple", "min_items", "max_items" }) |key| if (v.get(key) != null and kind != .array) {
            return self.fail("'s {s} {s}: is for an Array, and it is {s}", .{ where, key, kind.described() });
        };
        if (items) |rules| {
            const hinted: ?Rule = if (hint) |h| (if (h.items) |i| i.* else null) else null;
            rule.items = try self.ptr(try self.declared(rules, depth + 1, hinted, null, try self.place(where, "items:", .{}), false, .string));
            rule.tuple = null;
        }
        if (tuple) |rules| {
            if (rules != .array) return self.fail("'s {s} tuple: is a list of each place's rules, got {f}", .{ where, rules });
            const hinted: []const Rule = if (hint) |h| h.tuple orelse &.{} else &.{};
            const read = try self.arena.alloc(Rule, rules.array.len);
            for (rules.array, read, 0..) |place_rules, *r, i| {
                const at = try self.place(where, "tuple: [{d}]", .{i});
                r.* = try self.declared(place_rules, depth + 1, if (i < hinted.len) hinted[i] else null, null, at, false, .string);
            }
            rule.tuple = read;
            rule.items = null;
        }
        if (v.get("min_items")) |m| rule.min_items = try self.count(where, "min_items", m);
        if (v.get("max_items")) |m| rule.max_items = try self.count(where, "max_items", m);
        if (rule.min_items != null or rule.max_items != null) {
            if (rule.tuple) |places| return self.fail("'s {s} counts a list's items, and it is a tuple of {d}", .{ where, places.len });
            if ((rule.min_items orelse 0) > (rule.max_items orelse std.math.maxInt(usize))) {
                return self.fail("'s {s} min_items: {d} is above its max_items: {d}", .{ where, rule.min_items.?, rule.max_items.? });
            }
        }

        if (v.get("fields")) |fields| {
            if (kind != .map) return self.fail("'s {s} fields: is for a Map, and it is {s}", .{ where, kind.described() });
            if (fields != .map) return self.fail("'s {s} fields: is a Map of each field's rules, got {f}", .{ where, fields });
            const hinted: []const Rule.Field = if (hint) |h| h.fields orelse &.{} else &.{};
            const read = try self.arena.alloc(Rule.Field, fields.map.len);
            for (fields.map, read) |entry, *field| {
                var hinted_field: ?Rule = null;
                for (hinted) |h| {
                    if (std.mem.eql(u8, h.name, entry.key)) hinted_field = h.rule;
                }
                const at = try self.place(where, "fields: :{s}", .{entry.key});
                const field_rule = try self.declared(entry.value, depth + 1, hinted_field, null, at, false, .string);
                if (!field_rule.kind.isScalar()) return self.fail("'s {s} is {s}: a Map's fields are numbers, Strings, true or false and Symbols", .{ at, field_rule.kind.described() });
                field.* = .{ .name = entry.key, .rule = field_rule };
            }
            rule.fields = read;
        }
        if (kind == .map and rule.fields == null) return self.fail("'s {s} makes it a Map, with no fields: (nor a default to give them)", .{where});
        return rule;
    }

    /// Refuses an Array or a Map where nothing nests any deeper.
    fn within(self: *Builder, kind: Kind, depth: usize, where: []const u8) BuildError!void {
        if (depth >= MAX_DEPTH and !kind.isScalar()) return self.fail("'s {s} nests deeper than a list of tuples or of Maps", .{where});
    }

    fn place(self: *Builder, where: []const u8, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s} " ++ fmt, .{where} ++ args);
    }

    /// ", and its default is a String" (", ... there" for a part's), for a rule against its
    /// default; empty for none.
    fn againstDefault(self: *Builder, hint: ?Rule, top: bool) ![]const u8 {
        const h = hint orelse return "";
        return std.fmt.allocPrint(self.arena, ", and its default{s} is {s}", .{ if (top) "" else " there", h.kind.described() });
    }

    fn number(self: *Builder, where: []const u8, comptime key: []const u8, v: Literal, kind: Kind) BuildError!f64 {
        if (kind != .number) return self.fail("'s {s} " ++ key ++ ": is for numbers, and it is {s}", .{ where, kind.described() });
        return if (v == .number) v.number else self.fail("'s {s} " ++ key ++ ": is a number, got {f}", .{ where, v });
    }

    fn count(self: *Builder, where: []const u8, comptime key: []const u8, v: Literal) BuildError!usize {
        if (v == .number and v.number >= 0 and @trunc(v.number) == v.number and v.number <= std.math.maxInt(u32)) return @intFromFloat(v.number);
        return self.fail("'s {s} " ++ key ++ ": is a whole number, 0 or more, got {f}", .{ where, v });
    }

    /// `in:`'s choices, each read as `kind`.
    fn choices(self: *Builder, where: []const u8, v: Literal, kind: Kind) BuildError![]const Literal {
        if (!kind.isScalar()) return self.fail("'s {s} in: is for numbers, Strings, true or false and Symbols, and it is {s}: give an element's choices in items:", .{ where, kind.described() });
        if (v != .array) return self.fail("'s {s} in: is a list of choices, got {f}", .{ where, v });
        const read = try self.arena.alloc(Literal, v.array.len);
        for (v.array, read) |choice, *r| {
            var refusal: Refusal = undefined;
            r.* = check(self.arena, .{ .kind = kind }, choice, &refusal) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.Refused => return self.fail("'s {s} in: holds {f}, which isn't {s}", .{ where, choice, kind.described() }),
            };
        }
        return read;
    }

    /// `rule` with `unit` and `step` given to every number in it without its own.
    fn withNumbers(self: *Builder, rule: Rule, unit: ?[]const u8, step: ?f64) BuildError!Rule {
        var out = rule;
        if (rule.kind == .number) {
            out.unit = rule.unit orelse unit;
            out.step = rule.step orelse step;
            return out;
        }
        if (rule.items) |items| out.items = try self.ptr(try self.withNumbers(items.*, unit, step));
        if (rule.tuple) |places| {
            const read = try self.arena.alloc(Rule, places.len);
            for (places, read) |p, *r| r.* = try self.withNumbers(p, unit, step);
            out.tuple = read;
        }
        if (rule.fields) |fields| {
            const read = try self.arena.alloc(Rule.Field, fields.len);
            for (fields, read) |f, *r| r.* = .{ .name = f.name, .rule = try self.withNumbers(f.rule, unit, step) };
            out.fields = read;
        }
        return out;
    }
};

/// The kind `in:`'s choices share; null for none, or choices of more than one.
fn choicesKind(v: Literal) ?Kind {
    const choices = v.get("in") orelse return null;
    if (choices != .array or choices.array.len == 0) return null;
    const first = choices.array[0].kind() orelse return null;
    for (choices.array[1..]) |c| if (c.kind() != first) return null;
    return if (first.isScalar()) first else null;
}

/// The kind `v`'s structure gives: an Array for `items:` or `tuple:`, a Map for `fields:`.
fn structural(v: Literal) ?Kind {
    if (v.get("items") != null or v.get("tuple") != null) return .array;
    if (v.get("fields") != null) return .map;
    return null;
}

fn isKey(comptime keys: []const []const u8, key: []const u8) bool {
    inline for (keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// Whether two parts a default holds are alike: of one kind, a tuple's places and a Map's
/// fields too.
fn alike(a: Rule, b: Rule) bool {
    if (a.kind != b.kind) return false;
    if (a.tuple) |places| {
        const others = b.tuple orelse return false;
        if (places.len != others.len) return false;
        for (places, others) |x, y| if (!alike(x, y)) return false;
    }
    if (a.fields) |fields| {
        const others = b.fields orelse return false;
        if (fields.len != others.len) return false;
        for (fields, others) |x, y| if (!std.mem.eql(u8, x.name, y.name) or !alike(x.rule, y.rule)) return false;
    }
    return true;
}

const Checker = struct {
    arena: std.mem.Allocator,
    refusal: *Refusal,
    path: *std.ArrayList(Step),

    fn refuse(self: *Checker, wrong_kind: bool, expected: []const u8, got: []const u8) CheckError {
        self.refusal.* = .{
            .path = self.arena.dupe(Step, self.path.items) catch return error.OutOfMemory,
            .expected = expected,
            .got = got,
            .wrong_kind = wrong_kind,
        };
        return error.Refused;
    }

    fn shown(self: *Checker, v: Literal) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{f}", .{v});
    }

    fn read(self: *Checker, rule: Rule, v: Literal, root: bool) CheckError!Literal {
        const taken: Literal = switch (rule.kind) {
            .number => blk: {
                const n = numberOf(v) orelse return self.refuse(true, "a number", try self.shown(v));
                // The number read, not the text it was read from
                if (rule.min) |min| if (n < min) return self.refuse(false, try std.fmt.allocPrint(self.arena, "a number at least {f}", .{fmtNumber(min)}), try self.shown(.{ .number = n }));
                if (rule.max) |max| if (n > max) return self.refuse(false, try std.fmt.allocPrint(self.arena, "a number at most {f}", .{fmtNumber(max)}), try self.shown(.{ .number = n }));
                break :blk .{ .number = n };
            },
            .boolean => .{ .boolean = booleanOf(v) orelse return self.refuse(true, "true or false", try self.shown(v)) },
            .string => .{ .string = v.text() orelse return self.refuse(true, "a String", try self.shown(v)) },
            .symbol => .{ .symbol = v.text() orelse return self.refuse(true, "a Symbol", try self.shown(v)) },
            .array => try self.array(rule, try self.parsed(v, .array, root)),
            .map => try self.map(rule, try self.parsed(v, .map, root)),
        };
        if (rule.choices) |choices| {
            for (choices) |choice| {
                if (choice.eql(taken)) return taken;
            }
            var listed: std.Io.Writer.Allocating = .init(self.arena);
            listed.writer.writeAll("one of ") catch return error.OutOfMemory;
            for (choices, 0..) |choice, i| listed.writer.print("{s}{f}", .{ if (i > 0) ", " else "", choice }) catch return error.OutOfMemory;
            // As read: `got :m5`, as the choices are listed
            return self.refuse(false, listed.written(), try self.shown(taken));
        }
        return taken;
    }

    /// `v` as an Array or a Map: itself, or (at the top, from `-p`) its text read as JSON.
    fn parsed(self: *Checker, v: Literal, kind: Kind, root: bool) CheckError!Literal {
        if (v.kind() == kind) return v;
        const as_json = if (kind == .array) "an Array (as JSON: [10, 20])" else "a Map (as JSON: {\"x\": 1})";
        if (v != .string or !root) return self.refuse(true, if (root) as_json else kind.described(), try self.shown(v));
        const json = json_input.parse(std.json.Value, self.arena, v.string, null) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return self.refuse(true, as_json, try self.shown(v)),
        };
        const literal = try Literal.ofJson(self.arena, json.value) orelse return self.refuse(true, as_json, try self.shown(v));
        if (literal.kind() != kind) return self.refuse(true, as_json, try self.shown(v));
        return literal;
    }

    fn array(self: *Checker, rule: Rule, v: Literal) CheckError!Literal {
        const items = v.array;
        if (rule.tuple) |places| {
            if (items.len != places.len) return self.refuse(false, try std.fmt.allocPrint(self.arena, "{d} items", .{places.len}), try std.fmt.allocPrint(self.arena, "{d}", .{items.len}));
        } else {
            if (rule.min_items) |min| if (items.len < min) return self.refuse(false, try std.fmt.allocPrint(self.arena, "at least {d} items", .{min}), try std.fmt.allocPrint(self.arena, "{d}", .{items.len}));
            if (rule.max_items) |max| if (items.len > max) return self.refuse(false, try std.fmt.allocPrint(self.arena, "at most {d} items", .{max}), try std.fmt.allocPrint(self.arena, "{d}", .{items.len}));
        }
        const taken = try self.arena.alloc(Literal, items.len);
        for (items, taken, 0..) |item, *r, i| {
            try self.path.append(self.arena, .{ .index = i });
            r.* = try self.read(if (rule.tuple) |places| places[i] else rule.items.?.*, item, false);
            _ = self.path.pop();
        }
        return .{ .array = taken };
    }

    fn map(self: *Checker, rule: Rule, v: Literal) CheckError!Literal {
        const fields = rule.fields.?;
        for (v.map) |entry| {
            for (fields) |field| {
                if (std.mem.eql(u8, field.name, entry.key)) break;
            } else {
                var listed: std.Io.Writer.Allocating = .init(self.arena);
                listed.writer.writeAll("only its fields ") catch return error.OutOfMemory;
                for (fields, 0..) |field, i| listed.writer.print("{s}:{s}", .{ if (i > 0) ", " else "", field.name }) catch return error.OutOfMemory;
                return self.refuse(false, listed.written(), try std.fmt.allocPrint(self.arena, ":{s}", .{entry.key}));
            }
        }
        const taken = try self.arena.alloc(Literal.Entry, fields.len);
        for (fields, taken) |field, *r| {
            try self.path.append(self.arena, .{ .field = field.name });
            const given = v.get(field.name) orelse return self.refuse(true, field.rule.kind.described(), "nothing");
            r.* = .{ .key = field.name, .value = try self.read(field.rule, given, false) };
            _ = self.path.pop();
        }
        return .{ .map = taken };
    }
};

/// A number, or text a host gave (`-p width=10.5`) that reads as a finite one, as a script's
/// numbers are (parseFloat reads "inf" and "nan" too).
fn numberOf(v: Literal) ?f64 {
    return switch (v) {
        .number => |n| n,
        .string => |t| blk: {
            const n = std.fmt.parseFloat(f64, t) catch break :blk null;
            break :blk if (std.math.isFinite(n)) n else null;
        },
        else => null,
    };
}

/// true or false, the numbers 1 and 0, or the text "true", "false", "1" and "0".
fn booleanOf(v: Literal) ?bool {
    return switch (v) {
        .boolean => |b| b,
        .number => |n| if (n == 1) true else if (n == 0) false else null,
        .string => |t| if (std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "1")) true else if (std.mem.eql(u8, t, "false") or std.mem.eql(u8, t, "0")) false else null,
        else => null,
    };
}
