//! Checks a DAG node as the builder adds it, in Debug and test builds, as the bytecode
//! verifier checks a chunk: its payload lies inside the side tables, its operands are nodes
//! built before it (the DAG grows bottom up, so a later or missing index is a builder bug),
//! each operand is the kind of shape the operation takes (a sketch to extrude, a solid to
//! translate), its numbers are finite (the stdlib refuses the others, and the evaluator
//! relies on it), a polyhedron's faces name its own points, and its settings id exists.
//! The evaluator trusted all of this, so a mistake in one of the natives that build nodes
//! surfaced later as a kernel crash or a wrong part, far from where it was made.

const std = @import("std");
const dag = @import("dag.zig");

pub const Kind = enum { solid, sketch };

/// What kind of shape `tag` builds.
pub fn kindOf(tag: dag.DAGTag) Kind {
    return switch (tag) {
        .empty_solid, .cube, .cylinder, .sphere, .polyhedron_op, .concrete => .solid,
        .union_op, .batch_union_op, .difference_op, .intersection_op, .minkowski, .erode, .batch_hull_op, .hull => .solid,
        .translate, .rotate, .scale, .mirror, .transform_matrix, .trim_by_plane, .set_material, .set_name => .solid,
        .extrude, .revolve, .loft => .solid,
        .empty_sketch, .square, .rounded_square, .closed_path, .circle, .polygon, .polygons_even_odd => .sketch,
        .cs_union_op, .cs_difference_op, .cs_intersection_op, .cs_hull_op, .offset, .cs_transform, .cs_set_material, .cs_set_name => .sketch,
        .slice_op, .project_op => .sketch,
    };
}

/// The kind of shape `tag` takes for its operands.
pub fn operandKind(tag: dag.DAGTag) Kind {
    return switch (tag) {
        .cs_union_op, .cs_difference_op, .cs_intersection_op, .cs_hull_op, .extrude, .revolve, .offset, .cs_transform, .cs_set_material, .cs_set_name, .loft => .sketch,
        else => .solid,
    };
}

/// Why `node`, about to be added to `b`, is malformed; null when it is sound. The payload is
/// checked against its tag's layout (dag.layoutOf).
pub fn problem(b: *const dag.DAGBuilder, node: dag.DAGNode) ?[]const u8 {
    if (node.settings != 0 and node.settings > b.settings_table.items.len) return "its settings id names no settings";
    const extra = b.extra_data.items;
    const kind = operandKind(node.tag);
    return switch (dag.layoutOf(node.tag)) {
        .none => null,
        .numbers => |n| numbers(b, node.data, n),
        .operands => |n| operands(b, node.data, n, kind),
        .operand_list => {
            if (node.data >= extra.len) return "its operand count is outside extra_data";
            const count = extra[node.data];
            if (count == 0) return "it has no operands";
            return operands(b, node.data + 1, count, kind);
        },
        .target_numbers => |n| targetAndNumbers(b, node.data, kind, n),
        .target_value => {
            if (!fits(node.data, 2, extra.len)) return "its operand and value are outside extra_data";
            if ((node.tag == .set_name or node.tag == .cs_set_name) and extra[node.data + 1] >= b.part_names.items.len) return "its part name is outside the name table";
            return operands(b, node.data, 1, kind);
        },
        .loft => {
            if (!fits(node.data, 3, extra.len)) return "its operands are outside extra_data";
            if (operands(b, node.data, 2, kind)) |p| return p;
            return numbers(b, extra[node.data + 2], 1);
        },
        .polygon => {
            if (!fits(node.data, 2, extra.len)) return "its point range is outside extra_data";
            return numbers(b, extra[node.data], 2 * @as(usize, extra[node.data + 1]));
        },
        .path => {
            if (!fits(node.data, 2, extra.len)) return "its segment range is outside extra_data";
            return numbers(b, extra[node.data], dag.PATH_START_NUMBERS + dag.PATH_SEGMENT_NUMBERS * @as(usize, extra[node.data + 1]));
        },
        .polygons => {
            if (node.data >= extra.len) return "its contour count is outside extra_data";
            const count = extra[node.data];
            if (!fits(node.data + 1, 2 * @as(usize, count), extra.len)) return "its contours are outside extra_data";
            for (0..count) |i| {
                const at = node.data + 1 + 2 * i;
                if (numbers(b, extra[at], 2 * @as(usize, extra[at + 1]))) |p| return p;
            }
            const curves_at = b.polygonsCurvesAt(node.data);
            if (!fits(curves_at, 2, extra.len)) return "its curve count is outside extra_data";
            const curves = extra[curves_at];
            if (!fits(curves_at + 2, dag.CURVE_WORDS * @as(usize, curves), extra.len)) return "its curves are outside extra_data";
            if (numbers(b, extra[curves_at + 1], dag.CURVE_NUMBERS * @as(usize, curves))) |p| return p;
            for (0..curves) |i| {
                const words = extra[curves_at + 2 + dag.CURVE_WORDS * i ..][0..dag.CURVE_WORDS];
                if (words[0] >= count) return "a curve names a contour the node doesn't have";
                if (words[2] < 2 or !fits(words[1], words[2], extra[node.data + 2 + 2 * words[0]])) return "a curve names points its contour doesn't have";
            }
            return null;
        },
        .polyhedron => polyhedron(b, node.data),
        .concrete => if (node.data < b.concrete_leaves.items.len) null else "it names no concrete leaf",
    };
}

fn fits(start: usize, len: usize, available: usize) bool {
    return start <= available and len <= available - start;
}

/// `len` finite numbers at `start` of the numbers table.
fn numbers(b: *const dag.DAGBuilder, start: usize, len: usize) ?[]const u8 {
    if (!fits(start, len, b.numbers.items.len)) return "its numbers are outside the numbers table";
    for (b.numbers.items[start..][0..len]) |n| {
        if (!std.math.isFinite(n)) return "a number in it is NaN or infinite";
    }
    return null;
}

/// `count` operand indices at `start` of extra_data: earlier nodes of kind `kind`.
fn operands(b: *const dag.DAGBuilder, start: usize, count: usize, kind: Kind) ?[]const u8 {
    if (!fits(start, count, b.extra_data.items.len)) return "its operands are outside extra_data";
    for (b.extra_data.items[start..][0..count]) |child| {
        if (child >= b.nodes.items.len) return "an operand isn't a node built before it";
        if (kindOf(b.nodes.items[child].tag) != kind) {
            return if (kind == .solid) "an operand is a sketch where a solid belongs" else "an operand is a solid where a sketch belongs";
        }
    }
    return null;
}

/// A target of kind `kind` and the index of `len` numbers, at `start` of extra_data.
fn targetAndNumbers(b: *const dag.DAGBuilder, start: usize, kind: Kind, len: usize) ?[]const u8 {
    if (operands(b, start, 1, kind)) |p| return p;
    if (!fits(start, 2, b.extra_data.items.len)) return "its numbers index is outside extra_data";
    return numbers(b, b.extra_data.items[start + 1], len);
}

fn polyhedron(b: *const dag.DAGBuilder, start: usize) ?[]const u8 {
    const extra = b.extra_data.items;
    if (!fits(start, 6, extra.len)) return "its point and face ranges are outside extra_data";
    const pts_start = extra[start];
    const pts_len = extra[start + 1];
    const faces_start = extra[start + 2];
    const faces_len = extra[start + 3];
    if (!fits(pts_start, pts_len, b.poly_points.items.len)) return "its points are outside the points table";
    if (!fits(faces_start, faces_len, b.poly_faces.items.len)) return "its faces are outside the faces table";
    for (b.poly_points.items[pts_start..][0..pts_len]) |p| {
        for (p) |c| if (!std.math.isFinite(c)) return "a point in it is NaN or infinite";
    }
    for (b.poly_faces.items[faces_start..][0..faces_len]) |face| {
        for (face) |i| if (i >= pts_len) return "a face names a point it doesn't have";
    }
    return null;
}
