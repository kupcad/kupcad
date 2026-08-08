const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");
const visitor = @import("visitor.zig");

const CounterContext = struct {
    count: usize = 0,

    pub fn enterNode(self: *CounterContext, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        _ = tree;
        _ = node_idx;
        self.count += 1;
    }
};

test "AstVisitor: deeply traverses mathematical nodes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = ast.Builder.init(arena.allocator());
    defer b.deinit();

    const n1 = try b.number("10", 0);
    const n2 = try b.number("20", 0);
    const bin = try b.binary(.add, n1, n2, 0);

    var ctx = CounterContext{};
    try visitor.walk(CounterContext, &ctx, &b.tree, bin);

    // 1 binary node + 2 number nodes = 3 visits
    try testing.expectEqual(@as(usize, 3), ctx.count);
}
