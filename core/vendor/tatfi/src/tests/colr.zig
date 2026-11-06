const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
const Unit = @import("main.zig").Unit;
const colr = ttf.tables.colr;
const cpal = ttf.tables.cpal;

test "basic" {
    const cpal_data = try convert(&.{
        .{ .unt16 = 0 }, // version
        .{ .unt16 = 3 }, // number of palette entries
        .{ .unt16 = 1 }, // number of palettes
        .{ .unt16 = 3 }, // number of colors
        .{ .unt32 = 14 }, // offset to colors
        .{ .unt16 = 0 }, // index of palette 0's first color
        .{ .unt8 = 10 },
        .{ .unt8 = 15 },
        .{ .unt8 = 20 },
        .{ .unt8 = 25 }, // color 0
        .{ .unt8 = 30 },
        .{ .unt8 = 35 },
        .{ .unt8 = 40 },
        .{ .unt8 = 45 }, // color 1
        .{ .unt8 = 50 },
        .{ .unt8 = 55 },
        .{ .unt8 = 60 },
        .{ .unt8 = 65 }, // color 2
    });
    defer t.allocator.free(cpal_data);

    const colr_data = try convert(&.{
        .{ .unt16 = 0 }, // version
        .{ .unt16 = 3 }, // number of base glyphs
        .{ .unt32 = 14 }, // offset to base glyphs
        .{ .unt32 = 32 }, // offset to layers
        .{ .unt16 = 4 }, // number of layers
        .{ .unt16 = 2 },
        .{ .unt16 = 2 },
        .{ .unt16 = 2 }, // base glyph 0 (id 2)
        .{ .unt16 = 3 },
        .{ .unt16 = 0 },
        .{ .unt16 = 3 }, // base glyph 1 (id 3)
        .{ .unt16 = 7 },
        .{ .unt16 = 1 },
        .{ .unt16 = 1 }, // base glyph 2 (id 7)
        .{ .unt16 = 10 },
        .{ .unt16 = 2 }, // layer 0
        .{ .unt16 = 11 },
        .{ .unt16 = 1 }, // layer 1
        .{ .unt16 = 12 },
        .{ .unt16 = 2 }, // layer 2
        .{ .unt16 = 13 },
        .{ .unt16 = 0 }, // layer 3
    });
    defer t.allocator.free(colr_data);

    const cpal_table = try cpal.parse(cpal_data);
    const colr_table = try colr.parse(cpal_table, colr_data);

    try t.expect(!colr_table.contains(.{1}));
    try t.expect(colr_table.contains(.{2}));
    try t.expect(colr_table.contains(.{3}));
    try t.expect(!colr_table.contains(.{4}));
    try t.expect(!colr_table.contains(.{5}));
    try t.expect(!colr_table.contains(.{6}));
    try t.expect(colr_table.contains(.{7}));

    const a: CustomPaint, const b: CustomPaint, const c: CustomPaint = c: {
        const a = std.mem.zeroInit(ttf.RgbaColor, .{ 20, 15, 10, 25 });
        const b = std.mem.zeroInit(ttf.RgbaColor, .{ 40, 35, 30, 45 });
        const c = std.mem.zeroInit(ttf.RgbaColor, .{ 60, 55, 50, 65 });

        try t.expectEqual(a, cpal_table.get(0, 0));
        try t.expectEqual(b, cpal_table.get(0, 1));
        try t.expectEqual(c, cpal_table.get(0, 2));
        try t.expectEqual(null, cpal_table.get(0, 3));
        try t.expectEqual(null, cpal_table.get(1, 0));

        break :c .{ .{ .solid = a }, .{ .solid = b }, .{ .solid = c } };
    };

    const basic_paint = struct {
        fn basic_paint(
            id: u16,
            table: colr,
        ) ?[]Command {
            var commands: std.ArrayList(Command) = .empty;
            defer commands.deinit(t.allocator);

            const painter = init_painter(&commands);
            table.paint(.{id}, 0, painter, &.{}, .new(0, 0, 0, 255)) catch return null;

            return commands.toOwnedSlice(t.allocator) catch unreachable;
        }
    }.basic_paint;

    try t.expectEqual(null, basic_paint(1, colr_table));
    {
        const actual = basic_paint(2, colr_table).?;
        defer t.allocator.free(actual);

        const expected: []const Command = &.{
            .{ .outline_glyph = .{12} },
            .push_clip,
            .{ .paint = c },
            .pop_clip,
            .{ .outline_glyph = .{13} },
            .push_clip,
            .{ .paint = a },
            .pop_clip,
        };

        try t.expectEqualSlices(Command, expected, actual);
    }
    {
        const actual = basic_paint(3, colr_table).?;
        defer t.allocator.free(actual);

        const expected: []const Command = &.{
            .{ .outline_glyph = .{10} },
            .push_clip,
            .{ .paint = c },
            .pop_clip,
            .{ .outline_glyph = .{11} },
            .push_clip,
            .{ .paint = b },
            .pop_clip,
            .{ .outline_glyph = .{12} },
            .push_clip,
            .{ .paint = c },
            .pop_clip,
        };

        try t.expectEqualSlices(Command, expected, actual);
    }
    {
        const actual = basic_paint(7, colr_table).?;
        defer t.allocator.free(actual);

        const expected: []const Command = &.{
            .{ .outline_glyph = .{11} },
            .push_clip,
            .{ .paint = b },
            .pop_clip,
        };

        try t.expectEqualSlices(Command, expected, actual);
    }
}

// A static and variable COLRv1 test font from Google Fonts:
// https://github.com/googlefonts/color-fonts
const COLR1_STATIC = @embedFile("fonts/colr_1.ttf");
const COLR1_VARIABLE = @embedFile("fonts/colr_1_variable.ttf");

test "colr1 static linear_gradient" {
    const face = try ttf.Face.parse(COLR1_STATIC, 0);

    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);

    try face.paint_color_glyph(.{9}, 0, .new(0, 0, 0, 255), vec_painter);

    const expected: []const Command = &.{
        .{ .push_clip_box = .{ .x_min = 100.0, .y_min = 250.0, .x_max = 900.0, .y_max = 950.0 } },
        .{ .outline_glyph = .{9} },
        .push_clip,
        .{ .paint = .{ .linear_gradient = .{
            100.0, 250.0, 900.0, 250.0, 100.0, 300.0, .repeat,
            &.{
                .{ .stop_offset = 0.2000122, .color = .new(255, 0, 0, 255) },
                .{ .stop_offset = 0.7999878, .color = .new(0, 0, 255, 255) },
            },
        } } },
        .pop_clip,
        .pop_clip,
    };

    try t.expectEqualDeep(expected, commands.items);
}

test "colr1 static sweep_gradient" {
    const face = try ttf.Face.parse(COLR1_STATIC, 0);
    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);

    try face.paint_color_glyph(.{13}, 0, .new(0, 0, 0, 255), vec_painter);

    const expected: []const Command = &.{
        .{ .push_clip_box = .{ .x_min = 0.0, .y_min = 0.0, .x_max = 1000.0, .y_max = 1000.0 } },
        .{ .outline_glyph = .{176} },
        .push_clip,
        .{ .paint = .{ .sweep_gradient = .{
            500.0, 600.0, -0.666687, 0.666687, .pad,
            &.{
                .{ .stop_offset = 0.25, .color = .new(250, 240, 230, 255) },
                .{ .stop_offset = 0.416687, .color = .new(0, 0, 255, 255) },
                .{ .stop_offset = 0.583313, .color = .new(255, 0, 0, 255) },
                .{ .stop_offset = 0.75, .color = .new(47, 79, 79, 255) },
            },
        } } },
        .pop_clip,
        .pop_clip,
    };

    try t.expectEqualDeep(expected, commands.items);
}

test "colr1 static scale_around_center" {
    const face = try ttf.Face.parse(COLR1_STATIC, 0);
    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);

    try face.paint_color_glyph(.{84}, 0, .new(0, 0, 0, 255), vec_painter);

    const expected: []const Command = &.{
        .{ .push_layer = .source_over },
        .{ .outline_glyph = .{3} },
        .push_clip,
        .{ .paint = .{ .solid = .new(0, 0, 255, 127) } },
        .pop_clip,
        .{ .push_layer = .destination_over },
        .{ .push_transform = .new_translate(500.0, 500.0) },
        .{ .push_transform = .new_scale(0.5, 1.5) },
        .{ .push_transform = .new_translate(-500.0, -500.0) },
        .{ .outline_glyph = .{3} },
        .push_clip,
        .{ .paint = .{ .solid = .new(255, 165, 0, 178) } },
        .pop_clip,
        .pop_transform,
        .pop_transform,
        .pop_transform,
        .pop_layer,
        .pop_layer,
    };

    try t.expectEqualDeep(expected, commands.items);
}

test "colr1 static scale" {
    const face = try ttf.Face.parse(COLR1_STATIC, 0);
    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);

    try face.paint_color_glyph(.{86}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expect(commands_contain(
        commands.items,
        .{ .push_transform = .new_scale(0.5, 1.5) },
    ));
}

test "colr1 static radial_gradient" {
    const face = try ttf.Face.parse(COLR1_STATIC, 0);
    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);

    try face.paint_color_glyph(.{93}, 0, .new(0, 0, 0, 255), vec_painter);

    const expected: []const Command = &.{
        .{ .push_clip_box = .{ .x_min = 0.0, .y_min = 0.0, .x_max = 1000.0, .y_max = 1000.0 } },
        .{ .outline_glyph = .{2} },
        .push_clip,
        .{ .paint = .{ .radial_gradient = .{
            166.0, 768.0, 0.0, 256.0, 166.0, 768.0, .pad,
            &.{
                .{ .stop_offset = 0.0, .color = .new(0, 128, 0, 255) },
                .{ .stop_offset = 0.5, .color = .new(255, 255, 255, 255) },
                .{ .stop_offset = 1.0, .color = .new(255, 0, 0, 255) },
            },
        } } },
        .pop_clip,
        .pop_clip,
    };

    try t.expectEqualDeep(expected, commands.items);
}

test "colr1 static rotate" {
    const face = try ttf.Face.parse(COLR1_STATIC, 0);
    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);

    try face.paint_color_glyph(.{99}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expect(commands_contain(
        commands.items,
        .{ .push_transform = .new_rotate(0.055541992) },
    ));
}

test "colr1 static rotate_around_center" {
    const face = try ttf.Face.parse(COLR1_STATIC, 0);
    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);

    try face.paint_color_glyph(.{101}, 0, .new(0, 0, 0, 255), vec_painter);

    const expected: []const Command = &.{
        .{ .push_layer = .source_over },
        .{ .outline_glyph = .{3} },
        .push_clip,
        .{ .paint = .{ .solid = .new(0, 0, 255, 127) } },
        .pop_clip,
        .{ .push_layer = .destination_over },
        .{ .push_transform = .new_translate(500.0, 500.0) },
        .{ .push_transform = .new_rotate(0.13891602) },
        .{ .push_transform = .new_translate(-500.0, -500.0) },
        .{ .outline_glyph = .{3} },
        .push_clip,
        .{ .paint = .{ .solid = .new(255, 165, 0, 178) } },
        .pop_clip,
        .pop_transform,
        .pop_transform,
        .pop_transform,
        .pop_layer,
        .pop_layer,
    };

    try t.expectEqualDeep(expected, commands.items);
}

test "colr1 static skew" {
    const face = try ttf.Face.parse(COLR1_STATIC, 0);
    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);

    try face.paint_color_glyph(.{103}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expect(commands_contain(
        commands.items,
        .{ .push_transform = .new_skew(0.13891602, 0.0) },
    ));
}

test "colr1 static skew_around_center" {
    const face = try ttf.Face.parse(COLR1_STATIC, 0);
    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);

    try face.paint_color_glyph(.{104}, 0, .new(0, 0, 0, 255), vec_painter);

    const expected: []const Command = &.{
        .{ .push_layer = .source_over },
        .{ .outline_glyph = .{3} },
        .push_clip,
        .{ .paint = .{ .solid = .new(0, 0, 255, 127) } },
        .pop_clip,
        .{ .push_layer = .destination_over },
        .{ .push_transform = .new_translate(500.0, 500.0) },
        .{ .push_transform = .new_skew(0.13891602, 0.0) },
        .{ .push_transform = .new_translate(-500.0, -500.0) },
        .{ .outline_glyph = .{3} },
        .push_clip,
        .{ .paint = .{ .solid = .new(255, 165, 0, 178) } },
        .pop_clip,
        .pop_transform,
        .pop_transform,
        .pop_transform,
        .pop_layer,
        .pop_layer,
    };

    try t.expectEqualDeep(expected, commands.items);
}

test "colr1 static transform" {
    const face = try ttf.Face.parse(COLR1_STATIC, 0);
    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);

    try face.paint_color_glyph(.{109}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expect(commands_contain(
        commands.items,
        .{ .push_transform = .{ .a = 1.0, .b = 0.0, .c = 0.0, .d = 1.0, .e = 125.0, .f = 125.0 } },
    ));
}

test "colr1 static translate" {
    const face = try ttf.Face.parse(COLR1_STATIC, 0);
    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);

    try face.paint_color_glyph(.{114}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expect(commands_contain(
        commands.items,
        .{ .push_transform = .new_translate(0.0, 100.0) },
    ));
}

test "colr1 static composite" {
    const face = try ttf.Face.parse(COLR1_STATIC, 0);
    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);

    try face.paint_color_glyph(.{131}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expect(commands_contain(
        commands.items,
        .{ .push_layer = .xor },
    ));
}

test "colr1 static cyclic_dependency" {
    const face = try ttf.Face.parse(COLR1_STATIC, 0);

    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);

    try face.paint_color_glyph(.{179}, 0, .new(0, 0, 0, 255), vec_painter);
    // The cycle is found where it closes. With std.mem.containsAtLeastScalar's arguments in
    // their pre-0.17 order (minimum before element) the check never matched, and the paint
    // went on 64 levels deep, to the recursion stack's capacity: 130 commands.
    try t.expectEqual(@as(usize, 6), commands.items.len);
}

test "colr1 variable sweep_gradient" {
    var face = try ttf.Face.parse(COLR1_VARIABLE, 0);
    try face.set_variation(.from_bytes("SWPS"), 45.0);
    try face.set_variation(.from_bytes("SWPE"), 58.0);

    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);

    try face.paint_color_glyph(.{13}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expectEqualDeep(Command{ .paint = .{ .sweep_gradient = .{
        500.0, 600.0, -0.416687, 0.9888916, .pad,
        &.{
            .{ .stop_offset = 0.25, .color = .new(250, 240, 230, 255) },
            .{ .stop_offset = 0.416687, .color = .new(0, 0, 255, 255) },
            .{ .stop_offset = 0.583313, .color = .new(255, 0, 0, 255) },
            .{ .stop_offset = 0.75, .color = .new(47, 79, 79, 255) },
        },
    } } }, commands.items[3]);
}

test "colr1 variable scale_around_center" {
    var face = try ttf.Face.parse(COLR1_VARIABLE, 0);
    try face.set_variation(.from_bytes("SCSX"), 1.1);
    try face.set_variation(.from_bytes("SCSY"), -0.9);

    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);
    try face.paint_color_glyph(.{84}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expect(commands_contain(
        commands.items,
        .{ .push_transform = .new_scale(1.599942, 0.60009766) },
    ));
}

test "colr1 variable scale" {
    var face = try ttf.Face.parse(COLR1_VARIABLE, 0);
    try face.set_variation(.from_bytes("SCSX"), 1.1);
    try face.set_variation(.from_bytes("SCSY"), -0.9);

    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);
    try face.paint_color_glyph(.{86}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expect(commands_contain(
        commands.items,
        .{ .push_transform = .new_scale(1.599942, 0.60009766) },
    ));
}

test "colr1 variable radial_gradient" {
    const face = try ttf.Face.parse(COLR1_STATIC, 0);

    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);
    try face.paint_color_glyph(.{93}, 0, .new(0, 0, 0, 255), vec_painter);

    const expected: []const Command = &.{
        .{ .push_clip_box = .{ .x_min = 0.0, .y_min = 0.0, .x_max = 1000.0, .y_max = 1000.0 } },
        .{ .outline_glyph = .{2} },
        .push_clip,
        .{ .paint = .{ .radial_gradient = .{
            166.0, 768.0, 0.0, 256.0, 166.0, 768.0, .pad,
            &.{
                .{ .stop_offset = 0.0, .color = .new(0, 128, 0, 255) },
                .{ .stop_offset = 0.5, .color = .new(255, 255, 255, 255) },
                .{ .stop_offset = 1.0, .color = .new(255, 0, 0, 255) },
            },
        } } },
        .pop_clip,
        .pop_clip,
    };

    try t.expectEqualDeep(expected, commands.items);
}

test "colr1 variable rotate" {
    var face = try ttf.Face.parse(COLR1_VARIABLE, 0);
    try face.set_variation(.from_bytes("ROTA"), 150.0);

    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);
    try face.paint_color_glyph(.{99}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expect(commands_contain(
        commands.items,
        .{ .push_transform = .new_rotate(0.87341005) },
    ));
}

test "colr1 variable rotate_around_center" {
    var face = try ttf.Face.parse(COLR1_VARIABLE, 0);
    try face.set_variation(.from_bytes("ROTA"), 150.0);

    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);
    try face.paint_color_glyph(.{101}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expect(commands_contain(
        commands.items,
        .{ .push_transform = .new_rotate(0.9336252) },
    ));
}

test "colr1 variable skew" {
    var face = try ttf.Face.parse(COLR1_VARIABLE, 0);
    try face.set_variation(.from_bytes("SKXA"), 46.0);

    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);
    try face.paint_color_glyph(.{103}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expect(commands_contain(
        commands.items,
        .{ .push_transform = .new_skew(0.3944702, 0.0) },
    ));
}

test "colr1 variable skew_around_center" {
    var face = try ttf.Face.parse(COLR1_VARIABLE, 0);
    try face.set_variation(.from_bytes("SKXA"), 46.0);

    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);
    try face.paint_color_glyph(.{104}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expect(commands_contain(
        commands.items,
        .{ .push_transform = .new_skew(0.3944702, 0.0) },
    ));
}

test "colr1 variable transform" {
    var face = try ttf.Face.parse(COLR1_VARIABLE, 0);
    try face.set_variation(.from_bytes("TRDX"), 150.0);

    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);
    try face.paint_color_glyph(.{109}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expect(commands_contain(
        commands.items,
        .{ .push_transform = .{ .a = 1.0, .b = 0.0, .c = 0.0, .d = 1.0, .e = 274.9939, .f = 125.0 } },
    ));
}

test "colr1 variable translate" {
    var face = try ttf.Face.parse(COLR1_VARIABLE, 0);
    try face.set_variation(.from_bytes("TLDX"), 100.0);

    var commands: std.ArrayList(Command) = .empty;
    defer {
        for (commands.items) |*cmd| cmd.deinit();
        commands.deinit(t.allocator);
    }

    const vec_painter = init_painter(&commands);
    try face.paint_color_glyph(.{114}, 0, .new(0, 0, 0, 255), vec_painter);

    try t.expect(commands_contain(
        commands.items,
        .{ .push_transform = .new_translate(99.975586, 100.0) },
    ));
}

test "a base glyph with more layers than the table has" {
    // [KupCAD] Slicing the layers past their end panicked; ttf-parser's slice returns None.
    const cpal_data = try convert(&.{
        .{ .unt16 = 0 }, // version
        .{ .unt16 = 1 }, // number of palette entries
        .{ .unt16 = 1 }, // number of palettes
        .{ .unt16 = 1 }, // number of colors
        .{ .unt32 = 14 }, // offset to colors
        .{ .unt16 = 0 }, // index of palette 0's first color
        .{ .unt32 = 0 }, // color 0
    });
    defer t.allocator.free(cpal_data);

    const colr_data = try convert(&.{
        .{ .unt16 = 0 }, // version
        .{ .unt16 = 1 }, // number of base glyphs
        .{ .unt32 = 14 }, // offset to base glyphs
        .{ .unt32 = 20 }, // offset to layers
        .{ .unt16 = 1 }, // number of layers
        .{ .unt16 = 5 },
        .{ .unt16 = 0 },
        .{ .unt16 = 10 }, // base glyph 0 (id 5): ten layers from the first
        .{ .unt16 = 1 },
        .{ .unt16 = 0 }, // layer 0
    });
    defer t.allocator.free(colr_data);

    const colr_table = try colr.parse(try cpal.parse(cpal_data), colr_data);

    var commands: std.ArrayList(Command) = .empty;
    defer commands.deinit(t.allocator);
    try t.expectError(
        error.PaintError,
        colr_table.paint(.{5}, 0, init_painter(&commands), &.{}, .new(0, 0, 0, 255)),
    );
}

/// A COLRv1 table whose base glyph list's one record, for glyph 1, has `paint_offset`, then
/// `rest` from offset 44, with a layer list at `layer_list_offset` and a clip list at
/// `clip_list_offset`, a var index map at `var_index_map_offset` and an item variation store
/// at `item_variation_store_offset` (0 for none).
fn colr_v1(paint_offset: u32, offsets: [4]u32, rest: []const Unit) ![]u8 {
    var units: std.ArrayList(Unit) = .empty;
    defer units.deinit(t.allocator);
    try units.appendSlice(t.allocator, &.{
        .{ .unt16 = 1 }, // version
        .{ .unt16 = 0 }, // number of base glyphs
        .{ .unt32 = 0 }, // offset to base glyphs
        .{ .unt32 = 0 }, // offset to layers
        .{ .unt16 = 0 }, // number of layers
        .{ .unt32 = 34 }, // offset to the base glyph list
        .{ .unt32 = offsets[0] }, // offset to the layer list
        .{ .unt32 = offsets[1] }, // offset to the clip list
        .{ .unt32 = offsets[2] }, // offset to the var index map
        .{ .unt32 = offsets[3] }, // offset to the item variation store
        // Base glyph list, at 34
        .{ .unt32 = 1 }, // count
        .{ .unt16 = 1 }, // record 0: glyph
        .{ .unt32 = paint_offset }, // its paint's offset
    });
    try units.appendSlice(t.allocator, rest);
    return convert(units.items);
}

/// A CPAL table of one palette of one color.
const one_color_cpal = [_]u8{
    0, 0, // version
    0, 1, // number of palette entries
    0, 1, // number of palettes
    0, 1, // number of colors
    0, 0, 0, 14, // offset to colors
    0, 0, // index of palette 0's first color
    0, 0, 0, 0, // color 0
};

/// The commands painting glyph 1 of `colr_data` gives.
fn paint_glyph_1(colr_data: []const u8) ![]Command {
    const table = try colr.parse(try cpal.parse(&one_color_cpal), colr_data);

    var commands: std.ArrayList(Command) = .empty;
    errdefer commands.deinit(t.allocator);
    try table.paint(.{1}, 0, init_painter(&commands), &.{}, .new(0, 0, 0, 255));
    return commands.toOwnedSlice(t.allocator);
}

test "a base glyph paint past a u32" {
    // [KupCAD] The base glyph list's offset plus its record's paint offset overflowed the
    // u32s they were added in.
    const data = try colr_v1(0xFFFFFFF0, .{ 0, 0, 0, 0 }, &.{});
    defer t.allocator.free(data);

    const commands = try paint_glyph_1(data);
    defer t.allocator.free(commands);
    try t.expectEqual(0, commands.len);
}

test "a layer paint past a u32" {
    // [KupCAD] The layer list's offset plus a layer's paint offset overflowed the u32s they
    // were added in.
    const data = try colr_v1(10, .{ 50, 0, 0, 0 }, &.{
        // Paint, at 44: PaintColrLayers of one layer, the first
        .{ .unt8 = 1 }, // format
        .{ .unt8 = 1 }, // number of layers
        .{ .unt32 = 0 }, // first layer index
        // Layer list, at 50
        .{ .unt32 = 1 }, // count
        .{ .unt32 = 0xFFFFFFFF }, // layer 0's paint offset
    });
    defer t.allocator.free(data);

    const commands = try paint_glyph_1(data);
    defer t.allocator.free(commands);
    try t.expectEqual(0, commands.len);
}

/// A COLRv1 table whose glyph 1 has a variable clip box of `var_index_base`, with a var
/// index map of `entry_format` and 0xFFFFFFFF entries (none in the data), and an empty item
/// variation store.
fn colr_with_variable_clip_box(var_index_base: u32, entry_format: u8) ![]u8 {
    return colr_v1(0, .{ 0, 44, 69, 75 }, &.{
        // Clip list, at 44
        .{ .unt8 = 1 }, // format
        .{ .unt32 = 1 }, // count
        .{ .unt16 = 1 }, // record 0: first glyph
        .{ .unt16 = 1 }, // last glyph
        .{ .raw = &.{ 0, 0, 12 } }, // clip box offset (Offset24)
        // Clip box, at 56
        .{ .unt8 = 2 }, // format: variable
        .{ .int16 = 0 }, // x min
        .{ .int16 = 0 }, // y min
        .{ .int16 = 10 }, // x max
        .{ .int16 = 10 }, // y max
        .{ .unt32 = var_index_base },
        // Var index map, at 69
        .{ .unt8 = 1 }, // format
        .{ .unt8 = entry_format },
        .{ .unt32 = 0xFFFFFFFF }, // map count
        // Item variation store, at 75
        .{ .unt16 = 1 }, // format
        .{ .unt32 = 8 }, // offset to the region list
        .{ .unt16 = 0 }, // number of item variation data
        .{ .unt16 = 0 }, // region list: axis count
        .{ .unt16 = 0 }, // region count
    });
}

test "a clip box's variation indices past a u32" {
    // [KupCAD] Its four deltas' indices, from 0xFFFFFFFE, overflowed the u32 at the third.
    const data = try colr_with_variable_clip_box(0xFFFFFFFE, 0x00);
    defer t.allocator.free(data);

    const table = try colr.parse(try cpal.parse(&one_color_cpal), data);
    const coords: []const ttf.NormalizedCoordinate = &.{.{ .inner = 0 }};
    try t.expectEqual(colr.ClipBox{ .x_min = 0, .y_min = 0, .x_max = 10, .y_max = 10 }, table.clip_box(.{1}, coords));
}

test "a var index map entry past a u32" {
    // [KupCAD] The map's entry offset, index 0x80000000 times two bytes, overflowed the u32.
    const data = try colr_with_variable_clip_box(0x80000000, 0x10);
    defer t.allocator.free(data);

    const table = try colr.parse(try cpal.parse(&one_color_cpal), data);
    const coords: []const ttf.NormalizedCoordinate = &.{.{ .inner = 0 }};
    try t.expectEqual(colr.ClipBox{ .x_min = 0, .y_min = 0, .x_max = 10, .y_max = 10 }, table.clip_box(.{1}, coords));
}

// Helpers

const CustomPaint = union(enum) {
    solid: ttf.RgbaColor,
    linear_gradient: G,
    radial_gradient: G,
    sweep_gradient: struct { f32, f32, f32, f32, colr.GradientExtend, []const colr.ColorStop },

    const G = struct { f32, f32, f32, f32, f32, f32, colr.GradientExtend, []const colr.ColorStop };

    fn from(pnt: colr.Paint) !CustomPaint {
        return switch (pnt) {
            .solid => |c| .{ .solid = c },
            .linear_gradient => |lg| lg: {
                var iter = lg.stops(0, &.{});
                const stops = try iter.collect(t.allocator);
                break :lg .{ .linear_gradient = .{
                    lg.x0,     lg.y0, lg.x1,
                    lg.y1,     lg.x2, lg.y2,
                    lg.extend, stops,
                } };
            },
            .radial_gradient => |rg| rg: {
                var iter = rg.stops(0, &.{});
                const stops = try iter.collect(t.allocator);
                break :rg .{ .radial_gradient = .{
                    rg.x0,     rg.y0, rg.r0,
                    rg.r1,     rg.x1, rg.y1,
                    rg.extend, stops,
                } };
            },
            .sweep_gradient => |sg| sg: {
                var iter = sg.stops(0, &.{});
                const stops = try iter.collect(t.allocator);
                break :sg .{ .sweep_gradient = .{
                    sg.center_x,  sg.center_y, sg.start_angle,
                    sg.end_angle, sg.extend,   stops,
                } };
            },
        };
    }

    fn deinit(self: *CustomPaint) void {
        switch (self.*) {
            .linear_gradient, .radial_gradient => |g| t.allocator.free(g[7]),
            .sweep_gradient => |g| t.allocator.free(g[5]),
            else => {},
        }
    }
};

const Command = union(enum) {
    outline_glyph: ttf.GlyphId,
    paint: CustomPaint,
    push_layer: colr.CompositeMode,
    pop_layer,
    push_transform: ttf.Transform,
    pop_transform,
    push_clip,
    push_clip_box: colr.ClipBox,
    pop_clip,

    fn deinit(self: *Command) void {
        switch (self.*) {
            .paint => |*p| p.deinit(),
            else => {},
        }
    }
};

fn init_painter(
    ptr: *std.ArrayList(Command),
) colr.Painter {
    return .{ .ptr = ptr, .vtable = .{
        .outline_glyph = outline_glyph,
        .paint = paint,
        .push_layer = push_layer,
        .pop_layer = pop_layer,
        .push_transform = push_transform,
        .pop_transform = pop_transform,
        .push_clip = push_clip,
        .push_clip_box = push_clip_box,
        .pop_clip = pop_clip,
    } };
}

fn outline_glyph(
    ptr: *anyopaque,
    glyph_id: ttf.GlyphId,
) void {
    const v: *std.ArrayList(Command) = @ptrCast(@alignCast(ptr));
    v.append(t.allocator, .{ .outline_glyph = glyph_id }) catch unreachable;
}

fn paint(
    ptr: *anyopaque,
    pnt: colr.Paint,
) void {
    const v: *std.ArrayList(Command) = @ptrCast(@alignCast(ptr));
    const custom_paint = CustomPaint.from(pnt) catch unreachable;
    v.append(t.allocator, .{ .paint = custom_paint }) catch unreachable;
}

fn push_layer(
    ptr: *anyopaque,
    mode: colr.CompositeMode,
) void {
    const v: *std.ArrayList(Command) = @ptrCast(@alignCast(ptr));
    v.append(t.allocator, .{ .push_layer = mode }) catch unreachable;
}

fn pop_layer(
    ptr: *anyopaque,
) void {
    const v: *std.ArrayList(Command) = @ptrCast(@alignCast(ptr));
    v.append(t.allocator, .pop_layer) catch unreachable;
}

fn push_transform(
    ptr: *anyopaque,
    transform: ttf.Transform,
) void {
    const v: *std.ArrayList(Command) = @ptrCast(@alignCast(ptr));
    v.append(t.allocator, .{ .push_transform = transform }) catch unreachable;
}

fn pop_transform(
    ptr: *anyopaque,
) void {
    const v: *std.ArrayList(Command) = @ptrCast(@alignCast(ptr));
    v.append(t.allocator, .pop_transform) catch unreachable;
}

fn push_clip(
    ptr: *anyopaque,
) void {
    const v: *std.ArrayList(Command) = @ptrCast(@alignCast(ptr));
    v.append(t.allocator, .push_clip) catch unreachable;
}

fn push_clip_box(
    ptr: *anyopaque,
    clipbox: colr.ClipBox,
) void {
    const v: *std.ArrayList(Command) = @ptrCast(@alignCast(ptr));
    v.append(t.allocator, .{ .push_clip_box = clipbox }) catch unreachable;
}

fn pop_clip(
    ptr: *anyopaque,
) void {
    const v: *std.ArrayList(Command) = @ptrCast(@alignCast(ptr));
    v.append(t.allocator, .pop_clip) catch unreachable;
}

fn commands_contain(
    haystack: []const Command,
    needle: Command,
) bool {
    for (haystack) |item|
        if (std.meta.eql(item, needle))
            return true;

    return false;
}
