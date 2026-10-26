//! `param()` with values a host gives, injected as every host injects them (api.injectParams):
//! text and JSON read by the parameter's rules (core/param_rules.zig), typed values checked
//! against them; and the rules a declaration may and may not have.

const std = @import("std");
const testing = std.testing;
const api = @import("../api.zig");
const support = @import("../test_support.zig");
const VM = @import("../vm/vm.zig").VM;
const InterpretResult = @import("../vm/vm.zig").InterpretResult;

/// Runs `source` with one value for parameter `name`; the run's result.
fn runWith(name: []const u8, v: api.ParamValue, source: []const u8, vm: *VM) !InterpretResult {
    var values: api.ParamValues = .{};
    defer values.deinit(testing.allocator);
    try values.put(testing.allocator, name, v);
    try api.injectParams(vm, &values);
    return support.runOn(vm, source);
}

const Taken = struct { name: []const u8 = "p", v: api.ParamValue, source: []const u8, expected: support.Expected };

/// Each case's `r`, its source run with its one value.
fn expectTaken(cases: []const Taken) !void {
    for (cases) |case| {
        errdefer std.debug.print("{s}: {s}\n", .{ case.name, case.source });
        var vm = try support.initVm();
        defer vm.deinit();
        const result = try runWith(case.name, case.v, case.source, &vm);
        if (result != .ok) std.debug.print("{s}\n", .{vm.last_error orelse ""});
        try testing.expectEqual(.ok, result);
        try support.expectValue(case.expected, vm.globals.get("r").?);
    }
}

const Refused = struct { name: []const u8 = "p", v: api.ParamValue, source: []const u8, message: []const u8 };

/// Each case's error, its source run with its one value; the report names the parameter.
fn expectRefused(cases: []const Refused) !void {
    for (cases) |case| {
        errdefer std.debug.print("{s}: {s}\n", .{ case.name, case.source });
        var vm = try support.initVm();
        defer vm.deinit();
        try testing.expectEqual(.runtime_error, try runWith(case.name, case.v, case.source, &vm));
        try testing.expectEqualStrings(case.message, vm.last_error orelse "");
        try testing.expectEqualStrings(case.name, vm.report.refused_param orelse "");
    }
}

test "param: text from the host is read as the parameter's type" {
    // `-p` gives text: it used to have to be a number, whatever the parameter was.
    try expectTaken(&.{
        .{ .v = .{ .text = "10.5" }, .source = "r = param(:p, default: 1)", .expected = .{ .num = 10.5 } },
        .{ .v = .{ .text = "true" }, .source = "r = param(:p, default: false)", .expected = .{ .boolean = true } },
        .{ .v = .{ .text = "0" }, .source = "r = param(:p, default: true)", .expected = .{ .boolean = false } },
        .{ .v = .{ .text = "1" }, .source = "r = param(:p, default: false)", .expected = .{ .boolean = true } },
        .{ .v = .{ .text = "Gear A" }, .source = "r = param(:p, default: \"x\")", .expected = .{ .str = "Gear A" } },
        .{ .v = .{ .text = "" }, .source = "r = param(:p, default: \"x\")", .expected = .{ .str = "" } },
        .{ .v = .{ .text = "m4" }, .source = "s = param(:p, default: :m3, validate: { in: [:m3, :m4] })\nr = s == :m4 && s.class == Symbol", .expected = .{ .boolean = true } },
        .{ .v = .{ .text = "-1000" }, .source = "r = param(:p, default: 1)", .expected = .{ .num = -1000 } },
        .{ .v = .{ .text = "10" }, .source = "r = param(:p, default: 15, validate: { min: 10, max: 20 })", .expected = .{ .num = 10 } },
        .{ .v = .{ .text = "20" }, .source = "r = param(:p, default: 15, validate: { min: 10, max: 20 })", .expected = .{ .num = 20 } },
    });
}

test "param: text a host gives that isn't UTF-8 is an error where a String must be text" {
    // A shell passes bytes (`-p label=$'\xff'`); a script can't write them itself
    const cases = [_]struct { source: []const u8, expected: []const u8 }{
        .{ .source = comptime "label = param(:label, default: \"x\")\n" ++ support.rescued("text(label)"), .expected = "ValueError: text: the String isn't valid UTF-8" },
        .{ .source = comptime "label = param(:label, default: \"x\")\n" ++ support.rescued("label.split(\"\")"), .expected = "ValueError: split: the String isn't valid UTF-8" },
    };
    for (cases) |case| {
        errdefer std.debug.print("{s}\n", .{case.source});
        var vm = try support.initVm();
        defer vm.deinit();
        try testing.expectEqual(.ok, try runWith("label", .{ .text = "a\xff" }, case.source, &vm));
        try support.expectValue(.{ .str = case.expected }, vm.globals.get("r").?);
    }
}

test "param: a symbol parameter's value is a Symbol, so its in: choices are symbols" {
    // It was a String, which no symbol in `in:` equals: the parameter refused its own default.
    try support.expectScripts(&.{
        .{ .src = "s = param(:size, default: :m3, validate: { in: [:m3, :m4] })\nr = s == :m3 && s.class == Symbol", .expected = .{ .boolean = true } },
        // Choices written as Strings are the default's kind's
        .{ .src = "r = param(:size, default: :m3, validate: { in: [\"m3\", \"m4\"] }).class == Symbol", .expected = .{ .boolean = true } },
    });
}

test "param: a value the parameter can't take is an error naming it, what it expects and what was given" {
    try expectRefused(&.{
        .{ .v = .{ .text = "wide" }, .source = "param(:p, default: 1)", .message = "TypeError: parameter :p expects a number, got \"wide\"" },
        // A script's numbers are finite: parseFloat would read these
        .{ .v = .{ .text = "inf" }, .source = "param(:p, default: 1)", .message = "TypeError: parameter :p expects a number, got \"inf\"" },
        .{ .v = .{ .text = "nan" }, .source = "param(:p, default: 1)", .message = "TypeError: parameter :p expects a number, got \"nan\"" },
        .{ .v = .{ .boolean = true }, .source = "param(:p, default: 1)", .message = "TypeError: parameter :p expects a number, got true" },
        .{ .v = .{ .text = "yes" }, .source = "param(:p, default: false)", .message = "TypeError: parameter :p expects true or false, got \"yes\"" },
        .{ .v = .{ .number = 5 }, .source = "param(:p, default: \"x\")", .message = "TypeError: parameter :p expects a String, got 5" },
        .{ .v = .{ .number = 42 }, .source = "param(:p, default: false)", .message = "TypeError: parameter :p expects true or false, got 42" },
        .{ .v = .{ .text = "m5" }, .source = "param(:p, default: :m3, validate: { in: [:m3, :m4] })", .message = "ValueError: parameter :p expects one of :m3, :m4, got :m5" },
        .{ .v = .{ .text = "M3" }, .source = "param(:p, default: :m3, validate: { in: [:m3, :m4] })", .message = "ValueError: parameter :p expects one of :m3, :m4, got :M3" },
        .{ .v = .{ .text = "200" }, .source = "param(:p, default: 1, validate: { max: 100 })", .message = "ValueError: parameter :p expects a number at most 100, got 200" },
        .{ .v = .{ .number = 5 }, .source = "param(:p, default: 15, validate: { min: 10, max: 20 })", .message = "ValueError: parameter :p expects a number at least 10, got 5" },
    });
}

test "param: step, unit, group, title and description are a host's hints, checked but not applied to the value" {
    try support.expectScripts(&.{
        .{ .src = "r = param(:w, default: 10, step: 0.5, unit: \"mm\", group: \"Size\")", .expected = .{ .num = 10 } },
        .{ .src = "r = param(:label, default: \"A\", group: :Text)", .expected = .{ .str = "A" } },
        .{ .src = "r = param(:w, default: 10, title: \"Width\", description: \"Across the plate\")", .expected = .{ .num = 10 } },
        .{ .src = "r = param(:size, default: [10, 20], unit: \"mm\", step: 0.5)[1]", .expected = .{ .num = 20 } },
        .{ .src = comptime support.rescued("param(:w, default: 1, title: 5)"), .expected = .{ .str = "TypeError: param expects a String or Symbol for title, got Number" } },
        .{ .src = comptime support.rescued("param(:w, default: 1, step: 0)"), .expected = .{ .str = "ValueError: parameter :w step must be a number greater than 0, got 0" } },
        .{ .src = comptime support.rescued("param(:label, default: \"A\", step: 1)"), .expected = .{ .str = "ArgumentError: parameter :label is a String, and step: is for numbers" } },
        .{ .src = comptime support.rescued("param(:on, default: true, unit: \"mm\")"), .expected = .{ .str = "ArgumentError: parameter :on is true or false, and unit: is for numbers" } },
        .{ .src = comptime support.rescued("param(:w, default: 1, step: \"x\")"), .expected = .{ .str = "TypeError: param expects a number for step, got String" } },
        .{ .src = comptime support.rescued("param(:w, default: 1, colour: \"x\")"), .expected = .{ .str = "ArgumentError: param does not take a keyword 'colour' (it accepts: default, type, validate, step, unit, group, title, description)" } },
    });
    // A value off the step is the host's to give: -p 10.3 with step: 0.5 stays 10.3
    try expectTaken(&.{.{ .v = .{ .text = "10.3" }, .source = "r = param(:p, default: 10, step: 0.5)", .expected = .{ .num = 10.3 } }});
}

test "param: one with no default is nil until a host gives it a value, a String unless typed" {
    // It was a number by a default it didn't have, and refused its own nil
    try support.expectScripts(&.{
        .{ .src = "r = param(:key, title: \"Key\")", .expected = .nil },
        .{ .src = "r = param(:key, default: nil)", .expected = .nil },
        .{ .src = "r = param(:key, type: :number)", .expected = .nil },
        .{ .src = "r = param(:key, type: :array, validate: { items: :number })", .expected = .nil },
        // Nil is no value to check
        .{ .src = "r = param(:key, type: :number, validate: { min: 1, in: [2, 3] })", .expected = .nil },
    });
    try expectTaken(&.{
        .{ .v = .{ .text = "5" }, .source = "r = param(:p, title: \"Key\")", .expected = .{ .str = "5" } },
        .{ .v = .{ .text = "5" }, .source = "r = param(:p, default: nil)", .expected = .{ .str = "5" } },
        .{ .v = .{ .text = "5" }, .source = "r = param(:p, type: :number)", .expected = .{ .num = 5 } },
        .{ .v = .{ .text = "true" }, .source = "r = param(:p, type: :boolean)", .expected = .{ .boolean = true } },
        .{ .v = .{ .text = "m4" }, .source = "r = param(:p, type: :symbol) == :m4", .expected = .{ .boolean = true } },
        // Of choices all Symbols, it is a Symbol, or no value could be one of them
        .{ .v = .{ .text = "m4" }, .source = "r = param(:p, validate: { in: [:m3, :m4] }) == :m4", .expected = .{ .boolean = true } },
        .{ .v = .{ .text = "7" }, .source = "r = param(:p, type: :number, default: 1)", .expected = .{ .num = 7 } },
    });
}

test "param: type: names the kind, and a default of another, or that no value is made of, is an error" {
    const held = "; a parameter's value is made of numbers, Strings, true or false, Symbols, Arrays and Maps";
    try support.expectScripts(&.{
        .{ .src = comptime support.rescued("param(:k, type: :vector)"), .expected = .{ .str = "ArgumentError: parameter :k's type: is :number, :string, :boolean, :symbol, :array or :map, got :vector" } },
        .{ .src = comptime support.rescued("param(:k, type: \"number\")"), .expected = .{ .str = "ArgumentError: parameter :k's type: is :number, :string, :boolean, :symbol, :array or :map, got \"number\"" } },
        .{ .src = comptime support.rescued("param(:k, type: :number, default: \"x\")"), .expected = .{ .str = "ArgumentError: parameter :k is a number by its type:, and its default is a String" } },
        .{ .src = comptime support.rescued("param(:k, type: :string, default: :x)"), .expected = .{ .str = "ArgumentError: parameter :k is a String by its type:, and its default is a Symbol" } },
        .{ .src = comptime support.rescued("param(:k, type: :array, default: 1)"), .expected = .{ .str = "ArgumentError: parameter :k is an Array by its type:, and its default is a number" } },
        .{ .src = comptime support.rescued("param(:k, type: :map)"), .expected = .{ .str = "ArgumentError: parameter :k's type: makes it a Map, with no fields: (nor a default to give them)" } },
        .{ .src = comptime support.rescued("param(:k, default: 1..3)"), .expected = .{ .str = "ArgumentError: parameter :k's default is a Range" ++ held } },
        .{ .src = comptime support.rescued("param(:k, default: [1, [cube(1)]])"), .expected = .{ .str = "ArgumentError: parameter :k's default holds a Solid" ++ held } },
        .{ .src = comptime support.rescued("param(:k, default: [1, nil])"), .expected = .{ .str = "ArgumentError: parameter :k's default holds nil: a parameter's value is made of numbers, Strings, true or false and Symbols" } },
        .{ .src = "r = param(:k, type: :number, default: 2)", .expected = .{ .num = 2 } },
    });
}

test "param: a declaration's rules are refused where they can't be" {
    const takes = "(it takes min:, max:, in:, items:, tuple:, fields:, min_items:, max_items:";
    const cases = [_]struct { src: []const u8, message: []const u8 }{
        .{ .src = "param(:k, default: [[[1]]])", .message = "parameter :k's default nests deeper than a list of tuples or of Maps" },
        .{ .src = "param(:k, default: [1, \"a\"])", .message = "parameter :k's default holds elements unlike each other ([0] and [1]): give its rules, validate: { items: ... } or { tuple: [...] }" },
        .{ .src = "param(:k, default: [[1, 2], [3]])", .message = "parameter :k's default holds elements unlike each other ([0] and [1]): give its rules, validate: { items: ... } or { tuple: [...] }" },
        .{ .src = "param(:k, default: [{ a: 1 }, { b: 1 }])", .message = "parameter :k's default holds elements unlike each other ([0] and [1]): give its rules, validate: { items: ... } or { tuple: [...] }" },
        .{ .src = "param(:k, default: { a: [1] })", .message = "parameter :k's default holds an Array in its field :a: a Map's fields are numbers, Strings, true or false and Symbols" },
        .{ .src = "param(:k, default: 5, validate: { items: :number })", .message = "parameter :k's validate: is for an Array, and its default is a number" },
        .{ .src = "param(:k, default: [1], validate: { min: 0 })", .message = "parameter :k's validate: min: is for numbers, and it is an Array" },
        .{ .src = "param(:k, default: [1], validate: { in: [1] })", .message = "parameter :k's validate: in: is for numbers, Strings, true or false and Symbols, and it is an Array: give an element's choices in items:" },
        .{ .src = "param(:k, default: [1], validate: { items: :number, tuple: [:number] })", .message = "parameter :k's validate: has both items: and tuple: (a list's rules, or a tuple's)" },
        .{ .src = "param(:k, default: [[1, 2]], validate: { items: { items: { tuple: [:number] } } })", .message = "parameter :k's validate: items: items: nests deeper than a list of tuples or of Maps" },
        .{ .src = "param(:k, validate: { fields: { a: { fields: { b: :number } } } })", .message = "parameter :k's validate: fields: :a is a Map: a Map's fields are numbers, Strings, true or false and Symbols" },
        .{ .src = "param(:k, validate: { items: { fields: { a: { items: :number } } } })", .message = "parameter :k's validate: items: fields: :a nests deeper than a list of tuples or of Maps" },
        .{ .src = "param(:k, default: [1, 2], validate: { tuple: [:number, :number], min_items: 1 })", .message = "parameter :k's validate: counts a list's items, and it is a tuple of 2" },
        .{ .src = "param(:k, validate: { min_items: 3, max_items: 1, items: :number })", .message = "parameter :k's validate: min_items: 3 is above its max_items: 1" },
        .{ .src = "param(:k, validate: { min_items: -1, items: :number })", .message = "parameter :k's validate: min_items: is a whole number, 0 or more, got -1" },
        .{ .src = "param(:k, default: [1], validate: { colour: 1 })", .message = "parameter :k's validate: takes no colour: " ++ takes ++ ")" },
        .{ .src = "param(:k, default: [1], validate: { items: { type: :number, colour: 1 } })", .message = "parameter :k's validate: items: takes no colour: " ++ takes ++ ", type:, title:, unit:, step:)" },
        .{ .src = "param(:k, default: [1], validate: { items: :string })", .message = "parameter :k's validate: items: is for a String, and its default there is a number" },
        .{ .src = "param(:k, default: [1], validate: { items: { unit: 5 } })", .message = "parameter :k's validate: items: unit: is a String, got 5" },
        .{ .src = "param(:k, default: [\"a\"], validate: { items: { type: :string, unit: \"mm\" } })", .message = "parameter :k's validate: items: unit: is for numbers, and it is a String" },
        .{ .src = "param(:k, validate: { in: [1, \"a\"] })", .message = "parameter :k's validate: in: holds 1, which isn't a String" },
        .{ .src = "param(:k, default: [5], validate: { items: { type: :number, max: 3 } })", .message = "parameter :k's default doesn't meet its rules: :k[0] expects a number at most 3, got 5" },
        .{ .src = "param(:k, default: { a: 1 }, validate: { fields: { a: :number, b: :number } })", .message = "parameter :k's default doesn't meet its rules: :k[:b] expects a number, got nothing" },
    };
    for (cases) |case| {
        errdefer std.debug.print("{s}\n", .{case.src});
        var vm = try support.initVm();
        defer vm.deinit();
        try testing.expectEqual(.runtime_error, try support.runOn(&vm, case.src));
        const message = vm.last_error orelse "";
        try testing.expect(std.mem.startsWith(u8, message, "ArgumentError: "));
        try testing.expectEqualStrings(case.message, message["ArgumentError: ".len..]);
    }
}

test "param: a list takes a host's array of any length, each element as its rule says" {
    try support.expectScripts(&.{
        .{ .src = "r = param(:size, default: [10, 20, 30])", .expected = .{ .nums = &.{ 10, 20, 30 } } },
        .{ .src = "r = param(:none, default: [])", .expected = .{ .nums = &.{} } },
        // A copy: changing it leaves the default the next run reads
        .{ .src = "d = [1]\nxs = param(:xs, default: d)\nxs.push(2)\nr = d", .expected = .{ .nums = &.{1} } },
    });
    try expectTaken(&.{
        .{ .v = .{ .text = "[1, 2.5]" }, .source = "r = param(:p, default: [10, 20, 30])", .expected = .{ .nums = &.{ 1, 2.5 } } },
        .{ .v = .{ .array = &.{ .{ .number = 4 }, .{ .number = 5 } } }, .source = "r = param(:p, default: [1])", .expected = .{ .nums = &.{ 4, 5 } } },
        .{ .v = .{ .text = "[]" }, .source = "r = param(:p, default: [1], validate: { max_items: 3 })", .expected = .{ .nums = &.{} } },
        // A list of Symbols makes a host's strings Symbols
        .{ .v = .{ .text = "[\"m4\", \"m3\"]" }, .source = "r = param(:p, default: [:m3], validate: { items: { type: :symbol, in: [:m3, :m4] } }) == [:m4, :m3]", .expected = .{ .boolean = true } },
        .{ .v = .{ .text = "[\"a\", \"b\"]" }, .source = "r = param(:p, type: :array).inspect", .expected = .{ .str = "[\"a\", \"b\"]" } },
        .{ .v = .{ .text = "[5, 50]" }, .source = "r = param(:p, default: [1, 2], validate: { items: { type: :number, max: 100 }, min_items: 2 })", .expected = .{ .nums = &.{ 5, 50 } } },
    });
    try expectRefused(&.{
        .{ .v = .{ .text = "[1, \"x\"]" }, .source = "param(:p, default: [1, 2])", .message = "TypeError: parameter :p[1] expects a number, got \"x\"" },
        .{ .v = .{ .text = "[500]" }, .source = "param(:p, default: [1], validate: { items: { type: :number, max: 100 } })", .message = "ValueError: parameter :p[0] expects a number at most 100, got 500" },
        .{ .v = .{ .text = "[\"m5\"]" }, .source = "param(:p, default: [:m3], validate: { items: { in: [:m3, :m4] } })", .message = "ValueError: parameter :p[0] expects one of :m3, :m4, got :m5" },
        .{ .v = .{ .text = "[1]" }, .source = "param(:p, default: [1, 2], validate: { min_items: 2 })", .message = "ValueError: parameter :p expects at least 2 items, got 1" },
        .{ .v = .{ .text = "[1, 2, 3]" }, .source = "param(:p, default: [1], validate: { max_items: 2 })", .message = "ValueError: parameter :p expects at most 2 items, got 3" },
        .{ .v = .{ .text = "wide" }, .source = "param(:p, default: [1])", .message = "TypeError: parameter :p expects an Array (as JSON: [10, 20]), got \"wide\"" },
        .{ .v = .{ .text = "{\"a\": 1}" }, .source = "param(:p, default: [1])", .message = "TypeError: parameter :p expects an Array (as JSON: [10, 20]), got \"{\"a\": 1}\"" },
    });
}

test "param: a tuple takes as many as its places, each by its own rule; a list of them each so" {
    const point = "validate: { tuple: [{ type: :number, min: -50, max: 50, title: \"X\" }, { type: :number, min: 0, max: 200, title: \"Z\" }] }";
    try support.expectScripts(&.{
        .{ .src = "r = param(:pos, default: [0, 0], " ++ point ++ ")", .expected = .{ .nums = &.{ 0, 0 } } },
        .{ .src = "r = param(:pts, default: [[0, 0], [10, 0]]).flatten", .expected = .{ .nums = &.{ 0, 0, 10, 0 } } },
    });
    try expectTaken(&.{
        .{ .v = .{ .text = "[1, 2]" }, .source = "r = param(:p, default: [0, 0], " ++ point ++ ")", .expected = .{ .nums = &.{ 1, 2 } } },
        .{ .v = .{ .text = "[[1, 2], [3, 4], [5, 6]]" }, .source = "r = param(:p, default: [[0, 0], [10, 0]]).flatten", .expected = .{ .nums = &.{ 1, 2, 3, 4, 5, 6 } } },
        // Places of their own kinds, read as each says
        .{ .v = .{ .text = "[[1, \"b\"]]" }, .source = "r = param(:p, default: [[0, :a]])[0][1] == :b", .expected = .{ .boolean = true } },
    });
    try expectRefused(&.{
        .{ .v = .{ .text = "[1]" }, .source = "param(:p, default: [0, 0], " ++ point ++ ")", .message = "ValueError: parameter :p expects 2 items, got 1" },
        .{ .v = .{ .text = "[1, -5]" }, .source = "param(:p, default: [0, 0], " ++ point ++ ")", .message = "ValueError: parameter :p[1] expects a number at least 0, got -5" },
        .{ .v = .{ .text = "[[1, 2], [3, 250]]" }, .source = "param(:p, default: [[0, 0]], validate: { items: { tuple: [:number, { type: :number, max: 200 }] } })", .message = "ValueError: parameter :p[1][1] expects a number at most 200, got 250" },
        .{ .v = .{ .text = "[1]" }, .source = "param(:p, default: [[1, 2]])", .message = "TypeError: parameter :p[0] expects an Array, got 1" },
        .{ .v = .{ .text = "[[1]]" }, .source = "param(:p, default: [[1, 2]])", .message = "ValueError: parameter :p[0] expects 2 items, got 1" },
    });
}

test "param: a Map takes its fields, keyed by Symbols in its order; a list of them each so" {
    const cuts = "validate: { min_items: 1, items: { fields: { type: { type: :string, in: [\"slot\", \"hole\"] }, depth: { type: :number, min: 0.1, max: 50 } } } }";
    try support.expectScripts(&.{
        .{ .src = "r = param(:origin, default: { x: 0, y: 5 })[:y]", .expected = .{ .num = 5 } },
        // Keys written as Strings are Symbols, as its fields are named
        .{ .src = "r = param(:origin, default: { \"x\": 0 }).keys == [:x]", .expected = .{ .boolean = true } },
        .{ .src = "r = param(:cuts, default: [{ type: \"slot\", depth: 5 }], " ++ cuts ++ ")[0][:depth]", .expected = .{ .num = 5 } },
    });
    try expectTaken(&.{
        .{ .v = .{ .text = "{\"y\": 2, \"x\": 1}" }, .source = "r = param(:p, default: { x: 0, y: 0 }).inspect", .expected = .{ .str = "{x: 1, y: 2}" } },
        .{ .v = .{ .object = &.{ .{ .name = "x", .value = .{ .number = 3 } }, .{ .name = "y", .value = .{ .number = 4 } } } }, .source = "r = param(:p, default: { x: 0, y: 0 }).values", .expected = .{ .nums = &.{ 3, 4 } } },
        .{ .v = .{ .text = "[{\"type\": \"hole\", \"depth\": 2}]" }, .source = "r = param(:p, default: [{ type: \"slot\", depth: 5 }], " ++ cuts ++ ")[0].inspect", .expected = .{ .str = "{type: \"hole\", depth: 2}" } },
    });
    try expectRefused(&.{
        .{ .v = .{ .text = "[{\"type\": \"slot\", \"depth\": 0}]" }, .source = "param(:p, default: [{ type: \"slot\", depth: 5 }], " ++ cuts ++ ")", .message = "ValueError: parameter :p[0][:depth] expects a number at least 0.1, got 0" },
        .{ .v = .{ .text = "[{\"type\": \"slot\"}]" }, .source = "param(:p, default: [{ type: \"slot\", depth: 5 }], " ++ cuts ++ ")", .message = "TypeError: parameter :p[0][:depth] expects a number, got nothing" },
        .{ .v = .{ .text = "[{\"type\": \"pocket\", \"depth\": 1}]" }, .source = "param(:p, default: [{ type: \"slot\", depth: 5 }], " ++ cuts ++ ")", .message = "ValueError: parameter :p[0][:type] expects one of \"slot\", \"hole\", got \"pocket\"" },
        .{ .v = .{ .text = "{\"x\": 1, \"z\": 2}" }, .source = "param(:p, default: { x: 0 })", .message = "ValueError: parameter :p expects only its fields :x, got :z" },
        .{ .v = .{ .text = "[]" }, .source = "param(:p, default: [{ type: \"slot\", depth: 5 }], " ++ cuts ++ ")", .message = "ValueError: parameter :p expects at least 1 items, got 0" },
        .{ .v = .{ .text = "[1]" }, .source = "param(:p, default: { x: 0 })", .message = "TypeError: parameter :p expects a Map (as JSON: {\"x\": 1}), got \"[1]\"" },
    });
}
