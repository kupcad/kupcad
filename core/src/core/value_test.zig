const std = @import("std");
const testing = std.testing;
const value = @import("value.zig");

test "Value: memory size is strictly 8 bytes" {
    // This is the most critical assertion. If this fails, the VM loses
    // its ability to pass values cleanly in registers.
    try testing.expectEqual(@as(usize, 8), @sizeOf(value.Value));
}

test "Value: correct initialization and retrieval" {
    const num = value.Value.initNumber(3.14);
    try testing.expect(num.isNumber());
    try testing.expectEqual(@as(f64, 3.14), num.asNumber());

    const b = value.Value.initBool(true);
    try testing.expect(b.isBool());
    try testing.expectEqual(true, b.asBool());

    const n = value.Value.initNil();
    try testing.expect(n.isNil());
}

test "Value: equality works across all types" {
    const num1 = value.Value.initNumber(42.0);
    const num2 = value.Value.initNumber(42.0);
    const num3 = value.Value.initNumber(43.0);

    try testing.expect(value.Value.eql(num1, num2));
    try testing.expect(!value.Value.eql(num1, num3));

    const b1 = value.Value.initBool(true);
    const b2 = value.Value.initBool(false);

    try testing.expect(!value.Value.eql(num1, b1)); // different types
    try testing.expect(!value.Value.eql(b1, b2)); // different values
}
