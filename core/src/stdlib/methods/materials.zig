//! Appearance methods: `material(...)` registers a `MaterialDef` with the VM and tags the
//! Solid with it in the DAG; `highlight` and `ghost`, as methods or block forms, tag it for
//! the viewer, and a ghost goes to the VM's display list instead of the model.

const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const material = @import("../../core/material.zig");
const MaterialDef = material.MaterialDef;
const kernel = @import("../../kernel/kernel.zig");
const arguments = @import("../arguments.zig");
const paths = @import("../paths.zig");
const sig = @import("../method_signatures.zig");
const error_kind = @import("../../vm/error_kind.zig");

/// `solid.material(...)` and `sketch.material(...)`: how a Solid is shaded and what it is
/// made of; a Sketch's colour is its drawing's (SVG, DXF), the rest kept with it.
pub fn meshMaterial(vm: *VM, receiver: value.Value, args: []const value.Value) !value.Value {
    if (!receiver.isGeometry() and !receiver.isCrossSection() and !receiver.isPath()) return arguments.notDefinedFor(vm, "material", receiver);

    const parsed = try arguments.parseKwargsSubset(struct {
        color: ?[]const u8 = null,
        alpha: ?f64 = null,
        roughness: ?f64 = null,
        metallic: ?f64 = null,
        transmission: ?f64 = null,
        density: ?f64 = null,
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
        .density = if (opts.density) |d| blk: {
            try arguments.requirePositive(vm, d, "material", "density (g/cm³)");
            break :blk d;
        } else null,
    };

    // Insert into VM registry to get an ID
    const material_id: u32 = @intCast(vm.materials.items.len);
    try vm.materials.append(vm.allocator, mat_def);

    if (receiver.isCrossSection()) return vm.allocateCrossSection(try vm.dag_builder.addSketchMaterial(receiver.asCrossSection().dag_idx, material_id));
    if (receiver.isPath()) return paths.withMaterial(vm, receiver, material_id);
    return solidWithMaterial(vm, receiver, material_id);
}

/// The Solid `solid` tagged with the VM's material `material_id`. An engine that can't keep
/// materials warns here, where the script gives one, not when the Solid is built: a run
/// that finds it built already (the session's result cache) would say nothing, and one
/// that first builds it to export it would say nowhere.
fn solidWithMaterial(vm: *VM, solid: value.Value, material_id: u32) !value.Value {
    vm.warnUnsupported(vm.settingsOf(solid).engine, .materials);
    const new_idx = try vm.dag_builder.addSetMaterial(solid.asGeometry().dag_idx, material_id);
    return vm.allocateGeometry(.{ .symbolic = new_idx });
}

/// The Solid `solid` tagged for the viewer to show as `role` (a highlight, a ghost): the
/// viewer gives it its look.
fn solidWithRole(vm: *VM, solid: value.Value, role: material.MaterialRole) !value.Value {
    const material_id: u32 = @intCast(vm.materials.items.len);
    try vm.materials.append(vm.allocator, .{ .role = role });
    return solidWithMaterial(vm, solid, material_id);
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
    if (!receiver.isGeometry()) return arguments.notDefinedFor(vm, "highlight", receiver);

    return solidWithRole(vm, receiver, .highlight);
}

pub fn meshGhost(vm: *VM, receiver: value.Value) !value.Value {
    if (!receiver.isGeometry()) return arguments.notDefinedFor(vm, "ghost", receiver);

    // Force JIT evaluation and push directly to the standalone display list
    try appendToDisplayList(vm, try solidWithRole(vm, receiver, .ghost));

    // The shape itself, unchanged: the ghost is the copy on the display list. It returned
    // nil, so `env = part.ghost` lost the shape it showed.
    return receiver;
}

// --- Global Block Modifiers ---

/// highlight { ... } -> the block's Solid, tagged for the viewer to show in high contrast
pub fn globalHighlight(vm: *VM, block: ?*value.ObjClosure) !value.Value {
    const result = try vm.callClosureSync(try arguments.requireBlock(vm, block, "highlight"), &.{});
    try requireSolidResult(vm, result, "highlight");

    return solidWithRole(vm, result, .highlight);
}

/// The block of `highlight { }` or `ghost { }` must give the Solid to show: anything else
/// used to be passed through (or dropped) without being shown.
fn requireSolidResult(vm: *VM, result: value.Value, method: []const u8) !void {
    if (result.isGeometry()) return;
    return vm.fail(.TypeError, "{s}'s block must give a Solid, got {s}", .{ method, arguments.typeName(vm, result) });
}

/// ghost { ... } -> shows the block's Solid as a translucent reference, outside the model
pub fn globalGhost(vm: *VM, block: ?*value.ObjClosure) !value.Value {
    const result = try vm.callClosureSync(try arguments.requireBlock(vm, block, "ghost"), &.{});
    try requireSolidResult(vm, result, "ghost");

    try appendToDisplayList(vm, try solidWithRole(vm, result, .ghost));

    return value.Value.initNil();
}
