const std = @import("std");
const testing = std.testing;
const value = @import("../value.zig");
const VM = @import("../../vm/vm.zig").VM;
const registry = @import("../../stdlib/registry.zig");

const number_param = @import("number.zig");
const boolean_param = @import("boolean.zig");
const string_param = @import("string.zig");
const choice_param = @import("choice.zig");

test "Params Unit: Number normalization and bounds checking" {
    // 1. Raw Float
    const val_num = value.Value.initNumber(42.5);
    try testing.expectEqual(@as(f64, 42.5), try number_param.normalize(val_num));

    // 2. Bounds Validation
    try number_param.validate(15.0, 10.0, 20.0);
    try testing.expectError(error.BelowMin, number_param.validate(5.0, 10.0, 20.0));
    try testing.expectError(error.AboveMax, number_param.validate(25.0, 10.0, 20.0));

    // 3. Unbounded (NaN)
    const nan = std.math.nan(f64);
    try number_param.validate(-1000.0, nan, nan);
}

test "Params Unit: Boolean flag normalization" {
    // 1. Native Booleans
    try testing.expectEqual(true, try boolean_param.normalize(value.Value.initBool(true)));
    try testing.expectEqual(false, try boolean_param.normalize(value.Value.initBool(false)));

    // 2. Numeric Flags (1 = true, 0 = false)
    try testing.expectEqual(true, try boolean_param.normalize(value.Value.initNumber(1.0)));
    try testing.expectEqual(false, try boolean_param.normalize(value.Value.initNumber(0.0)));

    // 3. Invalid Numeric Flags
    try testing.expectError(error.InvalidType, boolean_param.normalize(value.Value.initNumber(42.0)));
}

test "Params Unit: Choice validation (in: [...])" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const arr_obj = try vm.gc.allocateArray(&vm);
    vm.push(value.Value.initObj(&arr_obj.obj));
    defer _ = vm.pop();

    try arr_obj.items.append(testing.allocator, value.Value.initNumber(10.0));
    try arr_obj.items.append(testing.allocator, value.Value.initNumber(20.0));

    // Valid Choice
    try choice_param.validate(&vm, value.Value.initNumber(10.0), arr_obj);

    // Invalid Choice
    try testing.expectError(error.NotInChoices, choice_param.validate(&vm, value.Value.initNumber(30.0), arr_obj));
}
