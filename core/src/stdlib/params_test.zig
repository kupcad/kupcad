//! `param()` with values a host gives, injected as every host injects them (api.injectParams):
//! text read by the parameter's declared type, typed values checked against it.

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

test "param: text from the host is read as the type the parameter's default has" {
    // `-p` gives text: it used to have to be a number, whatever the parameter was.
    const cases = [_]struct { name: []const u8, text: []const u8, source: []const u8, expected: support.Expected }{
        .{ .name = "w", .text = "10.5", .source = "r = param(:w, default: 1)", .expected = .{ .num = 10.5 } },
        .{ .name = "on", .text = "true", .source = "r = param(:on, default: false)", .expected = .{ .boolean = true } },
        .{ .name = "on", .text = "0", .source = "r = param(:on, default: true)", .expected = .{ .boolean = false } },
        .{ .name = "label", .text = "Gear A", .source = "r = param(:label, default: \"x\")", .expected = .{ .str = "Gear A" } },
        .{ .name = "label", .text = "", .source = "r = param(:label, default: \"x\")", .expected = .{ .str = "" } },
        .{ .name = "size", .text = "m4", .source = "s = param(:size, default: :m3, validate: { in: [:m3, :m4] })\nr = s == :m4 && s.class == Symbol", .expected = .{ .boolean = true } },
        .{ .name = "on", .text = "1", .source = "r = param(:on, default: false)", .expected = .{ .boolean = true } },
        .{ .name = "on", .text = "false", .source = "r = param(:on, default: true)", .expected = .{ .boolean = false } },
        .{ .name = "w", .text = "-1000", .source = "r = param(:w, default: 1)", .expected = .{ .num = -1000 } },
        .{ .name = "w", .text = "10", .source = "r = param(:w, default: 15, validate: { min: 10, max: 20 })", .expected = .{ .num = 10 } },
        .{ .name = "w", .text = "20", .source = "r = param(:w, default: 15, validate: { min: 10, max: 20 })", .expected = .{ .num = 20 } },
    };
    for (cases) |case| {
        errdefer std.debug.print("{s}={s}: {s}\n", .{ case.name, case.text, case.source });
        var vm = try support.initVm();
        defer vm.deinit();
        try testing.expectEqual(.ok, try runWith(case.name, .{ .text = case.text }, case.source, &vm));
        try support.expectValue(case.expected, vm.globals.get("r").?);
    }
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
    });
}

test "param: a value the parameter can't take is an error naming it and what was given" {
    const cases = [_]struct { name: []const u8, v: api.ParamValue, source: []const u8, message: []const u8 }{
        .{ .name = "w", .v = .{ .text = "wide" }, .source = "param(:w, default: 1)", .message = "TypeError: parameter :w expects a number, got \"wide\"" },
        // A script's numbers are finite: parseFloat would read these
        .{ .name = "w", .v = .{ .text = "inf" }, .source = "param(:w, default: 1)", .message = "TypeError: parameter :w expects a number, got \"inf\"" },
        .{ .name = "w", .v = .{ .text = "nan" }, .source = "param(:w, default: 1)", .message = "TypeError: parameter :w expects a number, got \"nan\"" },
        .{ .name = "w", .v = .{ .boolean = true }, .source = "param(:w, default: 1)", .message = "TypeError: parameter :w expects a number, got Boolean" },
        .{ .name = "on", .v = .{ .text = "yes" }, .source = "param(:on, default: false)", .message = "TypeError: parameter :on expects true or false, got \"yes\"" },
        .{ .name = "label", .v = .{ .number = 5 }, .source = "param(:label, default: \"x\")", .message = "TypeError: parameter :label expects a String, got Number" },
        .{ .name = "size", .v = .{ .text = "m5" }, .source = "param(:size, default: :m3, validate: { in: [:m3, :m4] })", .message = "ValueError: parameter :size value is not one of its allowed choices" },
        .{ .name = "w", .v = .{ .text = "200" }, .source = "param(:w, default: 1, validate: { max: 100 })", .message = "ValueError: parameter :w value 200 is above its maximum 100" },
        .{ .name = "w", .v = .{ .number = 5 }, .source = "param(:w, default: 15, validate: { min: 10, max: 20 })", .message = "ValueError: parameter :w value 5 is below its minimum 10" },
        .{ .name = "on", .v = .{ .number = 42 }, .source = "param(:on, default: false)", .message = "TypeError: parameter :on expects true or false, got Number" },
        .{ .name = "size", .v = .{ .text = "M3" }, .source = "param(:size, default: :m3, validate: { in: [:m3, :m4] })", .message = "ValueError: parameter :size value is not one of its allowed choices" },
    };
    for (cases) |case| {
        errdefer std.debug.print("{s}: {s}\n", .{ case.name, case.source });
        var vm = try support.initVm();
        defer vm.deinit();
        try testing.expectEqual(.runtime_error, try runWith(case.name, case.v, case.source, &vm));
        try testing.expectEqualStrings(case.message, vm.last_error orelse "");
    }
}

test "param: step, unit, group, title and description are a host's hints, checked but not applied to the value" {
    try support.expectScripts(&.{
        .{ .src = "r = param(:w, default: 10, step: 0.5, unit: \"mm\", group: \"Size\")", .expected = .{ .num = 10 } },
        .{ .src = "r = param(:label, default: \"A\", group: :Text)", .expected = .{ .str = "A" } },
        .{ .src = "r = param(:w, default: 10, title: \"Width\", description: \"Across the plate\")", .expected = .{ .num = 10 } },
        .{ .src = comptime support.rescued("param(:w, default: 1, title: 5)"), .expected = .{ .str = "TypeError: param expects a String or Symbol for title, got Number" } },
        .{ .src = comptime support.rescued("param(:w, default: 1, step: 0)"), .expected = .{ .str = "ValueError: parameter :w step must be a number greater than 0, got 0" } },
        .{ .src = comptime support.rescued("param(:label, default: \"A\", step: 1)"), .expected = .{ .str = "ArgumentError: parameter :label is a string, and step: is for numbers" } },
        .{ .src = comptime support.rescued("param(:on, default: true, unit: \"mm\")"), .expected = .{ .str = "ArgumentError: parameter :on is a boolean, and unit: is for numbers" } },
        .{ .src = "r = param(:size, default: [10, 20], unit: \"mm\", step: 0.5)[1]", .expected = .{ .num = 20 } },
        .{ .src = comptime support.rescued("param(:w, default: 1, step: \"x\")"), .expected = .{ .str = "TypeError: param expects a number for step, got String" } },
        .{ .src = comptime support.rescued("param(:w, default: 1, colour: \"x\")"), .expected = .{ .str = "ArgumentError: param does not take a keyword 'colour' (it accepts: default, type, validate, step, unit, group, title, description)" } },
    });
    // A value off the step is the host's to give: -p 10.3 with step: 0.5 stays 10.3
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try runWith("w", .{ .text = "10.3" }, "r = param(:w, default: 10, step: 0.5)", &vm));
    try support.expectValue(.{ .num = 10.3 }, vm.globals.get("r").?);
}

test "param: one with no default is nil until a host gives it a value, a String unless typed" {
    // It was a number by a default it didn't have, and refused its own nil
    try support.expectScripts(&.{
        .{ .src = "r = param(:key, title: \"Key\")", .expected = .nil },
        .{ .src = "r = param(:key, default: nil)", .expected = .nil },
        .{ .src = "r = param(:key, type: :number)", .expected = .nil },
        // Nil is no value to check
        .{ .src = "r = param(:key, type: :number, validate: { min: 1, in: [2, 3] })", .expected = .nil },
    });
    const cases = [_]struct { text: []const u8, source: []const u8, expected: support.Expected }{
        .{ .text = "5", .source = "r = param(:key, title: \"Key\")", .expected = .{ .str = "5" } },
        .{ .text = "5", .source = "r = param(:key, default: nil)", .expected = .{ .str = "5" } },
        .{ .text = "5", .source = "r = param(:key, type: :number)", .expected = .{ .num = 5 } },
        .{ .text = "true", .source = "r = param(:key, type: :boolean)", .expected = .{ .boolean = true } },
        .{ .text = "m4", .source = "r = param(:key, type: :symbol) == :m4", .expected = .{ .boolean = true } },
        // Of choices all Symbols, it is a Symbol, or no value could be one of them
        .{ .text = "m4", .source = "r = param(:key, validate: { in: [:m3, :m4] }) == :m4", .expected = .{ .boolean = true } },
        .{ .text = "7", .source = "r = param(:key, type: :number, default: 1)", .expected = .{ .num = 7 } },
    };
    for (cases) |case| {
        errdefer std.debug.print("key={s}: {s}\n", .{ case.text, case.source });
        var vm = try support.initVm();
        defer vm.deinit();
        try testing.expectEqual(.ok, try runWith("key", .{ .text = case.text }, case.source, &vm));
        try support.expectValue(case.expected, vm.globals.get("r").?);
    }
}

test "param: type: names the type, and a default of another, or that no parameter holds, is an error" {
    const takes = "; a parameter's default is a number, a String, true or false, a Symbol, an Array of them, or nil";
    try support.expectScripts(&.{
        .{ .src = comptime support.rescued("param(:k, type: :vector)"), .expected = .{ .str = "ArgumentError: parameter :k type: is :number, :string, :boolean, :symbol or :array, got :vector" } },
        .{ .src = comptime support.rescued("param(:k, type: \"number\")"), .expected = .{ .str = "ArgumentError: parameter :k type: is :number, :string, :boolean, :symbol or :array, got a String" } },
        .{ .src = comptime support.rescued("param(:k, type: :number, default: \"x\")"), .expected = .{ .str = "ArgumentError: parameter :k is a number by its type:, and its default is a string" } },
        .{ .src = comptime support.rescued("param(:k, type: :string, default: :x)"), .expected = .{ .str = "ArgumentError: parameter :k is a string by its type:, and its default is a symbol" } },
        .{ .src = comptime support.rescued("param(:k, type: :array, default: 1)"), .expected = .{ .str = "ArgumentError: parameter :k is an array by its type:, and its default is a number" } },
        .{ .src = comptime support.rescued("param(:k, default: { a: 1 })"), .expected = .{ .str = "ArgumentError: parameter :k's default is a Map" ++ takes } },
        .{ .src = comptime support.rescued("param(:k, default: 1..3)"), .expected = .{ .str = "ArgumentError: parameter :k's default is a Range" ++ takes } },
        .{ .src = comptime support.rescued("param(:k, default: [1, [cube(1)]])"), .expected = .{ .str = "ArgumentError: parameter :k's default holds a Solid" ++ takes } },
        .{ .src = comptime support.rescued("param(:k, default: [1, nil])"), .expected = .{ .str = "ArgumentError: parameter :k's default holds nil" ++ takes } },
        .{ .src = "r = param(:k, type: :number, default: 2)", .expected = .{ .num = 2 } },
    });
}

test "param: an Array parameter's value is its default's, or a host's array, or -p text read as JSON" {
    try support.expectScripts(&.{
        .{ .src = "r = param(:size, default: [10, 20, 30])", .expected = .{ .nums = &.{ 10, 20, 30 } } },
        .{ .src = "r = param(:pts, default: [[0, 0], [10, 5]]).flatten", .expected = .{ .nums = &.{ 0, 0, 10, 5 } } },
        .{ .src = "r = param(:none, default: [])", .expected = .{ .nums = &.{} } },
        .{ .src = "r = param(:xs, type: :array)", .expected = .nil },
        // A copy: changing it leaves the default the next run reads
        .{ .src = "d = [1]\nxs = param(:xs, default: d)\nxs.push(2)\nr = d", .expected = .{ .nums = &.{1} } },
    });
    const cases = [_]struct { v: api.ParamValue, source: []const u8, expected: support.Expected }{
        .{ .v = .{ .text = "[1, 2.5]" }, .source = "r = param(:xs, default: [10, 20, 30])", .expected = .{ .nums = &.{ 1, 2.5 } } },
        .{ .v = .{ .text = "[[1, 2], [3, 4]]" }, .source = "r = param(:xs, default: [[0, 0]]).flatten", .expected = .{ .nums = &.{ 1, 2, 3, 4 } } },
        .{ .v = .{ .array = &.{ .{ .number = 4 }, .{ .number = 5 } } }, .source = "r = param(:xs, default: [1])", .expected = .{ .nums = &.{ 4, 5 } } },
        // The default's Symbols make a host's strings Symbols, as a Symbol parameter's
        .{ .v = .{ .text = "[\"m4\", \"m3\"]" }, .source = "r = param(:xs, default: [:m3], validate: { in: [:m3, :m4] }) == [:m4, :m3]", .expected = .{ .boolean = true } },
        // Of no one kind, any a parameter holds
        .{ .v = .{ .text = "[1, \"a\", true, [2]]" }, .source = "r = param(:xs, default: [1, \"b\"]).inspect", .expected = .{ .str = "[1, \"a\", true, [2]]" } },
        .{ .v = .{ .text = "[1, \"a\"]" }, .source = "r = param(:xs, type: :array).inspect", .expected = .{ .str = "[1, \"a\"]" } },
        .{ .v = .{ .text = "[[5, 50]]" }, .source = "r = param(:xs, default: [[1]], validate: { max: 100 }).inspect", .expected = .{ .str = "[[5, 50]]" } },
    };
    for (cases) |case| {
        errdefer std.debug.print("{s}\n", .{case.source});
        var vm = try support.initVm();
        defer vm.deinit();
        const result = try runWith("xs", case.v, case.source, &vm);
        if (result != .ok) std.debug.print("{s}\n", .{vm.last_error orelse ""});
        try testing.expectEqual(.ok, result);
        try support.expectValue(case.expected, vm.globals.get("r").?);
    }
}

test "param: an Array parameter refuses a value naming the element it can't take" {
    const cases = [_]struct { text: []const u8, source: []const u8, message: []const u8 }{
        .{ .text = "[1, \"x\"]", .source = "param(:xs, default: [1, 2])", .message = "TypeError: parameter :xs[1] expects a number, got \"x\"" },
        .{ .text = "[500]", .source = "param(:xs, default: [1], validate: { max: 100 })", .message = "ValueError: parameter :xs[0] value 500 is above its maximum 100" },
        .{ .text = "[[1, 500]]", .source = "param(:xs, default: [[1, 2]], validate: { max: 100 })", .message = "ValueError: parameter :xs[0] value 500 is above its maximum 100" },
        .{ .text = "[1]", .source = "param(:xs, default: [[1, 2]])", .message = "TypeError: parameter :xs[0] expects an Array, got Number" },
        .{ .text = "[\"m5\"]", .source = "param(:xs, default: [:m3], validate: { in: [:m3, :m4] })", .message = "ValueError: parameter :xs[0] is not one of its allowed choices" },
        .{ .text = "wide", .source = "param(:xs, default: [1])", .message = "TypeError: parameter :xs expects an Array (as JSON: [10, 20]), got \"wide\"" },
        .{ .text = "{\"a\": 1}", .source = "param(:xs, default: [1])", .message = "TypeError: parameter :xs expects an Array (as JSON: [10, 20]), got \"{\"a\": 1}\"" },
        .{ .text = "[{\"a\": 1}]", .source = "param(:xs, type: :array)", .message = "TypeError: parameter :xs expects an Array of numbers, strings, true or false, and arrays of them, got \"[{\"a\": 1}]\"" },
    };
    for (cases) |case| {
        errdefer std.debug.print("xs={s}: {s}\n", .{ case.text, case.source });
        var vm = try support.initVm();
        defer vm.deinit();
        try testing.expectEqual(.runtime_error, try runWith("xs", .{ .text = case.text }, case.source, &vm));
        try testing.expectEqualStrings(case.message, vm.last_error orelse "");
        // The run's report names the parameter, for a host's control to mark
        try testing.expectEqualStrings("xs", vm.report.refused_param orelse "");
    }
}
