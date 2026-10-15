const std = @import("std");
const ast = @import("../../../core/ast.zig");
const token = @import("../../../core/token.zig");
const token_span = @import("../../../core/token_span.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;
const literals = @import("literals.zig");

/// A round shape drawn with this few segments is a polygon on purpose (a hex nut trap, an
/// octagonal hole), not a coarse circle.
const MAX_FACETED_SEGMENTS = 8;
/// The shapes that take both `sides:` and `segments:`.
const FACETABLE = [_][]const u8{ "cylinder", "circle" };

/// Flags `cylinder(..., segments: 6)`: `segments` only says how finely a round shape is
/// drawn, so the hexagon is there on the mesh engine but not on B-Rep, which keeps the
/// cylinder round. `sides: 6` makes the hexagon on both.
pub const SegmentsAsSidesRule = struct {
    pub const id = "segments-as-sides";
    pub const description = "segments: 3 to 8 on a cylinder or circle, which is a polygon only on the mesh engine";

    pub fn rule(self: *@This()) LintRule {
        return .{
            .id = id,
            .ptr = self,
            .vtable = &.{
                .checkNode = checkNode,
            },
        };
    }

    fn checkNode(ptr: *anyopaque, engine: *linter.Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        _ = ptr;
        const node = tree.getNode(node_idx) orelse return;
        if (node.tag != .method_call) return;
        const call = tree.methodCall(node);
        if (call.receiver != .none or !isFacetable(tree.getString(call.method_name))) return;
        if (literals.keyword(tree, call, "sides") != null) return;
        const segments = literals.keyword(tree, call, "segments") orelse return;
        const n = literals.number(tree, segments.value) orelse return;
        if (n < 3 or n > MAX_FACETED_SEGMENTS or @trunc(n) != n) return;

        const name_token = literals.keywordToken(token_span.first(tree, segments.value)) orelse node.main_token;
        const loc = engine.getLoc(@intCast(name_token));
        // sides: can't be combined with round_r: or chamfer: (yet), so no fix with those.
        const plain = literals.keyword(tree, call, "round_r") == null and literals.keyword(tree, call, "chamfer") == null;
        const fix = if (plain) try sidesFix(engine, loc) else null;
        try engine.reportFix(id, loc, fix, "with segments: {d} this is a polygon only on the mesh engine (B-Rep keeps it round); use sides: {d} for one on both", .{ n, n });
    }

    fn isFacetable(method: []const u8) bool {
        for (FACETABLE) |name| {
            if (std.mem.eql(u8, name, method)) return true;
        }
        return false;
    }

    /// `segments:` becomes `sides:`. Only offered: on B-Rep it turns a round cylinder
    /// into a prism, which is the point, but not the same model.
    fn sidesFix(engine: *linter.Linter, loc: token.Location) !?linter.Fix {
        const src = engine.sourceText();
        if (loc.offset + "segments".len > src.len or !std.mem.eql(u8, src[loc.offset..][0.."segments".len], "segments")) return null;
        const allocator = engine.allocator;
        const edits = try allocator.alloc(linter.Edit, 1);
        errdefer allocator.free(edits);
        edits[0] = .{ .offset = loc.offset, .length = "segments".len, .replacement = try allocator.dupe(u8, "sides") };
        errdefer allocator.free(edits[0].replacement);
        return .{ .title = try allocator.dupe(u8, "Use sides:"), .edits = edits, .safe = false };
    }
};
