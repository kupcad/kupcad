const std = @import("std");
const ast = @import("../../../core/ast.zig");
const manifest = @import("../../../stdlib/manifest.zig");
const linter = @import("../linter.zig");
const LintRule = @import("rule.zig").LintRule;
const literals = @import("literals.zig");
const token_span = @import("../../../core/token_span.zig");
const token = @import("../../../core/token.zig");

/// Most edits between a misspelt keyword and the one it suggests (`sise` to `size` is 1).
const MAX_SUGGESTION_DISTANCE = 2;
/// Longest keyword the suggestion compares (the edit-distance row lives on the stack).
const MAX_KEYWORD_LEN = 64;

/// Flags a keyword a primitive doesn't take (`cube(sise: 3)`), which is an ArgumentError
/// when the script runs; built-ins can't be redefined, so the call can't mean another
/// `cube`. The keywords come from each primitive's Signature.
pub const UnknownKeywordRule = struct {
    pub const id = "unknown-keyword";
    pub const description = "A keyword a primitive doesn't take, such as cube(sise: 3)";

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
        if (call.receiver != .none) return;
        const method = tree.getString(call.method_name);
        const signature = manifest.signatureOf(method) orelse return;

        for (tree.getNamedArgs(call.args)) |arg| {
            if (arg.name == .none or arg.modifier != null) continue;
            const name = tree.getString(arg.name);
            if (accepts(signature.keywords, name)) continue;

            const name_token = literals.keywordToken(token_span.first(tree, arg.value)) orelse node.main_token;
            const loc = engine.getLoc(@intCast(name_token));
            const nearest = closest(signature.keywords, name);
            const fix: ?linter.Fix = if (nearest) |better| try renameFix(engine, loc, name, better) else null;
            if (nearest) |better| {
                try engine.reportFix(id, loc, fix, "{s} doesn't take '{s}'; did you mean '{s}'?", .{ method, name, better });
            } else {
                const accepted = try std.mem.join(engine.allocator, ", ", signature.keywords);
                defer engine.allocator.free(accepted);
                try engine.reportFix(id, loc, fix, "{s} doesn't take '{s}' (it takes: {s})", .{ method, name, accepted });
            }
        }
    }

    fn accepts(keywords: []const []const u8, name: []const u8) bool {
        for (keywords) |k| {
            if (std.mem.eql(u8, k, name)) return true;
        }
        return false;
    }

    /// The accepted keyword nearest `name`, if one is close enough and no other is as close.
    fn closest(keywords: []const []const u8, name: []const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        var best_distance: usize = MAX_SUGGESTION_DISTANCE + 1;
        var tied = false;
        for (keywords) |k| {
            const d = distance(k, name) orelse continue;
            if (d < best_distance) {
                best = k;
                best_distance = d;
                tied = false;
            } else if (d == best_distance) tied = true;
        }
        return if (tied) null else best;
    }

    /// Levenshtein distance; null for words too long to compare.
    fn distance(a: []const u8, b: []const u8) ?usize {
        if (a.len > MAX_KEYWORD_LEN or b.len > MAX_KEYWORD_LEN) return null;
        var row: [MAX_KEYWORD_LEN + 1]usize = undefined;
        for (0..b.len + 1) |j| row[j] = j;
        for (a, 1..) |ca, i| {
            var diagonal = row[0];
            row[0] = i;
            for (b, 1..) |cb, j| {
                const above = row[j];
                row[j] = @min(@min(row[j] + 1, row[j - 1] + 1), diagonal + @intFromBool(ca != cb));
                diagonal = above;
            }
        }
        return row[b.len];
    }

    /// Renames the keyword. Only offered: the nearest keyword is a guess at the intent.
    fn renameFix(engine: *linter.Linter, loc: token.Location, name: []const u8, better: []const u8) !?linter.Fix {
        // Only when the location really is the keyword (a splat or odd spacing moves it).
        const src = engine.sourceText();
        if (loc.offset + name.len > src.len or !std.mem.eql(u8, src[loc.offset..][0..name.len], name)) return null;
        const allocator = engine.allocator;
        const edits = try allocator.alloc(linter.Edit, 1);
        errdefer allocator.free(edits);
        edits[0] = .{ .offset = loc.offset, .length = @intCast(name.len), .replacement = try allocator.dupe(u8, better) };
        errdefer allocator.free(edits[0].replacement);
        return .{ .title = try std.fmt.allocPrint(allocator, "Use '{s}'", .{better}), .edits = edits, .safe = false };
    }
};
