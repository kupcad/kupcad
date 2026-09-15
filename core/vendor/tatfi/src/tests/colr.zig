const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const convert = @import("main.zig").convert;
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
