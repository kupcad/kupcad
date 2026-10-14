const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const dag = @import("../vm/dag.zig");
const util = @import("methods/util.zig");

/// assemble(name: "Housing", parts: [...]) -> a named group of parts
pub fn nativeAssemble(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = try util.parseKwargs(struct { name: ?value.Value = null, parts: ?value.Value = null }, vm, args, "assemble");
    if (parsed.positional.len > 0) {
        _ = vm.raiseError(.ArgumentError, "assemble takes only keywords (name:, parts:), got {d} positional arguments", .{parsed.positional.len});
        return error.RuntimeError;
    }
    const name = parsed.opts.name orelse value.Value.initNil();
    const parts = parsed.opts.parts orelse value.Value.initNil();
    if (!name.isString()) {
        _ = vm.raiseError(.TypeError, "assemble expects a String for name, got {s}", .{util.typeName(vm, name)});
        return error.RuntimeError;
    }
    _ = try util.requireArray(vm, parts, "assemble", "parts");

    const assembly = try vm.gc.allocateAssembly(vm, name.asString(), parts.asArray());
    return value.Value.initObj(&assembly.obj);
}

/// union([parts]) and batch_hull([parts]): one balanced DAG chain over every part.
fn batchOp(comptime tag: dag.DAGTag, comptime name: []const u8) fn (*VM, *value.ObjArray) anyerror!value.Value {
    return struct {
        fn call(vm: *VM, parts: *value.ObjArray) !value.Value {
            if (parts.items.items.len == 0) {
                _ = vm.raiseError(.ArgumentError, name ++ " needs at least one Solid, got an empty Array", .{});
                return error.RuntimeError;
            }

            var scratch_indices = std.ArrayListUnmanaged(u32).empty;
            defer scratch_indices.deinit(vm.allocator);
            for (parts.items.items, 0..) |part, i| {
                if (!part.isGeometry()) {
                    _ = vm.raiseError(.TypeError, name ++ " expects only Solids, got {s} at index {d}", .{ util.typeName(vm, part), i });
                    return error.RuntimeError;
                }
                try scratch_indices.append(vm.allocator, part.asGeometry().dag_idx);
            }

            const dag_idx = try vm.dag_builder.addBalancedChain(tag, scratch_indices.items);
            return try vm.allocateGeometry(.{ .symbolic = dag_idx });
        }
    }.call;
}

pub const nativeUnion = batchOp(.union_op, "union");
pub const nativeBatchHull = batchOp(.hull, "batch_hull");
