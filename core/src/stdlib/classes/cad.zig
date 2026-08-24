const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");
const EngineConfig = @import("../../core/engine_config.zig").EngineConfig;

fn applyConfigMap(vm: *VM, map: *value.ObjMap, config: *EngineConfig) void {
    // --- Engine Selection ---
    if (vm.findMapKeyByString(map, "engine")) |idx| {
        const v = map.map.values()[idx];
        if (v.isSymbol()) {
            const sym = v.asSymbol().chars;
            if (std.mem.eql(u8, sym, "manifold")) config.engine = .manifold;
            if (std.mem.eql(u8, sym, "brep")) config.engine = .brep_native;
        }
    }

    // --- Nested Manifold-Specific Map ---
    if (vm.findMapKeyByString(map, "manifold")) |idx| {
        const v = map.map.values()[idx];
        if (v.isMap()) {
            const m = v.asMap();

            if (vm.findMapKeyByString(m, "simplify_coplanar")) |i| {
                const tv = m.map.values()[i];
                if (tv.isBool()) config.manifold.simplify_coplanar = tv.asBool();
            }
            if (vm.findMapKeyByString(m, "tolerance")) |i| {
                const tv = m.map.values()[i];
                if (tv.isNumber()) config.manifold.tolerance = tv.asNumber();
            }
            if (vm.findMapKeyByString(m, "fixed_segments")) |i| {
                if (m.map.values()[i].isNumber()) config.manifold.fixed_segments = @intFromFloat(@max(0.0, m.map.values()[i].asNumber()));
            }
            if (vm.findMapKeyByString(m, "min_angle_deg")) |i| {
                if (m.map.values()[i].isNumber()) config.manifold.min_angle_deg = m.map.values()[i].asNumber();
            }
            if (vm.findMapKeyByString(m, "min_segment_len")) |i| {
                if (m.map.values()[i].isNumber()) config.manifold.min_segment_len = m.map.values()[i].asNumber();
            }
        }
    }

    // --- Nested B-Rep-Specific Map ---
    if (vm.findMapKeyByString(map, "brep")) |idx| {
        const v = map.map.values()[idx];
        if (v.isMap()) {
            const m = v.asMap();

            // Tolerances
            if (vm.findMapKeyByString(m, "tolerance")) |i| {
                if (m.map.values()[i].isNumber()) config.brep.tolerance = m.map.values()[i].asNumber();
            }
            if (vm.findMapKeyByString(m, "angle_tolerance")) |i| {
                if (m.map.values()[i].isNumber()) config.brep.angle_tolerance = m.map.values()[i].asNumber();
            }
            if (vm.findMapKeyByString(m, "sewing_tolerance")) |i| {
                if (m.map.values()[i].isNumber()) config.brep.sewing_tolerance = m.map.values()[i].asNumber();
            }

            // Tessellation
            if (vm.findMapKeyByString(m, "chordal_deflection")) |i| {
                if (m.map.values()[i].isNumber()) config.brep.chordal_deflection = m.map.values()[i].asNumber();
            }
            if (vm.findMapKeyByString(m, "angular_deflection")) |i| {
                if (m.map.values()[i].isNumber()) config.brep.angular_deflection = m.map.values()[i].asNumber();
            }
            if (vm.findMapKeyByString(m, "min_circle_segments")) |i| {
                if (m.map.values()[i].isNumber()) config.brep.min_circle_segments = @intFromFloat(@max(0.0, m.map.values()[i].asNumber()));
            }

            // Solvers
            if (vm.findMapKeyByString(m, "max_newton_trials")) |i| {
                if (m.map.values()[i].isNumber()) config.brep.max_newton_trials = @intFromFloat(@max(0.0, m.map.values()[i].asNumber()));
            }
            if (vm.findMapKeyByString(m, "max_marching_steps")) |i| {
                if (m.map.values()[i].isNumber()) config.brep.max_marching_steps = @intFromFloat(@max(0.0, m.map.values()[i].asNumber()));
            }
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

    // --- Create the Root Configuration Map ---
    const root_map = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&root_map.obj)); // Protect root_map from GC
    defer _ = vm.pop();

    // Set Active Engine
    const engine_sym = if (config.engine == .manifold) "manifold" else "brep";
    try root_map.map.put(vm.allocator, try vm.allocateSymbol("engine"), try vm.allocateSymbol(engine_sym));

    // --- Create Nested Manifold Map ---
    const man_map = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&man_map.obj)); // Protect man_map from GC

    // Manifold Options
    try man_map.map.put(vm.allocator, try vm.allocateSymbol("tolerance"), value.Value.initNumber(config.manifold.tolerance));
    try man_map.map.put(vm.allocator, try vm.allocateSymbol("simplify_coplanar"), value.Value.initBool(config.manifold.simplify_coplanar));
    try man_map.map.put(vm.allocator, try vm.allocateSymbol("fixed_segments"), value.Value.initNumber(@floatFromInt(config.manifold.fixed_segments)));
    try man_map.map.put(vm.allocator, try vm.allocateSymbol("min_angle_deg"), value.Value.initNumber(config.manifold.min_angle_deg));
    try man_map.map.put(vm.allocator, try vm.allocateSymbol("min_segment_len"), value.Value.initNumber(config.manifold.min_segment_len));

    // Attach Manifold Map to Root
    try root_map.map.put(vm.allocator, try vm.allocateSymbol("manifold"), value.Value.initObj(&man_map.obj));
    _ = vm.pop();

    // --- Create Nested B-Rep Map ---
    const brep_map = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&brep_map.obj)); // Protect brep_map from GC

    // B-Rep Tolerances
    try brep_map.map.put(vm.allocator, try vm.allocateSymbol("tolerance"), value.Value.initNumber(config.brep.tolerance));
    try brep_map.map.put(vm.allocator, try vm.allocateSymbol("angle_tolerance"), value.Value.initNumber(config.brep.angle_tolerance));
    try brep_map.map.put(vm.allocator, try vm.allocateSymbol("sewing_tolerance"), value.Value.initNumber(config.brep.sewing_tolerance));

    // B-Rep Tessellation
    try brep_map.map.put(vm.allocator, try vm.allocateSymbol("chordal_deflection"), value.Value.initNumber(config.brep.chordal_deflection));
    try brep_map.map.put(vm.allocator, try vm.allocateSymbol("angular_deflection"), value.Value.initNumber(config.brep.angular_deflection));
    try brep_map.map.put(vm.allocator, try vm.allocateSymbol("min_circle_segments"), value.Value.initNumber(@floatFromInt(config.brep.min_circle_segments)));

    // B-Rep Solvers
    try brep_map.map.put(vm.allocator, try vm.allocateSymbol("max_newton_trials"), value.Value.initNumber(@floatFromInt(config.brep.max_newton_trials)));
    try brep_map.map.put(vm.allocator, try vm.allocateSymbol("max_marching_steps"), value.Value.initNumber(@floatFromInt(config.brep.max_marching_steps)));

    // Attach B-Rep Map to Root
    try root_map.map.put(vm.allocator, try vm.allocateSymbol("brep"), value.Value.initObj(&brep_map.obj));
    _ = vm.pop();

    return value.Value.initObj(&root_map.obj);
}

pub const methods = [_]common.MethodDef{
    .{ .name = "config", .func = cadConfig },
    .{ .name = "with_config", .func = cadWithConfig },
    .{ .name = "current_config", .func = cadCurrentConfig },
};
