const std = @import("std");
const testing = std.testing;
const InstructionHooks = @import("instruction_hooks.zig").InstructionHooks;

test "InstructionHooks: active while any hook is on, and only then" {
    var hooks: InstructionHooks = .{};
    try testing.expect(!hooks.active);
    hooks.setLimit(100);
    hooks.setStep(true);
    try testing.expect(hooks.active);
    hooks.setLimit(0);
    try testing.expect(hooks.active); // stepping still is
    hooks.setStep(false);
    try testing.expect(!hooks.active);
    hooks.setZealousGc(true);
    try testing.expect(hooks.active);
    hooks.setZealousGc(false);
    try testing.expect(!hooks.active);
}
