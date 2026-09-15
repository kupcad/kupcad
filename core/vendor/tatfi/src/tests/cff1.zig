const std = @import("std");
const ttf = @import("../lib.zig");
const t = std.testing;
const Unit = @import("main.zig").Unit;
const convert = @import("main.zig").convert;
const Table = ttf.tables.cff1;

test "unsupported_version" {
    const data = try convert(&.{
        .{ .unt8 = 10 }, // major version, only 1 is supported
        .{ .unt8 = 0 }, // minor version
        .{ .unt8 = 4 }, // header size
        .{ .unt8 = 0 }, // absolute offset
    });
    defer t.allocator.free(data);

    try t.expectError(error.ParseFail, Table.parse(data));
}

test "non_default_header_size" {
    const data = try convert(&.{
        // Header
        .{ .unt8 = 1 }, // major version
        .{ .unt8 = 0 }, // minor version
        .{ .unt8 = 8 }, // header size
        .{ .unt8 = 0 }, // absolute offset
        // no-op, should be skipped
        .{ .unt8 = 0 },
        .{ .unt8 = 0 },
        .{ .unt8 = 0 },
        .{ .unt8 = 0 },
        // Name INDEX
        .{ .unt16 = 0 }, // count
        // Top DICT
        // INDEX
        .{ .unt16 = 1 }, // count
        .{ .unt8 = 1 }, // offset size
        .{ .unt8 = 1 }, // index[0]
        .{ .unt8 = 3 }, // index[1]
        // Data
        .{ .cff_int = 21 },
        .{ .unt8 = @truncate(top_dict_operator.CHAR_STRINGS_OFFSET) },
        // String INDEX
        .{ .unt16 = 0 }, // count
        // Global Subroutines INDEX
        .{ .unt16 = 0 }, // count
        // CharString INDEX
        .{ .unt16 = 1 }, // count
        .{ .unt8 = 1 }, // offset size
        .{ .unt8 = 1 }, // index[0]
        .{ .unt8 = 4 }, // index[1]
        // Data
        .{ .cff_int = 10 },
        .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
        .{ .unt8 = operator.ENDCHAR },
    });
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    var writer: std.Io.Writer.Allocating = .init(t.allocator);
    defer writer.deinit();
    const builder = init_outline_builder(&writer.writer);

    const result = try table.outline(.{0}, builder);

    try t.expectEqualStrings("M 10 0 Z ", writer.written());
    try t.expectEqual(rect(10, 0, 10, 0), result);
}

test "move to" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 Z ",
        rect(10, 20, 10, 20),
    );
}

test "move_to_with_width" {
    try test_cs(
        &.{
            .{ .cff_int = 5 },
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 Z ",
        rect(10, 20, 10, 20),
    );
}

test "hmove_to" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 0 Z ",
        rect(10, 0, 10, 0),
    );
}

test "hmove_to_with_width" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 20 0 Z ",
        rect(20, 0, 20, 0),
    );
}

test "vmove_to" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .unt8 = operator.VERTICAL_MOVE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 0 10 Z ",
        rect(0, 10, 0, 10),
    );
}

test "vmove_to_with_width" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.VERTICAL_MOVE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 0 20 Z ",
        rect(0, 20, 0, 20),
    );
}

// Use only the first width.
test "two_vmove_to_with_width" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.VERTICAL_MOVE_TO },
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.VERTICAL_MOVE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 0 20 Z M 0 40 Z ",
        rect(0, 20, 0, 40),
    );
}

test "line_to" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .unt8 = operator.LINE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 L 40 60 Z ",
        rect(10, 20, 40, 60),
    );
}

test "line_to_with_multiple_pairs" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .cff_int = 50 },
            .{ .cff_int = 60 },
            .{ .unt8 = operator.LINE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 L 40 60 L 90 120 Z ",
        rect(10, 20, 90, 120),
    );
}

test "hline_to" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .unt8 = operator.HORIZONTAL_LINE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 L 40 20 Z ",
        rect(10, 20, 40, 20),
    );
}

test "hline_to_with_two_coords" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .unt8 = operator.HORIZONTAL_LINE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 L 40 20 L 40 60 Z ",
        rect(10, 20, 40, 60),
    );
}

test "hline_to_with_three_coords" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .cff_int = 50 },
            .{ .unt8 = operator.HORIZONTAL_LINE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 L 40 20 L 40 60 L 90 60 Z ",
        rect(10, 20, 90, 60),
    );
}

test "vline_to" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .unt8 = operator.VERTICAL_LINE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 L 10 50 Z ",
        rect(10, 20, 10, 50),
    );
}

test "vline_to_with_two_coords" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .unt8 = operator.VERTICAL_LINE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 L 10 50 L 50 50 Z ",
        rect(10, 20, 50, 50),
    );
}

test "vline_to_with_three_coords" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .cff_int = 50 },
            .{ .unt8 = operator.VERTICAL_LINE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 L 10 50 L 50 50 L 50 100 Z ",
        rect(10, 20, 50, 100),
    );
}

test "curve_to" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .cff_int = 50 },
            .{ .cff_int = 60 },
            .{ .cff_int = 70 },
            .{ .cff_int = 80 },
            .{ .unt8 = operator.CURVE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 C 40 60 90 120 160 200 Z ",
        rect(10, 20, 160, 200),
    );
}

test "curve_to_with_two_sets_of_coords" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .cff_int = 50 },
            .{ .cff_int = 60 },
            .{ .cff_int = 70 },
            .{ .cff_int = 80 },
            .{ .cff_int = 90 },
            .{ .cff_int = 100 },
            .{ .cff_int = 110 },
            .{ .cff_int = 120 },
            .{ .cff_int = 130 },
            .{ .cff_int = 140 },
            .{ .unt8 = operator.CURVE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 C 40 60 90 120 160 200 C 250 300 360 420 490 560 Z ",
        rect(10, 20, 490, 560),
    );
}

test "hh_curve_to" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .cff_int = 50 },
            .{ .cff_int = 60 },
            .{ .unt8 = operator.HH_CURVE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 C 40 20 80 70 140 70 Z ",
        rect(10, 20, 140, 70),
    );
}

test "hh_curve_to_with_y" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .cff_int = 50 },
            .{ .cff_int = 60 },
            .{ .cff_int = 70 },
            .{ .unt8 = operator.HH_CURVE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 C 50 50 100 110 170 110 Z ",
        rect(10, 20, 170, 110),
    );
}

test "vv_curve_to" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .cff_int = 50 },
            .{ .cff_int = 60 },
            .{ .unt8 = operator.VV_CURVE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 C 10 50 50 100 50 160 Z ",
        rect(10, 20, 50, 160),
    );
}

test "vv_curve_to_with_x" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .cff_int = 50 },
            .{ .cff_int = 60 },
            .{ .cff_int = 70 },
            .{ .unt8 = operator.VV_CURVE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 C 40 60 90 120 90 190 Z ",
        rect(10, 20, 90, 190),
    );
}

test "only_endchar" {
    const data = try gen_cff(&.{}, &.{}, &.{.{ .unt8 = operator.ENDCHAR }});
    defer t.allocator.free(data);
    const table = try Table.parse(data);

    var writer: std.Io.Writer.Allocating = .init(t.allocator);
    defer writer.deinit();
    const builder = init_outline_builder(&writer.writer);

    try t.expectError(error.ZeroBBox, table.outline(.{0}, builder));
}

test "local_subr" {
    try test_cs_with_subrs(
        &.{},
        &.{&.{
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .unt8 = operator.LINE_TO },
            .{ .unt8 = operator.RETURN },
        }},
        &.{
            .{ .cff_int = 10 },
            .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
            .{ .cff_int = 0 - 107 }, // subr index - subr bias
            .{ .unt8 = operator.CALL_LOCAL_SUBROUTINE },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 0 L 40 40 Z ",
        rect(10, 0, 40, 40),
    );
}

test "endchar_in_subr" {
    try test_cs_with_subrs(
        &.{},
        &.{&.{
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .unt8 = operator.LINE_TO },
            .{ .unt8 = operator.ENDCHAR },
        }},
        &.{
            .{ .cff_int = 10 },
            .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
            .{ .cff_int = 0 - 107 }, // subr index - subr bias
            .{ .unt8 = operator.CALL_LOCAL_SUBROUTINE },
        },
        "M 10 0 L 40 40 Z ",
        rect(10, 0, 40, 40),
    );
}

test "global_subr" {
    try test_cs_with_subrs(
        &.{&.{
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .unt8 = operator.LINE_TO },
            .{ .unt8 = operator.RETURN },
        }},
        &.{},
        &.{
            .{ .cff_int = 10 },
            .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
            .{ .cff_int = 0 - 107 }, // subr index - subr bias
            .{ .unt8 = operator.CALL_GLOBAL_SUBROUTINE },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 0 L 40 40 Z ",
        rect(10, 0, 40, 40),
    );
}

// `dotsection` (12 0) is a deprecated hinting operator that Adobe's
// Type 1 to Type 2 conversion preserves on dot-bearing glyphs (i, j, !).
// It takes no arguments and must be skipped, not rejected, otherwise
// such glyphs lose their outlines entirely.
test "dotsection_is_ignored" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .unt8 = 12 },
            .{ .unt8 = 0 }, // dotsection
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .unt8 = operator.LINE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 L 40 60 Z ",
        rect(10, 20, 40, 60),
    );
}

// `dotsection` is a pure no-op like in read-fonts and FreeType: operands
// already on the argument stack must survive it untouched.
test "dotsection_preserves_stack" {
    try test_cs(
        &.{
            .{ .cff_int = 10 },
            .{ .cff_int = 20 },
            .{ .unt8 = operator.MOVE_TO },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .unt8 = 12 },
            .{ .unt8 = 0 }, // dotsection
            .{ .unt8 = operator.LINE_TO },
            .{ .unt8 = operator.ENDCHAR },
        },
        "M 10 20 L 40 60 Z ",
        rect(10, 20, 40, 60),
    );
}

test "reserved_operator" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .unt8 = 2 },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidOperator);
}

test "line_to_without_move_to" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .cff_int = 20 },
        .{ .unt8 = operator.LINE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.MissingMoveTo);
}

test "move_to_with_too_many_coords" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .cff_int = 10 },
        .{ .cff_int = 10 },
        .{ .cff_int = 20 },
        .{ .unt8 = operator.MOVE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "move_to_with_not_enough_coords" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .unt8 = operator.MOVE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "hmove_to_with_too_many_coords" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .cff_int = 10 },
        .{ .cff_int = 10 },
        .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "hmove_to_with_not_enough_coords" {
    try test_cs_err(&.{
        .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "vmove_to_with_too_many_coords" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .cff_int = 10 },
        .{ .cff_int = 10 },
        .{ .unt8 = operator.VERTICAL_MOVE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "vmove_to_with_not_enough_coords" {
    try test_cs_err(&.{
        .{ .unt8 = operator.VERTICAL_MOVE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "line_to_with_single_coord" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .cff_int = 20 },
        .{ .unt8 = operator.MOVE_TO },
        .{ .cff_int = 30 },
        .{ .unt8 = operator.LINE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "line_to_with_odd_number_of_coord" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .cff_int = 20 },
        .{ .unt8 = operator.MOVE_TO },
        .{ .cff_int = 30 },
        .{ .cff_int = 40 },
        .{ .cff_int = 50 },
        .{ .unt8 = operator.LINE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "hline_to_without_coords" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .cff_int = 20 },
        .{ .unt8 = operator.MOVE_TO },
        .{ .unt8 = operator.HORIZONTAL_LINE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "vline_to_without_coords" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .cff_int = 20 },
        .{ .unt8 = operator.MOVE_TO },
        .{ .unt8 = operator.VERTICAL_LINE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "curve_to_with_invalid_num_of_coords_1" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .cff_int = 20 },
        .{ .unt8 = operator.MOVE_TO },
        .{ .cff_int = 30 },
        .{ .cff_int = 40 },
        .{ .cff_int = 50 },
        .{ .cff_int = 60 },
        .{ .unt8 = operator.CURVE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "curve_to_with_invalid_num_of_coords_2" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .cff_int = 20 },
        .{ .unt8 = operator.MOVE_TO },
        .{ .cff_int = 30 },
        .{ .cff_int = 40 },
        .{ .cff_int = 50 },
        .{ .cff_int = 60 },
        .{ .cff_int = 70 },
        .{ .cff_int = 80 },
        .{ .cff_int = 90 },
        .{ .unt8 = operator.CURVE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "hh_curve_to_with_not_enough_coords" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .cff_int = 20 },
        .{ .unt8 = operator.MOVE_TO },
        .{ .cff_int = 30 },
        .{ .cff_int = 40 },
        .{ .cff_int = 50 },
        .{ .unt8 = operator.HH_CURVE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "hh_curve_to_with_too_many_coords" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .cff_int = 20 },
        .{ .unt8 = operator.MOVE_TO },
        .{ .cff_int = 30 },
        .{ .cff_int = 40 },
        .{ .cff_int = 50 },
        .{ .cff_int = 30 },
        .{ .cff_int = 40 },
        .{ .cff_int = 50 },
        .{ .unt8 = operator.HH_CURVE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "vv_curve_to_with_not_enough_coords" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .cff_int = 20 },
        .{ .unt8 = operator.MOVE_TO },
        .{ .cff_int = 30 },
        .{ .cff_int = 40 },
        .{ .cff_int = 50 },
        .{ .unt8 = operator.VV_CURVE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "vv_curve_to_with_too_many_coords" {
    try test_cs_err(&.{
        .{ .cff_int = 10 },
        .{ .cff_int = 20 },
        .{ .unt8 = operator.MOVE_TO },
        .{ .cff_int = 30 },
        .{ .cff_int = 40 },
        .{ .cff_int = 50 },
        .{ .cff_int = 30 },
        .{ .cff_int = 40 },
        .{ .cff_int = 50 },
        .{ .unt8 = operator.VV_CURVE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.InvalidArgumentsStackLength);
}

test "multiple_endchar" {
    try test_cs_err(&.{
        .{ .unt8 = operator.ENDCHAR },
        .{ .unt8 = operator.ENDCHAR },
    }, error.DataAfterEndChar);
}

test "seac_with_not_enough_data" {
    try test_cs_err(&.{
        .{ .cff_int = 0 },
        .{ .cff_int = 0 },
        .{ .cff_int = 0 },
        .{ .cff_int = 0 },
        .{ .unt8 = operator.ENDCHAR },
    }, error.NestingLimitReached);
}

test "operands_overflow" {
    try test_cs_err(&.{
        .{ .cff_int = 0 },
        .{ .cff_int = 1 },
        .{ .cff_int = 2 },
        .{ .cff_int = 3 },
        .{ .cff_int = 4 },
        .{ .cff_int = 5 },
        .{ .cff_int = 6 },
        .{ .cff_int = 7 },
        .{ .cff_int = 8 },
        .{ .cff_int = 9 },
        .{ .cff_int = 0 },
        .{ .cff_int = 1 },
        .{ .cff_int = 2 },
        .{ .cff_int = 3 },
        .{ .cff_int = 4 },
        .{ .cff_int = 5 },
        .{ .cff_int = 6 },
        .{ .cff_int = 7 },
        .{ .cff_int = 8 },
        .{ .cff_int = 9 },
        .{ .cff_int = 0 },
        .{ .cff_int = 1 },
        .{ .cff_int = 2 },
        .{ .cff_int = 3 },
        .{ .cff_int = 4 },
        .{ .cff_int = 5 },
        .{ .cff_int = 6 },
        .{ .cff_int = 7 },
        .{ .cff_int = 8 },
        .{ .cff_int = 9 },
        .{ .cff_int = 0 },
        .{ .cff_int = 1 },
        .{ .cff_int = 2 },
        .{ .cff_int = 3 },
        .{ .cff_int = 4 },
        .{ .cff_int = 5 },
        .{ .cff_int = 6 },
        .{ .cff_int = 7 },
        .{ .cff_int = 8 },
        .{ .cff_int = 9 },
        .{ .cff_int = 0 },
        .{ .cff_int = 1 },
        .{ .cff_int = 2 },
        .{ .cff_int = 3 },
        .{ .cff_int = 4 },
        .{ .cff_int = 5 },
        .{ .cff_int = 6 },
        .{ .cff_int = 7 },
        .{ .cff_int = 8 },
        .{ .cff_int = 9 },
    }, error.ArgumentsStackLimitReached);
}

test "operands_overflow_with_4_byte_ints" {
    try test_cs_err(&.{
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
        .{ .cff_int = 30000 },
    }, error.ArgumentsStackLimitReached);
}

test "bbox_overflow" {
    try test_cs_err(&.{
        .{ .cff_int = 32767 },
        .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
        .{ .cff_int = 32767 },
        .{ .unt8 = operator.HORIZONTAL_LINE_TO },
        .{ .unt8 = operator.ENDCHAR },
    }, error.BboxOverflow);
}

test "endchar_in_subr_with_extra_data_1" {
    const data = try gen_cff(
        &.{},
        &.{&.{
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .unt8 = operator.LINE_TO },
            .{ .unt8 = operator.ENDCHAR },
        }},
        &.{
            .{ .cff_int = 10 },
            .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
            .{ .cff_int = 0 - 107 }, // subr index - subr bias
            .{ .unt8 = operator.CALL_LOCAL_SUBROUTINE },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .unt8 = operator.LINE_TO },
        },
    );
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    var writer: std.Io.Writer.Allocating = .init(t.allocator);
    defer writer.deinit();
    const builder = init_outline_builder(&writer.writer);

    const res = table.outline(.{0}, builder);
    try t.expectError(error.DataAfterEndChar, res);
}

test "endchar_in_subr_with_extra_data_2" {
    const data = try gen_cff(
        &.{},
        &.{&.{
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .unt8 = operator.LINE_TO },
            .{ .unt8 = operator.ENDCHAR },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .unt8 = operator.LINE_TO },
        }},
        &.{
            .{ .cff_int = 10 },
            .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
            .{ .cff_int = 0 - 107 }, // subr index - subr bias
            .{ .unt8 = operator.CALL_LOCAL_SUBROUTINE },
        },
    );
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    var writer: std.Io.Writer.Allocating = .init(t.allocator);
    defer writer.deinit();
    const builder = init_outline_builder(&writer.writer);

    const res = table.outline(.{0}, builder);
    try t.expectError(error.DataAfterEndChar, res);
}

test "subr_without_return" {
    const data = try gen_cff(
        &.{},
        &.{&.{
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .unt8 = operator.LINE_TO },
            .{ .unt8 = operator.ENDCHAR },
            .{ .cff_int = 30 },
            .{ .cff_int = 40 },
            .{ .unt8 = operator.LINE_TO },
        }},
        &.{
            .{ .cff_int = 10 },
            .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
            .{ .cff_int = 0 - 107 }, // subr index - subr bias
            .{ .unt8 = operator.CALL_LOCAL_SUBROUTINE },
        },
    );
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    var writer: std.Io.Writer.Allocating = .init(t.allocator);
    defer writer.deinit();
    const builder = init_outline_builder(&writer.writer);

    const res = table.outline(.{0}, builder);
    try t.expectError(error.DataAfterEndChar, res);
}

test "recursive_local_subr" {
    const data = try gen_cff(
        &.{},
        &.{&.{
            .{ .cff_int = 0 - 107 }, // subr index - subr bias
            .{ .unt8 = operator.CALL_LOCAL_SUBROUTINE },
        }},
        &.{
            .{ .cff_int = 10 },
            .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
            .{ .cff_int = 0 - 107 }, // subr index - subr bias
            .{ .unt8 = operator.CALL_LOCAL_SUBROUTINE },
        },
    );
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    var writer: std.Io.Writer.Allocating = .init(t.allocator);
    defer writer.deinit();
    const builder = init_outline_builder(&writer.writer);

    const res = table.outline(.{0}, builder);
    try t.expectError(error.NestingLimitReached, res);
}

test "recursive_global_subr" {
    const data = try gen_cff(
        &.{&.{
            .{ .cff_int = 0 - 107 }, // subr index - subr bias
            .{ .unt8 = operator.CALL_GLOBAL_SUBROUTINE },
        }},
        &.{},
        &.{
            .{ .cff_int = 10 },
            .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
            .{ .cff_int = 0 - 107 }, // subr index - subr bias
            .{ .unt8 = operator.CALL_GLOBAL_SUBROUTINE },
        },
    );
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    var writer: std.Io.Writer.Allocating = .init(t.allocator);
    defer writer.deinit();
    const builder = init_outline_builder(&writer.writer);

    const res = table.outline(.{0}, builder);
    try t.expectError(error.NestingLimitReached, res);
}

test "recursive_mixed_subr" {
    const data = try gen_cff(
        &.{&.{
            .{ .cff_int = 0 - 107 }, // subr index - subr bias
            .{ .unt8 = operator.CALL_LOCAL_SUBROUTINE },
        }},
        &.{&.{
            .{ .cff_int = 0 - 107 }, // subr index - subr bias
            .{ .unt8 = operator.CALL_GLOBAL_SUBROUTINE },
        }},
        &.{
            .{ .cff_int = 10 },
            .{ .unt8 = operator.HORIZONTAL_MOVE_TO },
            .{ .cff_int = 0 - 107 }, // subr index - subr bias
            .{ .unt8 = operator.CALL_GLOBAL_SUBROUTINE },
        },
    );
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    var writer: std.Io.Writer.Allocating = .init(t.allocator);
    defer writer.deinit();
    const builder = init_outline_builder(&writer.writer);

    const res = table.outline(.{0}, builder);
    try t.expectError(error.NestingLimitReached, res);
}

test "zero_char_string_offset" {
    const data = try convert(&.{
        // Header
        .{ .unt8 = 1 }, // major version
        .{ .unt8 = 0 }, // minor version
        .{ .unt8 = 4 }, // header size
        .{ .unt8 = 0 }, // absolute offset
        // Name INDEX
        .{ .unt16 = 0 }, // count
        // Top DICT
        // INDEX
        .{ .unt16 = 1 }, // count
        .{ .unt8 = 1 }, // offset size
        .{ .unt8 = 1 }, // index[0]
        .{ .unt8 = 3 }, // index[1]
        // Data
        .{ .cff_int = 0 }, // zero offset!
        .{ .unt8 = @truncate(top_dict_operator.CHAR_STRINGS_OFFSET) },
    });
    defer t.allocator.free(data);

    try t.expectError(error.ParseFail, Table.parse(data));
}

test "invalid_char_string_offset" {
    const data = try convert(&.{
        // Header
        .{ .unt8 = 1 }, // major version
        .{ .unt8 = 0 }, // minor version
        .{ .unt8 = 4 }, // header size
        .{ .unt8 = 0 }, // absolute offset
        // Name INDEX
        .{ .unt16 = 0 }, // count
        // Top DICT
        // INDEX
        .{ .unt16 = 1 }, // count
        .{ .unt8 = 1 }, // offset size
        .{ .unt8 = 1 }, // index[0]
        .{ .unt8 = 3 }, // index[1]
        // Data
        .{ .cff_int = 2 }, // invalid offset!
        .{ .unt8 = @truncate(top_dict_operator.CHAR_STRINGS_OFFSET) },
    });
    defer t.allocator.free(data);

    try t.expectError(error.ParseFail, Table.parse(data));
}

// [RazrFalcon] TODO: return from main
// [RazrFalcon] TODO: return without endchar
// [RazrFalcon] TODO: data after return
// [RazrFalcon] TODO: recursive subr
// [RazrFalcon] TODO: HORIZONTAL_STEM
// [RazrFalcon] TODO: VERTICAL_STEM
// [RazrFalcon] TODO: HORIZONTAL_STEM_HINT_MASK
// [RazrFalcon] TODO: HINT_MASK
// [RazrFalcon] TODO: COUNTER_MASK
// [RazrFalcon] TODO: VERTICAL_STEM_HINT_MASK
// [RazrFalcon] TODO: CURVE_LINE
// [RazrFalcon] TODO: LINE_CURVE
// [RazrFalcon] TODO: VH_CURVE_TO
// [RazrFalcon] TODO: HFLEX
// [RazrFalcon] TODO: FLEX
// [RazrFalcon] TODO: HFLEX1
// [RazrFalcon] TODO: FLEX1

// HELPERS ===

fn test_cs_err(
    values: []const Unit,
    err: anyerror,
) !void {
    const data = try gen_cff(&.{}, &.{}, values);
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    var writer: std.Io.Writer.Allocating = .init(t.allocator);
    defer writer.deinit();
    const builder = init_outline_builder(&writer.writer);

    const res = table.outline(.{0}, builder);
    try t.expectError(err, res);
}

fn test_cs(
    values: []const Unit,
    path: []const u8,
    rect_res: ttf.Rect,
) !void {
    try test_cs_with_subrs(&.{}, &.{}, values, path, rect_res);
}

fn test_cs_with_subrs(
    glob: []const []const Unit,
    loc: []const []const Unit,
    values: []const Unit,
    path: []const u8,
    rect_res: ttf.Rect,
) !void {
    const data = try gen_cff(glob, loc, values);
    defer t.allocator.free(data);

    const table = try Table.parse(data);
    var writer: std.Io.Writer.Allocating = .init(t.allocator);
    defer writer.deinit();
    const builder = init_outline_builder(&writer.writer);

    const result = try table.outline(.{0}, builder);

    try t.expectEqualStrings(path, writer.written());
    try t.expectEqual(rect_res, result);
}

fn gen_cff(
    global_subrs: []const []const Unit,
    local_subrs: []const []const Unit,
    chars: []const Unit,
) ![]const u8 {
    const EMPTY_INDEX_SIZE: usize = 2;
    const INDEX_HEADER_SIZE: usize = 5;

    std.debug.assert(global_subrs.len <= 1);
    std.debug.assert(local_subrs.len <= 1);

    const global_subrs_data = gsd: {
        var writer: std.Io.Writer.Allocating = .init(t.allocator);
        defer writer.deinit();

        for (global_subrs) |v1| for (v1) |v2|
            try writer.writer.print("{f}", .{v2});

        break :gsd try writer.toOwnedSlice();
    };
    defer t.allocator.free(global_subrs_data);

    const local_subrs_data = gsd: {
        var writer: std.Io.Writer.Allocating = .init(t.allocator);
        defer writer.deinit();

        for (local_subrs) |v1| for (v1) |v2|
            try writer.writer.print("{f}", .{v2});

        break :gsd try writer.toOwnedSlice();
    };
    defer t.allocator.free(local_subrs_data);

    const chars_data = try convert(chars);
    defer t.allocator.free(chars_data);

    std.debug.assert(global_subrs_data.len < 255);
    std.debug.assert(local_subrs_data.len < 255);
    std.debug.assert(chars_data.len < 255);

    var writer_state: std.Io.Writer.Allocating = .init(t.allocator);
    defer writer_state.deinit();

    var w = &writer_state.writer;
    // Header
    try w.print("{f}", .{Unit{ .unt8 = 1 }}); // major version
    try w.print("{f}", .{Unit{ .unt8 = 0 }}); // minor version
    try w.print("{f}", .{Unit{ .unt8 = 4 }}); // header size
    try w.print("{f}", .{Unit{ .unt8 = 0 }}); // absolute offset

    // Name INDEX
    try w.print("{f}", .{Unit{ .unt16 = 0 }}); // count

    // Top DICT
    // INDEX
    try w.print("{f}", .{Unit{ .unt16 = 1 }}); // count
    try w.print("{f}", .{Unit{ .unt8 = 1 }}); // offset size
    try w.print("{f}", .{Unit{ .unt8 = 1 }}); // index[0]

    const top_dict_idx2: u8 = if (local_subrs.len == 0) 3 else 6;
    try w.print("{f}", .{Unit{ .unt8 = top_dict_idx2 }}); // index[1]

    // Item 0
    const charstr_offset = o: {
        var charstr_offset: usize = w.end + 2; // [ARS] This should be the offset of the current cursor.
        charstr_offset += EMPTY_INDEX_SIZE; // String INDEX

        // Global Subroutines INDEX
        if (global_subrs_data.len != 0)
            charstr_offset += INDEX_HEADER_SIZE + global_subrs_data.len
        else
            charstr_offset += EMPTY_INDEX_SIZE;

        if (local_subrs_data.len != 0)
            charstr_offset += 3;

        break :o charstr_offset;
    };

    try w.print("{f}", .{Unit{ .cff_int = std.math.cast(i32, charstr_offset).? }}); // index[1]
    try w.print("{f}", .{Unit{ .unt8 = @truncate(top_dict_operator.CHAR_STRINGS_OFFSET) }}); // index[1]

    if (local_subrs_data.len != 0) {
        // Item 1
        try w.print("{f}", .{Unit{ .cff_int = 2 }}); // length
        try w.print("{f}", .{Unit{ .cff_int = std.math.cast(i32, charstr_offset + INDEX_HEADER_SIZE + chars_data.len).? }}); // offset
        try w.print("{f}", .{Unit{ .unt8 = @truncate(top_dict_operator.PRIVATE_DICT_SIZE_AND_OFFSET) }});
    }

    // String INDEX
    try w.print("{f}", .{Unit{ .unt16 = 0 }}); // count

    // Global Subroutines INDEX
    if (global_subrs_data.len == 0) {
        try w.print("{f}", .{Unit{ .unt16 = 0 }}); // count
    } else {
        try w.print("{f}", .{Unit{ .unt16 = 1 }}); // count
        try w.print("{f}", .{Unit{ .unt8 = 1 }}); // offset size
        try w.print("{f}", .{Unit{ .unt8 = 1 }}); // index[0]
        try w.print("{f}", .{Unit{ .unt8 = @truncate(global_subrs_data.len + 1) }}); // index[1]

        try w.writeAll(global_subrs_data);
    }

    // CharString INDEX
    try w.print("{f}", .{Unit{ .unt16 = 1 }}); // count
    try w.print("{f}", .{Unit{ .unt8 = 1 }}); // offset size
    try w.print("{f}", .{Unit{ .unt8 = 1 }}); // index[0]
    try w.print("{f}", .{Unit{ .unt8 = @truncate(chars_data.len + 1) }}); // index[1]
    try w.writeAll(chars_data);

    if (local_subrs_data.len != 0) {
        // The local subroutines offset is relative to the beginning of the Private DICT data.

        // Private DICT
        try w.print("{f}", .{Unit{ .cff_int = 2 }});
        try w.print("{f}", .{Unit{ .unt8 = @truncate(private_dict_operator.LOCAL_SUBROUTINES_OFFSET) }});

        // Local Subroutines INDEX
        try w.print("{f}", .{Unit{ .unt16 = 1 }}); // count
        try w.print("{f}", .{Unit{ .unt8 = 1 }}); // offset size
        try w.print("{f}", .{Unit{ .unt8 = 1 }}); // index[0]
        try w.print("{f}", .{Unit{ .unt8 = @truncate(local_subrs_data.len + 1) }}); // index[1]
        try w.writeAll(local_subrs_data);
    }

    return try writer_state.toOwnedSlice();
}

fn rect(x_min: i16, y_min: i16, x_max: i16, y_max: i16) ttf.Rect {
    return .{ .x_min = x_min, .y_min = y_min, .x_max = x_max, .y_max = y_max };
}

pub fn init_outline_builder(
    writer: *std.Io.Writer,
) ttf.OutlineBuilder {
    return .{ .ptr = writer, .vtable = .{
        .move_to = move_to,
        .line_to = line_to,
        .curve_to = curve_to,
        .quad_to = quad_to,
        .close = close,
    } };
}

fn move_to(
    self: *anyopaque,
    x: f32,
    y: f32,
) void {
    const w: *std.Io.Writer = @ptrCast(@alignCast(self));
    w.print("M {d} {d} ", .{ x, y }) catch unreachable;
    return;
}

fn line_to(
    self: *anyopaque,
    x: f32,
    y: f32,
) void {
    const w: *std.Io.Writer = @ptrCast(@alignCast(self));
    w.print("L {d} {d} ", .{ x, y }) catch unreachable;
    return;
}

fn quad_to(
    self: *anyopaque,
    x1: f32,
    y1: f32,
    x: f32,
    y: f32,
) void {
    const w: *std.Io.Writer = @ptrCast(@alignCast(self));
    w.print(
        "Q {d} {d} {d} {d} ",
        .{ x1, y1, x, y },
    ) catch unreachable;
    return;
}

fn curve_to(
    self: *anyopaque,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    x: f32,
    y: f32,
) void {
    const w: *std.Io.Writer = @ptrCast(@alignCast(self));
    w.print(
        "C {d} {d} {d} {d} {d} {d} ",
        .{ x1, y1, x2, y2, x, y },
    ) catch unreachable;
    return;
}

fn close(self: *anyopaque) void {
    const w: *std.Io.Writer = @ptrCast(@alignCast(self));
    w.writeAll("Z ") catch unreachable;
    return;
}

const operator = struct {
    pub const HORIZONTAL_STEM: u8 = 1;
    pub const VERTICAL_STEM: u8 = 3;
    pub const VERTICAL_MOVE_TO: u8 = 4;
    pub const LINE_TO: u8 = 5;
    pub const HORIZONTAL_LINE_TO: u8 = 6;
    pub const VERTICAL_LINE_TO: u8 = 7;
    pub const CURVE_TO: u8 = 8;
    pub const CALL_LOCAL_SUBROUTINE: u8 = 10;
    pub const RETURN: u8 = 11;
    pub const ENDCHAR: u8 = 14;
    pub const HORIZONTAL_STEM_HINT_MASK: u8 = 18;
    pub const HINT_MASK: u8 = 19;
    pub const COUNTER_MASK: u8 = 20;
    pub const MOVE_TO: u8 = 21;
    pub const HORIZONTAL_MOVE_TO: u8 = 22;
    pub const VERTICAL_STEM_HINT_MASK: u8 = 23;
    pub const CURVE_LINE: u8 = 24;
    pub const LINE_CURVE: u8 = 25;
    pub const VV_CURVE_TO: u8 = 26;
    pub const HH_CURVE_TO: u8 = 27;
    pub const SHORT_INT: u8 = 28;
    pub const CALL_GLOBAL_SUBROUTINE: u8 = 29;
    pub const VH_CURVE_TO: u8 = 30;
    pub const HV_CURVE_TO: u8 = 31;
    pub const HFLEX: u8 = 34;
    pub const FLEX: u8 = 35;
    pub const HFLEX1: u8 = 36;
    pub const FLEX1: u8 = 37;
    pub const FIXED_16_16: u8 = 255;
};

const top_dict_operator = struct {
    pub const CHARSET_OFFSET: u16 = 15;
    pub const CHAR_STRINGS_OFFSET: u16 = 17;
    pub const PRIVATE_DICT_SIZE_AND_OFFSET: u16 = 18;
    pub const ROS: u16 = 1230;
    pub const FD_ARRAY: u16 = 1236;
    pub const FD_SELECT: u16 = 1237;
};

const private_dict_operator = struct {
    pub const LOCAL_SUBROUTINES_OFFSET: u16 = 19;
};
