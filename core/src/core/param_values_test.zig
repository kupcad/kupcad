const std = @import("std");
const testing = std.testing;
const param_values = @import("param_values.zig");
const ParamValues = param_values.ParamValues;
const ParamValue = param_values.ParamValue;

fn expectValue(expected: ParamValue, values: *const ParamValues, name: []const u8) !void {
    errdefer std.debug.print("parameter: {s}\n", .{name});
    const got = values.map.get(name) orelse return error.MissingParameter;
    switch (expected) {
        .number => |n| try testing.expectEqual(n, got.number),
        .boolean => |b| try testing.expectEqual(b, got.boolean),
        .text => |t| try testing.expectEqualStrings(t, got.text),
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
    // An Array or an object is data, for import_json, not a parameter.
    const cases = [_]struct { json: []const u8, why: []const u8 }{
        .{ .json = "{\"gears\": [1, 2]}", .why = "parameter 'gears' is an array; a parameter takes a number, a string, true or false" },
        .{ .json = "{\"frame\": {\"w\": 1}}", .why = "parameter 'frame' is an object; a parameter takes a number, a string, true or false" },
        .{ .json = "{\"w\": null}", .why = "parameter 'w' is null; a parameter takes a number, a string, true or false" },
        .{ .json = "{\"w\": 1e400}", .why = "parameter 'w' is a number past the largest (1.8e308); a parameter takes a number, a string, true or false" },
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
    try testing.expectError(error.InvalidParams, values.putJson(testing.allocator, "{\"a\": \"text\", \"b\": [1]}", &why));
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
