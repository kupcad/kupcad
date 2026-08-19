const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;

pub fn nativeParam(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));

    // Require at least one positional argument (the parameter name)
    if (arg_count == 0) return error.RuntimeError;

    const key_val = args[0];
    if (!key_val.isObject() or (key_val.asObj().obj_type != .symbol and key_val.asObj().obj_type != .string)) {
        vm.reportError("Runtime Error: param() key must be a Symbol or String.\n", .{});
        return error.RuntimeError;
    }

    // Coerce Strings into Symbols for consistent Dictionary lookups
    const sym_key = if (key_val.asObj().obj_type == .symbol)
        key_val
    else
        try vm.allocateSymbol(@as(*value.ObjString, @alignCast(@fieldParentPtr("obj", key_val.asObj()))).chars);

    vm.push(sym_key); // Protect from GC
    defer _ = vm.pop();

    // Extract the `default:` value from kwargs (if provided)
    var default_val = value.Value.initNil();
    if (arg_count > 1 and args[arg_count - 1].isObject() and args[arg_count - 1].asObj().obj_type == .map) {
        const kwargs_map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", args[arg_count - 1].asObj())));

        for (kwargs_map.keys.items, 0..) |k, i| {
            if (k.isObject() and (k.asObj().obj_type == .string or k.asObj().obj_type == .symbol)) {
                const k_str = if (k.asObj().obj_type == .string)
                    @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars
                else
                    @as(*value.ObjSymbol, @alignCast(@fieldParentPtr("obj", k.asObj()))).chars;

                if (std.mem.eql(u8, k_str, "default")) {
                    default_val = kwargs_map.values.items[i];
                }

                // Note: We intentionally ignore `type:`, `min:`, and `max:` here
                // because the VM trusts the human/UI context. We just need the default!
            }
        }
    }

    // Fetch the global `params` dictionary we injected
    const p_val = vm.globals.get("params") orelse return error.RuntimeError;
    const params_map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", p_val.asObj())));

    // Initialize the value ONLY if it doesn't already exist (respecting CLI overrides)
    if (vm.findMapKey(params_map, sym_key) == null) {
        vm.retainValue(sym_key);
        vm.retainValue(default_val);
        try params_map.keys.append(vm.allocator, sym_key);
        try params_map.values.append(vm.allocator, default_val);
    }

    return value.Value.initNil();
}
