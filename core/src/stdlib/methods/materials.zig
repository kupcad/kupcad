//! Appearance methods: `material(...)` registers a `MaterialDef` with the VM and tags the
//! Solid with it in the DAG; `highlight` and `ghost`, as methods or block forms, tag it for
//! the viewer, and a ghost goes to the VM's display list instead of the model.

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const material = @import("../../core/material.zig");
const MaterialDef = material.MaterialDef;
const kernel = @import("../../kernel/kernel.zig");
const util = @import("util.zig");
const sig = @import("../method_signatures.zig");
const error_kind = @import("../../vm/error_kind.zig");

pub fn meshMaterial(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "material", receiver);

    const parsed = try util.parseKwargsSubset(struct {
        color: ?[]const u8 = null,
        alpha: ?f64 = null,
        roughness: ?f64 = null,
        metallic: ?f64 = null,
        transmission: ?f64 = null,
    }, sig.MATERIAL.keywords, vm, args, "material");
    if (parsed.positional.len == args.len) {
        return vm.fail(.ArgumentError, "material requires keyword arguments (e.g. color: \"#FF0000\")", .{});
    }
    const opts = parsed.opts;
    const defaults = MaterialDef{};
    const rgb = if (opts.color) |text| material.parseHexColor(text) orelse {
        return vm.fail(.ValueError, "material color must be \"#RRGGBB\" or \"#RGB\", got \"{s}\"", .{text});
    } else defaults.rgb;
    const mat_def = MaterialDef{
        .rgb = rgb,
        .alpha = try unitInterval(vm, "alpha", opts.alpha orelse defaults.alpha),
        .roughness = try unitInterval(vm, "roughness", opts.roughness orelse defaults.roughness),
        .metallic = try unitInterval(vm, "metallic", opts.metallic orelse defaults.metallic),
        .transmission = try unitInterval(vm, "transmission", opts.transmission orelse defaults.transmission),
    };

    // Insert into VM registry to get an ID
    const material_id: u32 = @intCast(vm.materials.items.len);
    try vm.materials.append(vm.allocator, mat_def);

    const new_idx = try vm.dag_builder.addSetMaterial(receiver.asGeometry().dag_idx, material_id);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

/// Material factors are fractions: `roughness: 5` used to be accepted as is.
fn unitInterval(vm: *VM, comptime name: []const u8, n: f64) !f64 {
    if (n >= 0.0 and n <= 1.0) return n;
    return vm.fail(.ValueError, "material " ++ name ++ " must be between 0 and 1, got {f}", .{value.fmtNumber(n)});
}

/// ensureConcrete only BORROWS the handle from vm.dag_cache, and nothing roots
/// `ghost_geom`, so the next GC would evict (free) it before export. The display
/// list therefore stores its own copy, destroyed in VM.deinit.
fn appendToDisplayList(vm: *VM, ghost_geom: value.Value) !void {
    const borrowed = try vm.ensureConcrete(ghost_geom);
    const owned = kernel.clone(borrowed) orelse {
        return vm.fail(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"ghost"});
    };
    vm.display_list.append(vm.allocator, owned) catch |err| {
        kernel.destruct(owned);
        return err;
    };
}

// --- Chained Methods ---

pub fn meshHighlight(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "highlight", receiver);

    const material_id: u32 = @intCast(vm.materials.items.len);
    // Pure semantic tagging. Let the viewer handle the visuals.
    try vm.materials.append(vm.allocator, .{ .role = .highlight });

    const new_idx = try vm.dag_builder.addSetMaterial(receiver.asGeometry().dag_idx, material_id);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

pub fn meshGhost(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isGeometry()) return util.notDefinedFor(vm, "ghost", receiver);

    const material_id: u32 = @intCast(vm.materials.items.len);
    // Pure semantic tagging
    try vm.materials.append(vm.allocator, .{ .role = .ghost });

    const new_idx = try vm.dag_builder.addSetMaterial(receiver.asGeometry().dag_idx, material_id);
    const ghost_geom = try vm.allocateGeometry(.{ .symbolic = new_idx });

    // Force JIT evaluation and push directly to the standalone display list
    try appendToDisplayList(vm, ghost_geom);

    // Return NIL so it drops completely out of the CSG math tree!
    return value.Value.initNil();
}

// --- Global Block Modifiers ---

/// highlight { ... } -> the block's Solid, tagged for the viewer to show in high contrast
pub fn globalHighlight(vm: *VM, block: ?*value.ObjClosure) !value.Value {
    const result = try vm.callClosureSync(try requireBlock(vm, block, "highlight"), &.{});
    try requireSolidResult(vm, result, "highlight");

    const material_id: u32 = @intCast(vm.materials.items.len);
    try vm.materials.append(vm.allocator, .{ .role = .highlight });

    const new_idx = try vm.dag_builder.addSetMaterial(result.asGeometry().dag_idx, material_id);
    return try vm.allocateGeometry(.{ .symbolic = new_idx });
}

/// The block of `highlight { }` or `ghost { }` must give the Solid to show: anything else
/// used to be passed through (or dropped) without being shown.
fn requireSolidResult(vm: *VM, result: value.Value, method: []const u8) !void {
    if (result.isGeometry()) return;
    return vm.fail(.TypeError, "{s}'s block must give a Solid, got {s}", .{ method, util.typeName(vm, result) });
}

/// ghost { ... } -> shows the block's Solid as a translucent reference, outside the model
pub fn globalGhost(vm: *VM, block: ?*value.ObjClosure) !value.Value {
    const result = try vm.callClosureSync(try requireBlock(vm, block, "ghost"), &.{});
    try requireSolidResult(vm, result, "ghost");

    const material_id: u32 = @intCast(vm.materials.items.len);
    try vm.materials.append(vm.allocator, .{ .role = .ghost });

    const new_idx = try vm.dag_builder.addSetMaterial(result.asGeometry().dag_idx, material_id);
    const ghost_geom = try vm.allocateGeometry(.{ .symbolic = new_idx });

    try appendToDisplayList(vm, ghost_geom);

    return value.Value.initNil();
}

fn requireBlock(vm: *VM, block: ?*value.ObjClosure, comptime name: []const u8) !*value.ObjClosure {
    return block orelse {
        return vm.fail(.ArgumentError, name ++ " requires a block", .{});
    };
}
