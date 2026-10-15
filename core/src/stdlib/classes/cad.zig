const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const common = @import("common.zig");
const util = @import("../methods/util.zig");
const iteration = @import("iteration.zig");
const engine_config = @import("../../core/engine_config.zig");
const EngineConfig = engine_config.EngineConfig;
const EngineType = @import("../../kernel/geometry_handle.zig").EngineType;

/// The top-level settings of CAD.config: EngineConfig's fields, with the engine given by
/// name and each nested group as a Map (parsed into its own struct by `applyGroup`).
const Settings = struct {
    engine: ?[]const u8 = null,
    tolerance: ?f64 = null,
    resolution: ?value.Value = null,
    max_vertices: ?usize = null,
    manifold: ?value.Value = null,
    brep: ?value.Value = null,
};

/// `config` with `settings` applied. Unknown or mistyped settings and values the kernels
/// can't use are errors, and nothing is applied then.
fn applySettings(vm: *VM, settings: *value.ObjMap, config: EngineConfig) !EngineConfig {
    const parsed = try util.parseKwargs(Settings, vm, &.{value.Value.initObj(&settings.obj)}, "CAD.config");
    const s = parsed.opts;
    var next = config;
    if (s.engine) |name| next.engine = EngineType.fromScriptName(name) orelse {
        _ = vm.raiseError(.ValueError, "CAD.config engine must be manifold or brep, got '{s}'", .{name});
        return error.RuntimeError;
    };
    if (s.tolerance) |t| next.tolerance = t;
    if (s.max_vertices) |n| next.max_vertices = n;
    if (s.resolution) |v| next.resolution = try applyGroup(engine_config.Resolution, vm, v, next.resolution, "CAD.config resolution");
    if (s.manifold) |v| next.manifold = try applyGroup(engine_config.ManifoldConfig, vm, v, next.manifold, "CAD.config manifold");
    if (s.brep) |v| next.brep = try applyGroup(engine_config.BRepConfig, vm, v, next.brep, "CAD.config brep");
    if (next.problem()) |reason| {
        _ = vm.raiseError(.ValueError, "CAD.config: {s}", .{reason});
        return error.RuntimeError;
    }
    return next;
}

/// `current` with the settings of the Map `v` applied; its keys are T's fields.
fn applyGroup(comptime T: type, vm: *VM, v: value.Value, current: T, what: []const u8) !T {
    if (!v.isMap()) {
        _ = vm.raiseError(.TypeError, "{s} expects a Map of settings, got {s}", .{ what, util.typeName(vm, v) });
        return error.RuntimeError;
    }
    return (try util.parseKwargsOnto(T, current, vm, &.{v}, what)).opts;
}

/// `config` as nested Maps with the same keys CAD.config takes.
fn settingsMap(vm: *VM, comptime T: type, config: T) !value.Value {
    const map = try vm.gc.allocateMap(vm);
    vm.push(value.Value.initObj(&map.obj)); // protected from GC while it fills
    defer _ = vm.pop();
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        const v = @field(config, name);
        const item = switch (@typeInfo(F)) {
            .float => value.Value.initNumber(v),
            .int => value.Value.initNumber(@floatFromInt(v)),
            .bool => value.Value.initBool(v),
            .@"enum" => try vm.allocateSymbol(v.scriptName()),
            .@"struct" => try settingsMap(vm, F, v),
            else => @compileError("CAD.current_config: unsupported setting type " ++ @typeName(F)),
        };
        vm.push(item); // the key's allocation may collect
        defer _ = vm.pop();
        try map.map.put(vm.gc.trackingAllocator(), try vm.allocateSymbol(name), item);
    }
    return value.Value.initObj(&map.obj);
}

// CAD's methods are called on the CAD object; the receiver carries nothing.

/// CAD.config(settings) -> applies the settings to the active config
fn cadConfig(vm: *VM, receiver: value.Value, settings: *value.ObjMap) !value.Value {
    _ = receiver;
    try vm.setConfig(try applySettings(vm, settings, vm.config()));
    return value.Value.initNil();
}

/// CAD.with_config(settings) { ... } -> runs the block with the settings applied on top
/// of the active config, then restores it
fn cadWithConfig(vm: *VM, receiver: value.Value, settings: *value.ObjMap, block: ?*value.ObjClosure) !value.Value {
    _ = receiver;
    const body = block orelse {
        _ = vm.raiseError(.ArgumentError, "CAD.with_config requires a block", .{});
        return error.RuntimeError;
    };

    // Inherit the current config, then apply overrides
    const new_config = try applySettings(vm, settings, vm.config());

    // The block runs under the new settings; they come off again whatever it does.
    try vm.pushConfig(new_config);
    defer vm.popConfig();

    return switch (try iteration.callBlock(vm, body, &.{})) {
        .value, .broke => |v| v,
    };
}

/// CAD.current_config -> the active config as nested Maps
fn cadCurrentConfig(vm: *VM, receiver: value.Value) !value.Value {
    _ = receiver;
    return settingsMap(vm, EngineConfig, vm.config());
}

pub const methods = [_]common.MethodDef{
    .{ .name = "config", .func = common.wrapMethod(cadConfig) },
    .{ .name = "with_config", .func = common.wrapMethod(cadWithConfig) },
    .{ .name = "current_config", .func = common.wrapMethod(cadCurrentConfig) },
};
