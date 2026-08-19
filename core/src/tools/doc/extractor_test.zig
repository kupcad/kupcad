const std = @import("std");
const testing = std.testing;
const Document = @import("../../core/document.zig").Document;
const extractor = @import("extractor.zig");

test "Extractor: Parses Presentation Data and Param UI Config into Schema" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const source =
        \\# @title Heavy Duty Bracket
        \\# @description A parametric L-bracket optimized for 3D printing.
        \\# @author Leo
        \\
        \\param(:width, default: -150.5, ui: { label: "Base Width", group: "Dimensions" }, validate: { min: 10, max: 200 })
        \\param(:verbose, default: true)
    ;

    var doc = try Document.parse(arena.allocator(), source);
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
    try testing.expectEqualStrings("number", p1.type);
    try testing.expectEqual(@as(f64, -150.5), p1.default_value.?.float);
    try testing.expectEqualStrings("Base Width", p1.ui.label.?);
    try testing.expectEqualStrings("Dimensions", p1.ui.group.?);
    try testing.expectEqual(@as(f64, 10.0), p1.validate.min.?);
    try testing.expectEqual(@as(f64, 200.0), p1.validate.max.?);

    const p2 = schema.parameters[1];
    try testing.expectEqualStrings("verbose", p2.name);
    try testing.expectEqualStrings("boolean", p2.type);
    try testing.expectEqual(true, p2.default_value.?.bool);
}
