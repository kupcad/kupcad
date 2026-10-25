//! Built-ins that group Solids: `assemble` (`nativeAssemble`), of Solids and of assemblies,
//! an assembly's `name` and `parts`, `appendSolids` (every Solid it holds, its
//! assemblies' too), and `union([...])` and `batch_hull([...])`, which add one balanced DAG
//! chain over every part of an Array.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const dag = @import("../vm/dag.zig");
const arguments = @import("arguments.zig");
const limits = @import("../core/limits.zig");
/// How deep assemblies nest in assemblies: as deep as a model's Arrays may.
const MAX_ASSEMBLY_DEPTH = @import("../exporters/model.zig").MAX_MODEL_NESTING;

/// assemble(name: "Housing", parts: [...]) -> a named group of Solids and assemblies (a
/// subassembly stays one: `parts` gives it back). Anything else is a TypeError: the
/// exporters took the others for nothing and left them out without a word. The assembly
/// keeps its own copy of the list, so changing the Array afterwards doesn't change it.
pub fn nativeAssemble(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = try arguments.parseKwargs(struct { name: ?value.Value = null, parts: ?value.Value = null }, vm, args, "assemble");
    if (parsed.positional.len > 0) {
        return vm.fail(.ArgumentError, "assemble takes only keywords (name:, parts:), got {d} positional arguments", .{parsed.positional.len});
    }
    const name = parsed.opts.name orelse value.Value.initNil();
    const parts = parsed.opts.parts orelse value.Value.initNil();
    if (!name.isString()) {
        return vm.fail(.TypeError, "assemble expects a String for name, got {s}", .{arguments.typeName(vm, name)});
    }
    _ = try arguments.requireArray(vm, parts, "assemble", "parts");
    for (parts.asArray().items.items, 0..) |part, i| {
        if (part.isGeometry() or part.isAssembly()) continue;
        const hint = if (part.isNil()) "; leave out the nils with .compact" else "";
        return vm.fail(.TypeError, "assemble expects Solids and assemblies in parts, got {s} at index {d}{s}", .{ arguments.typeName(vm, part), i, hint });
    }
    const size = sizeOf(parts.asArray().items.items);
    if (size.depth > MAX_ASSEMBLY_DEPTH) return vm.fail(.ValueError, "assemble: assemblies nest at most {d} deep", .{MAX_ASSEMBLY_DEPTH});
    if (size.solids > limits.MAX_ASSEMBLY_SOLIDS) return vm.fail(.ValueError, "assemble: its parts place {d} Solids (an assembly among them counts each time it is placed); a script places at most {d}", .{ size.solids, limits.MAX_ASSEMBLY_SOLIDS });

    const own_parts = try copyArray(vm, parts.asArray());
    vm.push(value.Value.initObj(&own_parts.obj)); // rooted while the assembly is allocated
    defer _ = vm.pop();
    const assembly = try vm.gc.allocateAssembly(vm, name.asString(), own_parts, size);
    return value.Value.initObj(&assembly.obj);
}

/// The size of an assembly of `parts` (Solids and assemblies), from theirs: an assembly
/// placed twice in each of 25 levels places 2^25 Solids, which walking them would find
/// only after placing them.
fn sizeOf(parts: []const value.Value) value.AssemblySize {
    var size: value.AssemblySize = .{ .depth = 1, .solids = 0 };
    for (parts) |part| {
        if (!part.isAssembly()) {
            size.solids +|= 1;
            continue;
        }
        const inner = part.asAssembly().size;
        size.depth = @max(size.depth, inner.depth + 1);
        size.solids +|= inner.solids;
    }
    return size;
}

/// Appends every Solid `assembly` holds to `solids`: its own, then its assemblies', in order.
pub fn appendSolids(vm: *VM, solids: *std.ArrayList(value.Value), assembly: value.Value) !void {
    for (assembly.asAssembly().parts.items.items) |part| {
        if (part.isAssembly()) try appendSolids(vm, solids, part) else try solids.append(vm.allocator, part);
    }
}

fn copyArray(vm: *VM, from: *value.ObjArray) !*value.ObjArray {
    const copy = try vm.gc.allocateArray(vm);
    try copy.items.appendSlice(vm.gc.trackingAllocator(), from.items.items);
    return copy;
}

/// A new assembly of the same name, every part moved by `offset` (translate and center),
/// its assemblies as assemblies.
pub fn translated(vm: *VM, receiver: value.Value, offset: [3]f64) !value.Value {
    const from = receiver.asAssembly();
    const moved = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&moved.obj)); // rooted while the parts and the assembly are made
    defer _ = vm.pop();
    try moved.items.ensureTotalCapacity(vm.gc.trackingAllocator(), from.parts.items.items.len);
    for (from.parts.items.items) |part| {
        if (part.isAssembly()) {
            moved.items.appendAssumeCapacity(try translated(vm, part, offset));
            continue;
        }
        const idx = try vm.dag_builder.addTranslate(part.asGeometry().dag_idx, offset[0], offset[1], offset[2]);
        moved.items.appendAssumeCapacity(try vm.allocateGeometry(.{ .symbolic = idx }));
    }
    const assembly = try vm.gc.allocateAssembly(vm, from.name, moved, from.size);
    return value.Value.initObj(&assembly.obj);
}

/// `assembly.name`: the name it was given.
pub fn assemblyName(vm: *VM, receiver: value.Value) !value.Value {
    _ = vm;
    return value.Value.initObj(&receiver.asAssembly().name.obj);
}

/// `assembly.parts`: its Solids and assemblies as it was given them, as a new Array
/// (changing it doesn't change the assembly).
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
                return vm.fail(.ArgumentError, name ++ " needs at least one Solid, got an empty Array", .{});
            }

            var scratch_indices = std.ArrayList(u32).empty;
            defer scratch_indices.deinit(vm.allocator);
            for (parts.items.items, 0..) |part, i| {
                if (!part.isGeometry()) {
                    const hint = if (part.isNil()) "; leave out the nils with .compact" else "";
                    return vm.fail(.TypeError, name ++ " expects only Solids, got {s} at index {d}{s}", .{ arguments.typeName(vm, part), i, hint });
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
