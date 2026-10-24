//! The preview frame of a script, as api.previewScript makes it: read back as a front end
//! reads it (frame.split, then its JSON header strictly).

const std = @import("std");
const testing = std.testing;
const api = @import("../api.zig");
const frame = @import("frame.zig");
const ParamValues = @import("../core/param_values.zig").ParamValues;

/// The header as a front end's types read it: a field renamed or added fails.
const Header = struct {
    protocolVersion: u32,
    kind: []const u8,
    parts: []const struct { name: []const u8, count: u32, nodes: []const []const u8, color: ?[]const u8, opacity: f64 },
    warnings: []const struct { message: []const u8, line: ?u32, column: ?u32 },
    params: struct { schema: std.json.Value, values: std.json.Value },
    @"error": ?struct { message: []const u8, line: ?u32, column: ?u32, param: ?[]const u8 },
    timing: struct { runMs: f64, renderMs: f64 },
};

/// A frame read back: its header, and its body, both owned by the arena.
const Read = struct { header: Header, body: []const u8 };

/// The frame of `source` with `params` (a JSON object, or empty), read back into `arena`.
fn preview(arena: std.mem.Allocator, source: []const u8, params: []const u8) !Read {
    var values: ParamValues = .{};
    defer values.deinit(testing.allocator);
    var why: ?[]u8 = null;
    if (params.len > 0) try values.putJson(testing.allocator, params, &why);
    const bytes = try api.previewScript(testing.allocator, testing.io, source, .{ .params = &values });
    defer testing.allocator.free(bytes);
    const parts = try frame.split(bytes);
    return .{
        .header = try std.json.parseFromSliceLeaky(Header, arena, try arena.dupe(u8, parts.header), .{ .allocate = .alloc_always }),
        .body = try arena.dupe(u8, parts.body),
    };
}

/// The names of the nodes of a GLB: its JSON chunk's `nodes`, the named ones.
fn glbNodeNames(arena: std.mem.Allocator, glb: []const u8) ![]const []const u8 {
    try testing.expectEqualStrings("glTF", glb[0..4]);
    const json_len = std.mem.readInt(u32, glb[12..16], .little);
    try testing.expectEqualStrings("JSON", glb[16..20]);
    const Gltf = struct { nodes: []const struct { name: ?[]const u8 = null } };
    const gltf = try std.json.parseFromSliceLeaky(Gltf, arena, glb[20..][0..json_len], .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    var names: std.ArrayList([]const u8) = .empty;
    for (gltf.nodes) |node| if (node.name) |name| try names.append(arena, name);
    return names.items;
}

test "preview: a model's Solids as GLB, its parts named as the GLB's nodes, with the values the run took" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\# @title Plate
        \\w = param(:width, default: 20, validate: { min: 10 })
        \\bolt = cylinder(r: 2, h: 5).named("bolt").material(color: "#cc3333")
        \\[cube(w).named("plate"), bolt.translate(x: 30), bolt.translate(x: 40)]
    ;
    const read = try preview(arena.allocator(), source, "{\"width\": 25}");
    const h = read.header;
    try testing.expectEqual(frame.PROTOCOL_VERSION, h.protocolVersion);
    try testing.expectEqualStrings("3d", h.kind);
    try testing.expect(h.@"error" == null);
    try testing.expectEqual(@as(usize, 0), h.warnings.len);
    try testing.expectEqual(@as(usize, 2), h.parts.len);
    try testing.expectEqualStrings("plate", h.parts[0].name);
    try testing.expectEqual(@as(?[]const u8, null), h.parts[0].color);
    try testing.expectEqualStrings("bolt", h.parts[1].name);
    try testing.expectEqual(@as(u32, 2), h.parts[1].count);
    try testing.expectEqualStrings("#cc3333", h.parts[1].color.?);
    // Every node a part names is a node of the GLB, by the same name
    const nodes = try glbNodeNames(arena.allocator(), read.body);
    var named: usize = 0;
    for (h.parts) |part| for (part.nodes) |node| {
        named += 1;
        for (nodes) |n| {
            if (std.mem.eql(u8, n, node)) break;
        } else return error.TestNodeMissing;
    };
    try testing.expectEqual(@as(usize, 3), named);
    try testing.expectEqualStrings("bolt_2", h.parts[1].nodes[1]);
    // The value the run took, and the schema kupcad doc gives
    try testing.expectEqual(@as(i64, 25), h.params.values.object.get("width").?.integer);
    try testing.expectEqualStrings("Plate", h.params.schema.object.get("meta").?.object.get("title").?.string);
    try testing.expect(h.timing.runMs >= 0 and h.timing.renderMs >= 0);
}

test "preview: a model of Sketches and Paths as SVG" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const read = try preview(arena.allocator(), "[square(10).named(\"plate\"), line([0, 0], [5, 5])]", "");
    try testing.expectEqualStrings("2d", read.header.kind);
    try testing.expect(std.mem.find(u8, read.body, "<svg") != null);
    try testing.expect(std.mem.find(u8, read.body, "id=\"plate\"") != null);
}

test "preview: a refused parameter is named, with where the run failed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const read = try preview(arena.allocator(), "x = 1\nw = param(:width, default: 20, validate: { min: 10 })\ncube(w)\n", "{\"width\": 5}");
    const h = read.header;
    try testing.expectEqualStrings("none", h.kind);
    try testing.expectEqual(@as(usize, 0), read.body.len);
    const failure = h.@"error".?;
    try testing.expectEqualStrings("width", failure.param.?);
    try testing.expectEqual(@as(?u32, 2), failure.line);
    try testing.expect(std.mem.startsWith(u8, failure.message, "ValueError: parameter :width value 5 is below its minimum 10"));
    // The schema still comes: the panel keeps its controls
    try testing.expectEqual(@as(usize, 1), h.params.schema.object.get("parameters").?.array.items.len);
}

test "preview: a script that doesn't parse or compile says why, and where" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const syntax = (try preview(arena.allocator(), "w = param(:width, default: 2)\ncube(\n", "")).header;
    try testing.expectEqualStrings("none", syntax.kind);
    try testing.expect(syntax.@"error".?.line.? >= 2);
    try testing.expect(syntax.@"error".?.param == null);
    const compile = (try preview(arena.allocator(), "x = 1\ncube = 5\n", "")).header;
    try testing.expectEqual(@as(?u32, 2), compile.@"error".?.line);
    try testing.expect(std.mem.find(u8, compile.@"error".?.message, "cube") != null);
}

test "preview: Sketches beside Solids, and Solids that are empty, are said in warnings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const mixed = (try preview(arena.allocator(), "[cube(1), square(2)]", "")).header;
    try testing.expectEqualStrings("3d", mixed.kind);
    try testing.expectEqual(@as(usize, 1), mixed.warnings.len);
    try testing.expect(std.mem.find(u8, mixed.warnings[0].message, "1 Sketches and Paths") != null);
    try testing.expect(mixed.warnings[0].line == null);

    const empty = try preview(arena.allocator(), "cube(1) - cube(2, center: true).translate(x: 0.5, y: 0.5, z: 0.5)", "");
    try testing.expectEqualStrings("none", empty.header.kind);
    try testing.expect(empty.header.@"error" == null);
    try testing.expect(std.mem.find(u8, empty.header.warnings[0].message, "empty") != null);
}

test "preview: a document that ends in no model shows its ghosts, or nothing, and no error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const definitions = (try preview(arena.allocator(), "def bracket(w) = cube(w)\nsize = 5\n", "")).header;
    try testing.expectEqualStrings("none", definitions.kind);
    try testing.expect(definitions.@"error" == null);

    const ghosts = try preview(arena.allocator(), "cube(10).ghost\nsize = 5\n", "");
    try testing.expectEqualStrings("3d", ghosts.header.kind);
    try testing.expectEqual(@as(usize, 0), ghosts.header.parts.len);
    try testing.expectEqualStrings("glTF", ghosts.body[0..4]);

    // An Array with something no model holds is still the error an export would raise
    const bad_item = (try preview(arena.allocator(), "[cube(1), 5]", "")).header;
    try testing.expect(std.mem.startsWith(u8, bad_item.@"error".?.message, "TypeError"));
}

test "preview: a refusal before the run keeps the schema and says why" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const bytes = try api.previewFailure(testing.allocator, "w = param(:width, default: 2)\ncube(w)\n", "parameters: line 1, column 2: invalid JSON");
    defer testing.allocator.free(bytes);
    const h = try std.json.parseFromSliceLeaky(Header, arena.allocator(), (try frame.split(bytes)).header, .{ .allocate = .alloc_always });
    try testing.expectEqualStrings("none", h.kind);
    try testing.expectEqualStrings("parameters: line 1, column 2: invalid JSON", h.@"error".?.message);
    try testing.expect(h.@"error".?.line == null);
    try testing.expectEqualStrings("width", h.params.schema.object.get("parameters").?.array.items[0].object.get("name").?.string);
}
