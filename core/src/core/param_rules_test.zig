const std = @import("std");
const testing = std.testing;
const rules = @import("param_rules.zig");
const Literal = rules.Literal;

/// The rules `declaration` builds, in `arena`.
fn built(arena: std.mem.Allocator, declaration: rules.Declaration) !rules.Built {
    var why: []const u8 = "";
    return rules.build(arena, declaration, &why) catch |err| {
        std.debug.print("{s}\n", .{why});
        return err;
    };
}

test "param rules: a default implies a list, a list of tuples, a list of Maps, a Map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const list = (try built(a, .{ .name = "xs", .default = .{ .array = &.{ .{ .number = 1 }, .{ .number = 2 } } } })).rule;
    try testing.expectEqual(.array, list.kind);
    try testing.expectEqual(.number, list.items.?.kind);
    try testing.expect(list.tuple == null);

    const points = (try built(a, .{ .name = "pts", .default = .{ .array = &.{.{ .array = &.{ .{ .number = 0 }, .{ .symbol = "a" } } }} } })).rule;
    const point = points.items.?.tuple.?;
    try testing.expectEqual(.number, point[0].kind);
    try testing.expectEqual(.symbol, point[1].kind);

    const origin = (try built(a, .{ .name = "o", .default = .{ .map = &.{ .{ .key = "x", .value = .{ .number = 0 } }, .{ .key = "label", .value = .{ .string = "A" } } } } })).rule;
    try testing.expectEqualStrings("x", origin.fields.?[0].name);
    try testing.expectEqual(.string, origin.fields.?[1].rule.kind);
}

test "param rules: a parameter's unit and step go to every number in it without its own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const validate: Literal = .{ .map = &.{.{ .key = "tuple", .value = .{ .array = &.{
        .{ .symbol = "number" },
        .{ .map = &.{ .{ .key = "type", .value = .{ .symbol = "number" } }, .{ .key = "unit", .value = .{ .string = "deg" } } } },
        .{ .symbol = "string" },
    } } }} };
    const rule = (try built(a, .{ .name = "pose", .type = .{ .symbol = "array" }, .validate = validate, .unit = "mm", .step = 0.5 })).rule;
    const places = rule.tuple.?;
    try testing.expectEqualStrings("mm", places[0].unit.?);
    try testing.expectEqual(@as(f64, 0.5), places[0].step.?);
    try testing.expectEqualStrings("deg", places[1].unit.?);
    try testing.expect(places[2].unit == null);
}

test "param rules: a value is read as its rules say, its path named where it is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]rules.Rule.Field{
        .{ .name = "type", .rule = .{ .kind = .symbol } },
        .{ .name = "depth", .rule = .{ .kind = .number, .max = 50 } },
    };
    const cut: rules.Rule = .{ .kind = .map, .fields = &fields };
    const cuts: rules.Rule = .{ .kind = .array, .items = &cut, .max_items = 2 };

    // JSON text, as -p gives it: the keys put in the fields' order, Strings made Symbols
    var refusal: rules.Refusal = undefined;
    const read = try rules.check(a, cuts, .{ .string = "[{\"depth\": 5, \"type\": \"slot\"}]" }, &refusal);
    const first = read.array[0].map;
    try testing.expectEqualStrings("type", first[0].key);
    try testing.expectEqualStrings("slot", first[0].value.symbol);
    try testing.expectEqual(@as(f64, 5), first[1].value.number);

    try testing.expectError(error.Refused, rules.check(a, cuts, .{ .string = "[{\"type\": \"a\", \"depth\": 5}, {\"type\": \"b\", \"depth\": 60}]" }, &refusal));
    try testing.expectEqual(@as(usize, 1), refusal.path[0].index);
    try testing.expectEqualStrings("depth", refusal.path[1].field);
    try testing.expectEqualStrings("a number at most 50", refusal.expected);
    try testing.expectEqualStrings("60", refusal.got);
    try testing.expect(!refusal.wrong_kind);
    var place: std.Io.Writer.Allocating = .init(a);
    try place.writer.print("{f}", .{rules.Place{ .name = "cuts", .path = refusal.path }});
    try testing.expectEqualStrings(":cuts[1][:depth]", place.written());

    // Text read as JSON at the top only: an element of a list is no text to read
    try testing.expectError(error.Refused, rules.check(a, cuts, .{ .array = &.{.{ .string = "{\"type\": \"a\"}" }} }, &refusal));
    try testing.expect(refusal.wrong_kind);
    try testing.expectEqualStrings("a Map", refusal.expected);
}

test "param rules: written as the schema has them, each part's rules nested" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const point: rules.Rule = .{ .kind = .array, .tuple = &.{ .{ .kind = .number, .title = "X" }, .{ .kind = .symbol, .choices = &.{.{ .symbol = "a" }} } } };
    const rule: rules.Rule = .{ .kind = .array, .items = &point, .min_items = 1 };
    const json = try std.json.Stringify.valueAlloc(arena.allocator(), rule, .{});
    const nothing = "\"in\":null,\"items\":null,\"tuple\":null,\"fields\":null,\"min_items\":null,\"max_items\":null";
    try testing.expectEqualStrings(
        "{\"type\":\"array\",\"min\":null,\"max\":null,\"in\":null,\"items\":" ++
            "{\"type\":\"array\",\"min\":null,\"max\":null,\"in\":null,\"items\":null,\"tuple\":[" ++
            "{\"type\":\"number\",\"min\":null,\"max\":null," ++ nothing ++ ",\"title\":\"X\",\"unit\":null,\"step\":null}," ++
            // A Symbol is a "string" with choices, its choices their text
            "{\"type\":\"string\",\"min\":null,\"max\":null,\"in\":[\"a\"],\"items\":null,\"tuple\":null,\"fields\":null,\"min_items\":null,\"max_items\":null,\"title\":null,\"unit\":null,\"step\":null}" ++
            "],\"fields\":null,\"min_items\":null,\"max_items\":null,\"title\":null,\"unit\":null,\"step\":null}," ++
            "\"tuple\":null,\"fields\":null,\"min_items\":1,\"max_items\":null,\"title\":null,\"unit\":null,\"step\":null}",
        json,
    );
}

test "param rules: JSON nested past the deepest a Literal holds is none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (0..rules.MAX_LITERAL_DEPTH + 1) |_| try text.append(a, '[');
    for (0..rules.MAX_LITERAL_DEPTH + 1) |_| try text.append(a, ']');
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, text.items, .{});
    try testing.expect(try Literal.ofJson(a, parsed) == null);
    try testing.expect(try Literal.ofJson(a, .{ .number_string = "1e400" }) == null);
}
