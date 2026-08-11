const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const manifest = @import("manifest.zig");

pub fn cadInvokeHandler(vm: *VM, receiver: value.Value, method_name: []const u8, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (!receiver.isGeometry()) {
        std.log.err("Runtime Error: Methods can only be called on Geometry objects.\n", .{});
        return error.RuntimeError;
    }

    // JIT Materialization Triggers (Introspection)
    if (std.mem.eql(u8, method_name, "bbox") or std.mem.eql(u8, method_name, "volume") or std.mem.eql(u8, method_name, "on_face")) {
        _ = try vm.ensureConcrete(receiver);
        return value.Value.initNil();
    }

    // Lazy Transforms (Appends to DAG, returns new symbolic node)
    if (std.mem.eql(u8, method_name, "translate")) {
        const x = if (arg_count > 0) args[0].asNumber() else 0.0;
        const y = if (arg_count > 1) args[1].asNumber() else 0.0;
        const z = if (arg_count > 2) args[2].asNumber() else 0.0;
        const new_idx = try vm.dag_builder.addTranslate(receiver.asGeometry().dag_idx, x, y, z);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    }

    // Mock: Accept transform methods dynamically mapped in our manifest
    inline for (manifest.mesh_methods) |method| {
        if (std.mem.eql(u8, method_name, method.name)) {
            vm.retainValue(receiver);
            return receiver;
        }
    }

    std.log.err("Runtime Error: Unknown method '{s}' on Geometry object.\n", .{method_name});
    return error.RuntimeError;
}
