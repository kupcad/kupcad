//! The trace sink receives the body after each phase, as JSON that loads back; without a
//! sink nothing is dumped.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const primitives = @import("../construct/primitives.zig");
const transform = @import("../construct/transform.zig");
const body_json = @import("body_json.zig");
const trace = @import("trace.zig");

const tol = Tolerance.fromZone(1e-5);

/// A sink keeping every phase's names and text.
const Collector = struct {
    const Entry = struct { operation: []u8, phase: []u8, text: []u8 };
    entries: std.ArrayList(Entry) = .empty,

    fn write(context: ?*anyopaque, operation: []const u8, phase: []const u8, body_json_text: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(context.?));
        self.entries.append(testing.allocator, .{
            .operation = testing.allocator.dupe(u8, operation) catch @panic("oom"),
            .phase = testing.allocator.dupe(u8, phase) catch @panic("oom"),
            .text = testing.allocator.dupe(u8, body_json_text) catch @panic("oom"),
        }) catch @panic("oom");
    }

    fn deinit(self: *Collector) void {
        for (self.entries.items) |e| {
            testing.allocator.free(e.operation);
            testing.allocator.free(e.phase);
            testing.allocator.free(e.text);
        }
        self.entries.deinit(testing.allocator);
    }

    fn sink(self: *Collector) diagnostics.Trace {
        return .{ .context = self, .write = write };
    }
};

test "trace: a transform reports its phases as bodies that load back; no sink, no dump" {
    var diag = diagnostics.Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var box = try primitives.box(testing.allocator, tol, 1, 2, 3, false, &diag);
    defer box.deinit();
    var collector = Collector{};
    defer collector.deinit();
    const affine = mat.Affine.translate(.{ 5, 0, 0 });

    var moved = try transform.transform(testing.allocator, &box, &affine, .{ .trace = collector.sink() }, &diag);
    defer moved.deinit();
    try testing.expectEqual(@as(usize, 3), collector.entries.items.len);
    try testing.expectEqualStrings("transform", collector.entries.items[0].operation);
    // The arguments first, as JSON of plain data, for a replay
    try testing.expectEqualStrings("arguments", collector.entries.items[0].phase);
    try testing.expect(std.mem.indexOf(u8, collector.entries.items[0].text, "\"translation\"") != null);
    try testing.expect(std.mem.indexOf(u8, collector.entries.items[0].text, "5") != null);
    try testing.expectEqualStrings("mapped", collector.entries.items[1].phase);
    try testing.expectEqualStrings("checked", collector.entries.items[2].phase);
    // Each phase after the arguments is a body; the last is the result
    for (collector.entries.items[1..]) |e| {
        var loaded = try body_json.load(testing.allocator, e.text);
        loaded.deinit();
    }
    const result = try body_json.dump(testing.allocator, &moved);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(result, collector.entries.items[2].text);

    // `phase` without a sink is nothing
    try trace.phase(testing.allocator, &.{}, &box, "none", "none");
    try trace.arguments(testing.allocator, &.{}, "none", .{ .n = 1 });
    try testing.expectEqual(@as(usize, 3), collector.entries.items.len);
}
