const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");

/// Symbol#to_s
pub fn symbolToS(vm: *VM, sym: *value.ObjSymbol) !value.Value {
    return try vm.allocateString(sym.chars);
}

/// Symbol#to_sym (Identity)
pub fn symbolToSym(vm: *VM, sym: *value.ObjSymbol) !value.Value {
    _ = vm;
    return value.Value.initObj(&sym.obj);
}

/// Symbol class method dispatch table
pub const methods = [_]common.MethodDef{
    .{ .name = "to_s", .func = common.wrapMethod(symbolToS) },
    .{ .name = "to_sym", .func = common.wrapMethod(symbolToSym) },
};
