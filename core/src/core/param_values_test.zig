const std = @import("std");
const testing = std.testing;
const param_values = @import("param_values.zig");
const ParamValues = param_values.ParamValues;
const ParamValue = param_values.ParamValue;

fn expectValue(expected: ParamValue, values: *const ParamValues, name: []const u8) !void {
    errdefer std.debug.print("parameter: {s}\n", .{name});
    try expectParamValue(expected, values.map.get(name) orelse return error.MissingParameter);
}

fn expectParamValue(expected: ParamValue, got: ParamValue) !void {
    switch (expected) {
        .number => |n| try testing.expectEqual(n, got.number),
        .boolean => |b| try testing.expectEqual(b, got.boolean),
        .text => |t| try testing.expectEqualStrings(t, got.text),
        .array => |items| {
            try testing.expectEqual(items.len, got.array.len);
            for (items, got.array) |item, element| try expectParamValue(item, element);
        },
        .object => |fields| {
            try testing.expectEqual(fields.len, got.object.len);
            for (fields, got.object) |field, given| {
                try testing.expectEqualStrings(field.name, given.name);
                try expectParamValue(field.value, given.value);
            }
        },
    }
}

test "ParamValues: put copies the name and the text, and a later value replaces the earlier" {
    var values: ParamValues = .{};
    defer values.deinit(testing.allocator);
    var name = "width".*;
    var text = "40".*;
    try values.put(testing.allocator, &name, .{ .text = &text });
    // The caller's buffers can change: the values hold their own copies
    name[0] = 'x';
    text[0] = '9';
    try expectValue(.{ .text = "40" }, &values, "width");
    try values.put(testing.allocator, "width", .{ .number = 50 });
    try values.put(testing.allocator, "label", .{ .text = "A" });
    try values.put(testing.allocator, "label", .{ .text = "B" });
    try expectValue(.{ .number = 50 }, &values, "width");
    try expectValue(.{ .text = "B" }, &values, "label");
    try testing.expectEqual(@as(usize, 2), values.map.count());
}

test "ParamValues: a JSON object gives numbers, strings and booleans, in its order" {
    var values: ParamValues = .{};
    defer values.deinit(testing.allocator);
    try values.put(testing.allocator, "width", .{ .number = 1 });
    var why: ?[]u8 = null;
    try values.putJson(testing.allocator,
        \\{"width": 40, "height": 2.5, "label": "Gear A", "hollow": true, "size": "m4", "big": 123456789012345678901234567890}
    , &why);
    try testing.expect(why == null);
    try expectValue(.{ .number = 40 }, &values, "width");
    try expectValue(.{ .number = 2.5 }, &values, "height");
    try expectValue(.{ .text = "Gear A" }, &values, "label");
    try expectValue(.{ .boolean = true }, &values, "hollow");
    try expectValue(.{ .text = "m4" }, &values, "size");
    try expectValue(.{ .number = 1.2345678901234568e29 }, &values, "big");
    const order = [_][]const u8{ "width", "height", "label", "hollow", "size", "big" };
    for (order, values.map.keys()) |want, got| try testing.expectEqualStrings(want, got);
}

test "ParamValues: a file that isn't one object of parameter values is refused, saying why" {
    // Values nested past a list of objects are data, for import_json, not a parameter's
    const cases = [_]struct { json: []const u8, why: []const u8 }{
        .{ .json = "{\"gears\": [1, null]}", .why = "parameter 'gears' holds null; a parameter takes numbers, strings, true or false, and arrays and objects of them, two deep at most" },
        .{ .json = "{\"gears\": [[[20]]]}", .why = "parameter 'gears' holds values nested too deep; a parameter takes numbers, strings, true or false, and arrays and objects of them, two deep at most" },
        .{ .json = "{\"frame\": {\"w\": [[1]]}}", .why = "parameter 'frame' holds values nested too deep; a parameter takes numbers, strings, true or false, and arrays and objects of them, two deep at most" },
        .{ .json = "{\"w\": 1e400}", .why = "parameter 'w' is a number past the largest (1.8e308); a parameter takes numbers, strings, true or false, and arrays and objects of them, two deep at most" },
        .{ .json = "[1, 2]", .why = "a parameter file holds one JSON object of names and values, as {\"width\": 40}" },
        .{ .json = "40", .why = "a parameter file holds one JSON object of names and values, as {\"width\": 40}" },
        .{ .json = "{\"w\": 1,\n \"h\" 2}", .why = "line 2, column 6: invalid JSON" },
        // Found once the second value is read: the column after it
        .{ .json = "{\"w\": 1, \"w\": 2}", .why = "line 1, column 16: a key is written twice" },
        .{ .json = "", .why = "line 1, column 1: invalid JSON" },
    };
    for (cases) |case| {
        errdefer std.debug.print("json: {s}\n", .{case.json});
        var values: ParamValues = .{};
        defer values.deinit(testing.allocator);
        var why: ?[]u8 = null;
        defer if (why) |w| testing.allocator.free(w);
        try testing.expectError(error.InvalidParams, values.putJson(testing.allocator, case.json, &why));
        try testing.expectEqualStrings(case.why, why orelse return error.NoReason);
    }
}

test "ParamValues: refusing a file frees what it had set" {
    // The values before the refusal are freed with the rest (the testing allocator checks)
    var values: ParamValues = .{};
    defer values.deinit(testing.allocator);
    var why: ?[]u8 = null;
    defer if (why) |w| testing.allocator.free(w);
    try testing.expectError(error.InvalidParams, values.putJson(testing.allocator, "{\"a\": \"text\", \"b\": [\"set\", [[1]]]}", &why));
}

test "ParamValues: written as JSON, they read back the same, in their order" {
    var values: ParamValues = .{};
    defer values.deinit(testing.allocator);
    try values.put(testing.allocator, "width", .{ .number = 12.5 });
    try values.put(testing.allocator, "hollow", .{ .boolean = true });
    try values.put(testing.allocator, "material", .{ .text = "PETG \"pro\"" });
    const text = try std.json.Stringify.valueAlloc(testing.allocator, values, .{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{\"width\":12.5,\"hollow\":true,\"material\":\"PETG \\\"pro\\\"\"}", text);

    var back: ParamValues = .{};
    defer back.deinit(testing.allocator);
    var why: ?[]u8 = null;
    try back.putJson(testing.allocator, text, &why);
    try testing.expectEqual(values.map.count(), back.map.count());
    for (values.map.keys(), back.map.keys()) |a, b| try testing.expectEqualStrings(a, b);
    try testing.expectEqualStrings("PETG \"pro\"", back.map.get("material").?.text);
}

test "ParamValues: a copy is equal, and a value, a name or the order changed isn't" {
    var values: ParamValues = .{};
    defer values.deinit(testing.allocator);
    try values.put(testing.allocator, "width", .{ .number = 12.5 });
    try values.put(testing.allocator, "label", .{ .text = "A" });
    var copy = try values.clone(testing.allocator);
    defer copy.deinit(testing.allocator);
    try testing.expect(copy.eql(values));
    try testing.expect(values.map.get("label").?.text.ptr != copy.map.get("label").?.text.ptr);
    try testing.expect(!values.eql(.{}));

    try copy.put(testing.allocator, "label", .{ .text = "B" });
    try testing.expect(!copy.eql(values));
    try copy.put(testing.allocator, "label", .{ .boolean = true });
    try testing.expect(!copy.eql(values));

    var reordered: ParamValues = .{};
    defer reordered.deinit(testing.allocator);
    try reordered.put(testing.allocator, "label", .{ .text = "A" });
    try reordered.put(testing.allocator, "width", .{ .number = 12.5 });
    try testing.expect(!reordered.eql(values));
}

test "ParamValues: a parsed JSON object gives its values, and refuses one no parameter takes" {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"width\": 40, \"label\": \"A\", \"holes\": [[[1]]]}", .{});
    var values: ParamValues = .{};
    defer values.deinit(testing.allocator);
    var why: ?[]u8 = null;
    defer if (why) |w| testing.allocator.free(w);
    try testing.expectError(error.InvalidParams, values.putObject(testing.allocator, parsed.value.object, &why));
    try testing.expectEqualStrings("parameter 'holes' holds values nested too deep; a parameter takes numbers, strings, true or false, and arrays and objects of them, two deep at most", why.?);
    // Its strings are copies: the parse goes, the values stay
    parsed.deinit();
    try expectValue(.{ .text = "A" }, &values, "label");
    try expectValue(.{ .number = 40 }, &values, "width");
}

test "ParamValues: arrays and objects give Array and Map parameters their values, two deep" {
    var values: ParamValues = .{};
    defer values.deinit(testing.allocator);
    var why: ?[]u8 = null;
    defer if (why) |w| testing.allocator.free(w);
    try values.putJson(testing.allocator, "{\"size\": [10, 20.5], \"holes\": [[0, 0], [10, \"x\", true]], \"none\": [], \"cuts\": [{\"type\": \"slot\", \"depth\": 5}], \"origin\": {\"x\": 1}}", &why);
    try expectValue(.{ .array = &.{ .{ .number = 10 }, .{ .number = 20.5 } } }, &values, "size");
    try expectValue(.{ .array = &.{
        .{ .array = &.{ .{ .number = 0 }, .{ .number = 0 } } },
        .{ .array = &.{ .{ .number = 10 }, .{ .text = "x" }, .{ .boolean = true } } },
    } }, &values, "holes");
    try expectValue(.{ .array = &.{} }, &values, "none");
    try expectValue(.{ .array = &.{.{ .object = &.{ .{ .name = "type", .value = .{ .text = "slot" } }, .{ .name = "depth", .value = .{ .number = 5 } } } }} }, &values, "cuts");
    try expectValue(.{ .object = &.{.{ .name = "x", .value = .{ .number = 1 } }} }, &values, "origin");

    // Written out and read back, copied: the same values
    const json = try std.json.Stringify.valueAlloc(testing.allocator, values, .{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"size\":[10,20.5],\"holes\":[[0,0],[10,\"x\",true]],\"none\":[],\"cuts\":[{\"type\":\"slot\",\"depth\":5}],\"origin\":{\"x\":1}}", json);
    var back: ParamValues = .{};
    defer back.deinit(testing.allocator);
    try back.putJson(testing.allocator, json, &why);
    try testing.expect(back.eql(values));
    var copy = try values.clone(testing.allocator);
    defer copy.deinit(testing.allocator);
    try testing.expect(copy.eql(values));
    try copy.put(testing.allocator, "size", .{ .array = &.{.{ .number = 10 }} });
    try testing.expect(!copy.eql(values));
}

test "ParamValues: null gives a parameter no value, dropping one given before" {
    var values: ParamValues = .{};
    defer values.deinit(testing.allocator);
    try values.put(testing.allocator, "width", .{ .number = 5 });
    try values.put(testing.allocator, "label", .{ .text = "A" });
    var why: ?[]u8 = null;
    try values.putJson(testing.allocator, "{\"width\": null, \"depth\": null}", &why);
    try testing.expect(why == null);
    try testing.expectEqual(1, values.map.count());
    try expectValue(.{ .text = "A" }, &values, "label");
}
