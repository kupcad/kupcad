const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const geom = @import("../kernel/geometry_handle.zig");
const manifest = @import("manifest.zig");

pub fn cadInvokeHandler(vm: *VM, receiver: value.Value, method_name: []const u8, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    if (!receiver.isGeometry()) {
        std.log.err("Runtime Error: Methods can only be called on Geometry objects.\n", .{});
        return error.RuntimeError;
    }

    if (std.mem.eql(u8, method_name, "on_face")) {
        // Force JIT Materialization
        const handle = try vm.ensureConcrete(receiver);
        const geom_obj = receiver.asGeometry();

        // Extract direction symbol (e.g., :top)
        if (arg_count < 1 or !args[0].isString()) return error.RuntimeError;
        const direction_sym = args[0].asString();

        // 3. Lazy Topology Initialization
        if (geom_obj.cached_topology == null) {
            geom_obj.cached_topology = try vm.allocator.create(value.TopologyCache);
            geom_obj.cached_topology.?.* = .{ .is_populated = true };
        }

        var filter = geom.FaceFilter.top;
        if (std.mem.eql(u8, direction_sym, "bottom")) filter = .bottom;

        // Query Kernel (Mocked for now)
        _ = vm.active_kernel.?.queryFaces(handle, filter);

        // Spawn Workplane tied to parent geometry!
        return try vm.allocateWorkplane(geom_obj, [3]f64{ 0, 0, 0 }, [3]f64{ 0, 0, 1 });
    }

    if (std.mem.eql(u8, method_name, "translate")) {
        const x = if (arg_count > 0) args[0].asNumber() else 0.0;
        const y = if (arg_count > 1) args[1].asNumber() else 0.0;
        const z = if (arg_count > 2) args[2].asNumber() else 0.0;
        const new_idx = try vm.dag_builder.addTranslate(receiver.asGeometry().dag_idx, x, y, z);
        return try vm.allocateGeometry(.{ .symbolic = new_idx });
    }

    inline for (manifest.mesh_methods) |method| {
        if (std.mem.eql(u8, method_name, method.name)) {
            vm.retainValue(receiver);
            return receiver;
        }
    }

    std.log.err("Runtime Error: Unknown method '{s}' on Geometry object.\n", .{method_name});
    return error.RuntimeError;
}
