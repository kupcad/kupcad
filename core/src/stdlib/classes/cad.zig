const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");
const EngineConfig = @import("../../core/engine_config.zig").EngineConfig;

fn applyConfigMap(vm: *VM, map: *value.ObjMap, config: *EngineConfig) void {
    if (vm.findMapKeyByString(map, "segments")) |idx| {
        const v = map.map.values()[idx];
        if (v.isNumber()) config.segments = @intFromFloat(v.asNumber());
    }
    if (vm.findMapKeyByString(map, "fa")) |idx| {
        const v = map.map.values()[idx];
        if (v.isNumber()) config.fa = v.asNumber();
    }
    if (vm.findMapKeyByString(map, "fs")) |idx| {
        const v = map.map.values()[idx];
        if (v.isNumber()) config.fs = v.asNumber();
    }
    if (vm.findMapKeyByString(map, "tolerance")) |idx| {
        const v = map.map.values()[idx];
        if (v.isNumber()) config.tolerance = v.asNumber();
    }
    if (vm.findMapKeyByString(map, "engine")) |idx| {
        const v = map.map.values()[idx];
        if (v.isSymbol()) {
            const sym = v.asSymbol().chars;
            if (std.mem.eql(u8, sym, "manifold")) config.engine = .manifold;
            if (std.mem.eql(u8, sym, "brep")) config.engine = .brep_native;
        }
    }
}

pub fn cadConfig(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = vm.getReceiver(args); // Skip the `CAD` receiver

    if (arg_count == 0 or !args[0].isMap()) {
        vm.reportError("ArgumentError: CAD.config requires a Hash Map of settings.\n", .{});
        return error.RuntimeError;
    }

    const current = &vm.config_stack.items[vm.config_stack.items.len - 1];
    applyConfigMap(vm, args[0].asMap(), current);

    return value.Value.initNil();
}

pub fn cadWithConfig(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = vm.getReceiver(args);

    if (arg_count < 2 or !args[0].isMap() or !args[1].isClosure()) {
        vm.reportError("ArgumentError: CAD.with_config requires a Hash Map and a Block.\n", .{});
        return error.RuntimeError;
    }

    // Inherit the current config, then apply overrides
    var new_config = vm.config_stack.items[vm.config_stack.items.len - 1];
    applyConfigMap(vm, args[0].asMap(), &new_config);

    // Push the new scope
    try vm.config_stack.append(vm.allocator, new_config);

    // Evaluate the block
    const result = vm.callClosureSync(args[1].asClosure(), &.{});

    // Pop the scope (Guarantees no state leakage!)
    _ = vm.config_stack.pop();

    return result catch |err| {
        if (err == error.BlockBreak) return vm.stack[vm.stack_top - 1];
        return err;
    };
}

pub fn cadCurrentConfig(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const vm: *VM = @ptrCast(@alignCast(vm_opaque));
    _ = vm.getReceiver(args);
    _ = arg_count;

    const config = vm.config_stack.items[vm.config_stack.items.len - 1];
    const map_obj = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&map_obj.obj));
    defer _ = vm.pop();

    try map_obj.map.put(vm.allocator, try vm.allocateSymbol("segments"), value.Value.initNumber(@floatFromInt(config.segments)));
    try map_obj.map.put(vm.allocator, try vm.allocateSymbol("fa"), value.Value.initNumber(config.fa));
    try map_obj.map.put(vm.allocator, try vm.allocateSymbol("fs"), value.Value.initNumber(config.fs));
    try map_obj.map.put(vm.allocator, try vm.allocateSymbol("tolerance"), value.Value.initNumber(config.tolerance));

    const engine_sym = if (config.engine == .manifold) "manifold" else "brep";
    try map_obj.map.put(vm.allocator, try vm.allocateSymbol("engine"), try vm.allocateSymbol(engine_sym));

    return value.Value.initObj(&map_obj.obj);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "config", .func = cadConfig },
    .{ .name = "with_config", .func = cadWithConfig },
    .{ .name = "current_config", .func = cadCurrentConfig },
};
