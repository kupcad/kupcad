const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const dag = @import("../vm/dag.zig");
const util = @import("methods/util.zig");

/// assemble(name: "Housing", parts: [...]) -> a named group of Solids. Every part must be a
/// Solid: the exporters took the others for nothing and left them out without a word. The
/// assembly keeps its own copy of the list, so changing the Array afterwards doesn't
/// change it.
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
    for (parts.asArray().items.items, 0..) |part, i| {
        if (part.isGeometry()) continue;
        const hint = if (part.isAssembly()) "; to nest an assembly, give its .parts" else if (part.isNil()) "; leave out the nils with .compact" else "";
        _ = vm.raiseError(.TypeError, "assemble expects only Solids in parts, got {s} at index {d}{s}", .{ util.typeName(vm, part), i, hint });
        return error.RuntimeError;
    }

    const own_parts = try copyArray(vm, parts.asArray());
    vm.push(value.Value.initObj(&own_parts.obj)); // rooted while the assembly is allocated
    defer _ = vm.pop();
    const assembly = try vm.gc.allocateAssembly(vm, name.asString(), own_parts);
    return value.Value.initObj(&assembly.obj);
}

fn copyArray(vm: *VM, from: *value.ObjArray) !*value.ObjArray {
    const copy = try vm.gc.allocateArray(vm);
    try copy.items.appendSlice(vm.gc.trackingAllocator(), from.items.items);
    return copy;
}

/// `assembly.name`: the name it was given.
pub fn assemblyName(vm: *VM, receiver: value.Value) !value.Value {
    _ = vm;
    return value.Value.initObj(&receiver.asAssembly().name.obj);
}

/// `assembly.parts`: its Solids, as a new Array (changing it doesn't change the assembly).
pub fn assemblyParts(vm: *VM, receiver: value.Value) !value.Value {
    return value.Value.initObj(&(try copyArray(vm, receiver.asAssembly().parts)).obj);
}

/// union([parts]) and batch_hull([parts]): one balanced DAG chain over every part.
fn batchOp(comptime tag: dag.DAGTag, comptime name: []const u8) fn (*VM, *value.ObjArray) anyerror!value.Value {
    return struct {
        fn call(vm: *VM, parts: *value.ObjArray) !value.Value {
            if (parts.items.items.len == 0) {
                // The union of nothing is the empty Solid (it was an error, though a list of
                // optional parts all left out is an ordinary outcome); a hull of nothing isn't a shape.
                if (tag == .union_op) return try vm.allocateGeometry(.{ .symbolic = try vm.dag_builder.addEmpty(true) });
                _ = vm.raiseError(.ArgumentError, name ++ " needs at least one Solid, got an empty Array", .{});
                return error.RuntimeError;
            }

            var scratch_indices = std.ArrayListUnmanaged(u32).empty;
            defer scratch_indices.deinit(vm.allocator);
            for (parts.items.items, 0..) |part, i| {
                if (!part.isGeometry()) {
                    const hint = if (part.isNil()) "; leave out the nils with .compact" else "";
                    _ = vm.raiseError(.TypeError, name ++ " expects only Solids, got {s} at index {d}{s}", .{ util.typeName(vm, part), i, hint });
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
