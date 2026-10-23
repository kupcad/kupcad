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
