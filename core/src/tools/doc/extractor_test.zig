const std = @import("std");
const testing = std.testing;
const Document = @import("../../frontend/document.zig").Document;
const extractor = @import("extractor.zig");

test "Extractor: Parses Presentation Data and Param Config into Schema" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\# @title Heavy Duty Bracket
        \\# @description A parametric L-bracket optimized for 3D printing.
        \\# @author Leo
        \\
        \\param(:width, default: -150.5, validate: { min: -200, max: 200 })
        \\param(:verbose, default: true)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    const schema = try extractor.extractSchema(arena.allocator(), &doc, source);

    // Verify Presentation Meta
    try testing.expectEqualStrings("Heavy Duty Bracket", schema.meta.title.?);
    try testing.expectEqualStrings("A parametric L-bracket optimized for 3D printing.", schema.meta.description.?);
    try testing.expectEqualStrings("Leo", schema.meta.author.?);

    // Verify Parameters array
    try testing.expectEqual(@as(usize, 2), schema.parameters.len);

    const p1 = schema.parameters[0];
    try testing.expectEqualStrings("width", p1.name);
    try testing.expectEqual(.number, p1.rule.kind);
    try testing.expectEqual(@as(f64, -150.5), p1.default_value.number);
    try testing.expectEqual(@as(f64, -200.0), p1.rule.min.?);
    try testing.expectEqual(@as(f64, 200.0), p1.rule.max.?);

    const p2 = schema.parameters[1];
    try testing.expectEqualStrings("verbose", p2.name);
    try testing.expectEqual(.boolean, p2.rule.kind);
    try testing.expectEqual(true, p2.default_value.boolean);
}

test "Extractor: Parses Param within Assignments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\standoff_dist = param(:standoff_dist, default: 20.0, validate: { min: 15.0, max: 35.0 })
        \\standoff_dia  = param(:standoff_dia, default: 5.0)
    ;

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    const schema = try extractor.extractSchema(arena.allocator(), &doc, source);

    try testing.expectEqual(@as(usize, 2), schema.parameters.len);
    try testing.expectEqualStrings("standoff_dist", schema.parameters[0].name);
    try testing.expectEqual(@as(f64, 20.0), schema.parameters[0].default_value.number);
    try testing.expectEqualStrings("standoff_dia", schema.parameters[1].name);
}

test "Extractor: the schema is what param accepts, choices included, as JSON" {
    // `validate: { in: }` was dropped, and the schema had `ui` and `validate.step`, which
    // param refuses as unknown keywords: the JSON described scripts that can't run.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\width = param(:width, default: 20.0, validate: { min: 10.0, max: 100.0 })
        \\material = param(:material, default: "PLA", validate: { in: ["PLA", "PETG", "ABS"] })
        \\mount = param(:mount, default: :screw, validate: { in: [:screw, :clip] })
        \\holes = param(:holes, default: 4, validate: { in: [2, 4, -6] })
        \\size = param(:size, default: 1, validate: { in: [1, width] })
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    const schema = try extractor.extractSchema(arena.allocator(), &doc, source);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{std.json.fmt(schema, .{})});
    // A choice list with something computed in it can't be known before the script runs,
    // so it is left out rather than shown short.
    try testing.expectEqualStrings(
        \\{"meta":{"title":null,"description":null,"author":null},"parameters":[
    ++
        \\{"name":"width","type":"number","min":10,"max":100,"in":null,"items":null,"tuple":null,"fields":null,"min_items":null,"max_items":null,"title":null,"unit":null,"step":null,"default_value":20,"group":null,"description":null},
    ++
        \\{"name":"material","type":"string","min":null,"max":null,"in":["PLA","PETG","ABS"],"items":null,"tuple":null,"fields":null,"min_items":null,"max_items":null,"title":null,"unit":null,"step":null,"default_value":"PLA","group":null,"description":null},
    ++
        \\{"name":"mount","type":"string","min":null,"max":null,"in":["screw","clip"],"items":null,"tuple":null,"fields":null,"min_items":null,"max_items":null,"title":null,"unit":null,"step":null,"default_value":"screw","group":null,"description":null},
    ++
        \\{"name":"holes","type":"number","min":null,"max":null,"in":[2,4,-6],"items":null,"tuple":null,"fields":null,"min_items":null,"max_items":null,"title":null,"unit":null,"step":null,"default_value":4,"group":null,"description":null},
    ++
        \\{"name":"size","type":"number","min":null,"max":null,"in":null,"items":null,"tuple":null,"fields":null,"min_items":null,"max_items":null,"title":null,"unit":null,"step":null,"default_value":1,"group":null,"description":null}]}
    , out.written());
}

test "Extractor: step, unit, group, title and description, for a host's controls, from literals only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\u = "in"
        \\width = param(:width, default: 20, step: 0.5, unit: "mm", group: "Size", title: "Width", description: "Across the plate")
        \\label = param(:label, default: "A", group: :Text)
        \\depth = param(:depth, default: 5, unit: u, title: "Depth #{u}")
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    const schema = try extractor.extractSchema(arena.allocator(), &doc, source);
    const width = schema.parameters[0];
    try testing.expectEqual(@as(f64, 0.5), width.rule.step.?);
    try testing.expectEqualStrings("mm", width.rule.unit.?);
    try testing.expectEqualStrings("Size", width.group.?);
    try testing.expectEqualStrings("Width", width.rule.title.?);
    try testing.expectEqualStrings("Across the plate", width.description.?);
    try testing.expectEqualStrings("Text", schema.parameters[1].group.?);
    try testing.expect(schema.parameters[1].rule.step == null);
    // Without them a host shows the name
    try testing.expect(schema.parameters[1].rule.title == null and schema.parameters[1].description == null);
    // A variable's value, or a string built from one, is the run's to know
    try testing.expect(schema.parameters[2].rule.unit == null);
    try testing.expect(schema.parameters[2].rule.title == null);
}

test "Extractor: a parameter's type is type:'s, else its default's, else its choices', else a String's" {
    // One without a literal default was a number, whatever the run would make it
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\key = param(:key, title: "Key")
        \\none = param(:none, default: nil)
        \\count = param(:count, type: :number)
        \\size = param(:size, type: :symbol, validate: { in: [:m3, :m4] })
        \\pick = param(:pick, validate: { in: [:m3, :m4] })
        \\vec = param(:vec, default: [10, -20, 30], unit: "mm")
        \\pts = param(:pts, default: [[0, 0], [10, 0]])
        \\list = param(:list, type: :array)
        \\made = param(:made, default: [1, made_up])
        \\computed = param(:computed, default: 2 * 3)
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    const schema = try extractor.extractSchema(arena.allocator(), &doc, source);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for (schema.parameters) |spec| {
        try out.writer.print("{s} {s} {f}\n", .{ spec.name, spec.rule.kind.schemaName(), std.json.fmt(spec.default_value, .{}) });
    }
    // An Array with something computed in it, as any default the run computes, is taken
    // for a number's
    try testing.expectEqualStrings(
        \\key string null
        \\none string null
        \\count number null
        \\size string null
        \\pick string null
        \\vec array [10,-20,30]
        \\pts array [[0,0],[10,0]]
        \\list array null
        \\made number null
        \\computed number null
        \\
    , out.written());
}

test "Extractor: a declaration the run refuses is listed with what its type and default give" {
    // Its default breaks its own rules, then the rules themselves are wrong: the schema
    // still lists each, so a host shows a control the run will say why it refuses
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\a = param(:a, default: 5, validate: { min: 10 })
        \\b = param(:b, default: [1], validate: { colour: 1 })
        \\c = param(:c, type: :vector)
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    const schema = try extractor.extractSchema(arena.allocator(), &doc, source);
    try testing.expectEqual(.number, schema.parameters[0].rule.kind);
    try testing.expect(schema.parameters[0].rule.min == null);
    try testing.expectEqual(.array, schema.parameters[1].rule.kind);
    try testing.expectEqual(.number, schema.parameters[1].rule.items.?.kind);
    try testing.expectEqual(.string, schema.parameters[2].rule.kind);
}

test "Extractor: lists, tuples and Maps, as their rules and their defaults say" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const source =
        \\pts = param(:pts, default: [[0, 0], [10, 0]], validate: { max_items: 8, items: { tuple: [{ type: :number, title: "X" }, { type: :number, title: "Y", max: w }] } }, unit: "mm")
        \\cuts = param(:cuts, default: [{ type: "slot", depth: 5 }])
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    const schema = try extractor.extractSchema(arena.allocator(), &doc, source);

    const pts = schema.parameters[0].rule;
    try testing.expectEqual(@as(usize, 8), pts.max_items.?);
    const point = pts.items.?.tuple.?;
    try testing.expectEqualStrings("X", point[0].title.?);
    // A rule the run computes is left out, the rest kept; the parameter's unit is each number's
    try testing.expect(point[1].max == null);
    try testing.expectEqualStrings("Y", point[1].title.?);
    try testing.expectEqualStrings("mm", point[1].unit.?);

    const cut = schema.parameters[1].rule.items.?.fields.?;
    try testing.expectEqualStrings("type", cut[0].name);
    try testing.expectEqual(.string, cut[0].rule.kind);
    try testing.expectEqualStrings("depth", cut[1].name);
    try testing.expectEqual(.number, cut[1].rule.kind);
}
