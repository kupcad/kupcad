const std = @import("std");
const testing = std.testing;
const value = @import("value.zig");

test "Value: memory size is strictly 8 bytes (NaN-Tagging)" {
    // This is the most critical assertion. If this fails, the VM loses
    // its ability to pass values cleanly in 64-bit hardware registers.
    try testing.expectEqual(@as(usize, 8), @sizeOf(value.Value));
}

test "Value: correct initialization and retrieval of primitives" {
    const num = value.Value.initNumber(3.14);
    try testing.expect(num.isNumber());
    try testing.expect(!num.isObject());
    try testing.expectEqual(@as(f64, 3.14), num.asNumber());

    const b = value.Value.initBool(true);
    try testing.expect(b.isBool());
    try testing.expect(!b.isNumber());
    try testing.expectEqual(true, b.asBool());

    const n = value.Value.initNil();
    try testing.expect(n.isNil());
    try testing.expect(!n.isBool());
}

test "Value: equality works across all types" {
    const num1 = value.Value.initNumber(42.0);
    const num2 = value.Value.initNumber(42.0);
    const num3 = value.Value.initNumber(43.0);

    try testing.expect(num1.isEqual(num2));
    try testing.expect(!num1.isEqual(num3));

    const b1 = value.Value.initBool(true);
    const b2 = value.Value.initBool(false);

    try testing.expect(!num1.isEqual(b1)); // different types
    try testing.expect(!b1.isEqual(b2)); // different values
}

test "Value: NaN-tagging handles edge-case floats seamlessly" {
    // Ensure IEEE 754 special values don't collide with our custom NaN tags
    const zero = value.Value.initNumber(0.0);
    const neg_zero = value.Value.initNumber(-0.0);
    const inf = value.Value.initNumber(std.math.inf(f64));

    try testing.expect(zero.isNumber());
    try testing.expect(neg_zero.isNumber());
    try testing.expect(inf.isNumber());

    // +0.0 and -0.0 must be evaluated as equal by our engine
    try testing.expect(zero.isEqual(neg_zero));
}

test "Value: NaN-tagging packs and unpacks Object pointers losslessly" {
    // Create a dummy heap object
    var dummy_obj = value.Obj{
        .obj_type = .string,
        .is_marked = false,
    };

    // Pack the pointer into the 8-byte Value
    const val = value.Value.initObj(&dummy_obj);

    // Verify it registers as an object and NOT a number/primitive
    try testing.expect(val.isObject());
    try testing.expect(!val.isNumber());
    try testing.expect(!val.isNil());

    // Unpack the pointer and ensure it points to the EXACT same memory address
    const unpacked_ptr = val.asObj();
    try testing.expectEqual(&dummy_obj, unpacked_ptr);
    try testing.expectEqual(value.ObjType.string, unpacked_ptr.obj_type);
}
