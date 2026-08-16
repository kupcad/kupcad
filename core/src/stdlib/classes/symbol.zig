const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

// Symbol to String
pub fn symbolToS(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapSymbol(vm_opaque, arg_count, 0, args);
    return try ctx.vm.allocateString(ctx.sym.chars);
}

// Symbol to Symbol (Identity)
pub fn symbolToSym(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const ctx = try common.unwrapSymbol(vm_opaque, arg_count, 0, args);
    return ctx.receiver;
}

pub const methods = [_]common.MethodDef{
    .{ .name = "to_s", .func = symbolToS },
    .{ .name = "to_sym", .func = symbolToSym },
};
