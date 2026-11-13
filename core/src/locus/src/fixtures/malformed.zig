//! The malformed corpus (M4's exit; research/opengeometry.md §6, after OpenGeometry's
//! verdict files): bodies as JSON, each broken in one way (`malformed/<name>.json`), and
//! what must be said of each (`malformed/<name>.verdict.json`): the reader refuses it, or
//! the checker's first finding at a level. Made from the defects topology/check_test.zig
//! builds in code (`zig build test -Dupdate-snapshots` rewrites them), read back by it, and
//! the body reader's fuzz target's seeds. Embedded, so no test touches the file system.

/// A case: its name, its body as JSON, its verdict as JSON.
pub const Case = struct { name: []const u8, body: []const u8, verdict: []const u8 };

/// The cases, in check_test.zig's `MALFORMED` order (a test holds the two to one list).
pub const NAMES = [_][]const u8{
    "point_index_past_table",
    "version_unknown",
    "curve_kind_unknown",
    "next_prev_not_reciprocal",
    "partner_not_reciprocal",
    "partner_same_sense",
    "loop_not_connected",
    "loop_not_closed",
    "loop_empty",
    "coedge_loop_disagrees",
    "edge_three_coedges",
    "degenerate_edge_vertices",
    "edge_range_reversed",
    "vertex_coedge_not_leaving",
    "face_shell_disagrees",
    "loop_face_disagrees",
    "face_without_loop",
    "face_shell_count",
    "euler_poincare",
    "open_edge_in_closed_shell",
    "vertex_off_curve",
    "edge_too_short",
    "too_large_for_zone",
    "too_large_far_out",
    "gap_too_large",
    "edge_off_surface",
    "loop_winding",
    "shell_inside_out",
    "vertices_too_close",
    "hole_outside_outer",
};

pub const CASES = blk: {
    var cases: [NAMES.len]Case = undefined;
    for (NAMES, &cases) |name, *c| c.* = .{
        .name = name,
        .body = @embedFile("malformed/" ++ name ++ ".json"),
        .verdict = @embedFile("malformed/" ++ name ++ ".verdict.json"),
    };
    break :blk cases;
};
