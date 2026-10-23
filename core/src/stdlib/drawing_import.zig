//! `import_dxf`: a drawing's outlines as a Sketch. The reader (exporters/2d/dxf_read.zig)
//! gives closed outlines; each becomes a closed path of the geometry graph, its arcs
//! known to a drawing, turned counter-clockwise (the kernel fills a clockwise one with
//! nothing), and they nest by the even-odd rule, as a laser cutter reads a drawing: an
//! outline inside one other is a hole, inside two an island in the hole, and so on.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const arguments = @import("arguments.zig");
const Signature = @import("signature.zig").Signature;
const limits = @import("../core/limits.zig");
const path_mod = @import("../core/path.zig");
const paths = @import("paths.zig");
const dxf_read = @import("../exporters/2d/dxf_read.zig");

pub const IMPORT_DXF = Signature{ .positional = &.{"path"}, .keywords = &.{ "layers", "tolerance" }, .sizes = &.{"tolerance"} };

/// `import_dxf(path, layers:, tolerance:)`: the Sketch the DXF file's outlines fill, on
/// the `layers:` named (a String or an Array of them; every layer without it), pieces
/// whose ends are within `tolerance:` (the active tolerance without it) joined. What
/// `import plate from "./plate.dxf"` calls.
pub fn nativeImportDxf(vm: *VM, args: []const value.Value) !value.Value {
    const Opts = struct { layers: ?value.Value = null, tolerance: ?f64 = null };
    const parsed = try arguments.parseKwargsSubset(Opts, IMPORT_DXF.keywords, vm, args, "import_dxf");
    if (parsed.positional.len != 1) return vm.fail(.ArgumentError, "import_dxf expects the path of a DXF file", .{});
    const file_path = try arguments.requireName(vm, parsed.positional[0], "import_dxf", "path");
    const tolerance = parsed.opts.tolerance orelse vm.config().tolerance;
    try arguments.requirePositive(vm, tolerance, "import_dxf", "tolerance");
    const layers = if (parsed.opts.layers) |v| try layerNames(vm, v) else null;
    defer if (layers) |names| vm.allocator.free(names);

    const file = vm.readScriptFile(file_path) catch |err| {
        if (err == error.OutOfMemory) return err;
        return vm.fail(.ImportError, "could not read DXF file '{s}': {s}", .{ file_path, @errorName(err) });
    };
    defer vm.allocator.free(file);
    if (file.len > limits.MAX_DRAWING_BYTES) {
        return vm.fail(.ImportError, "DXF file '{s}' is {d} bytes; a script reads at most {d}", .{ file_path, file.len, limits.MAX_DRAWING_BYTES });
    }
    var diag: dxf_read.Diagnostic = .{};
    const config = vm.config();
    var drawing = dxf_read.read(vm.allocator, file, .{ .tolerance = tolerance, .layers = layers, .config = &config }, &diag) catch |err| switch (err) {
        error.InvalidDxf => return vm.fail(.ImportError, "could not read DXF file '{s}': {s}", .{ file_path, diag.message() }),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer drawing.deinit();
    if (layers) |names| for (names) |name| {
        for (drawing.layers) |known| {
            if (std.mem.eql(u8, known, name)) break;
        } else return noLayer(vm, file_path, name, drawing.layers);
    };
    if (drawing.outlines.len == 0) return vm.fail(.ImportError, "DXF file '{s}' has no outline to read", .{file_path});
    return vm.allocateCrossSection(try evenOddNode(vm, drawing.outlines));
}

/// The names `val` gives, a String (or Symbol) or an Array of them; owned by vm.allocator.
fn layerNames(vm: *VM, val: value.Value) ![]const []const u8 {
    if (!val.isArray()) {
        const names = try vm.allocator.alloc([]const u8, 1);
        errdefer vm.allocator.free(names);
        names[0] = try arguments.requireName(vm, val, "import_dxf", "layers");
        return names;
    }
    const items = val.asArray().items.items;
    const names = try vm.allocator.alloc([]const u8, items.len);
    errdefer vm.allocator.free(names);
    for (items, names) |item, *name| name.* = try arguments.requireName(vm, item, "import_dxf", "a layer of layers");
    return names;
}

fn noLayer(vm: *VM, file_path: []const u8, name: []const u8, known: []const []const u8) error{RuntimeError} {
    var buffer: [256]u8 = undefined;
    var list: std.Io.Writer = .fixed(&buffer);
    for (known, 0..) |layer, i| list.print("{s}'{s}'", .{ if (i == 0) "" else ", ", layer }) catch break;
    return vm.fail(.ImportError, "DXF file '{s}' has no outline on a layer '{s}' (its layers: {s})", .{ file_path, name, list.buffered() });
}

/// The graph node of the region `outlines` fill by the even-odd rule: the union of the
/// outlines enclosed by none, less the union of those enclosed by one, with those enclosed
/// by two added back, and so on.
fn evenOddNode(vm: *VM, outlines: []const dxf_read.Outline) !u32 {
    const alloc = vm.allocator;
    const boxes = try alloc.alloc(path_mod.Bounds, outlines.len);
    defer alloc.free(boxes);
    for (outlines, boxes) |outline, *box| box.* = path_mod.bounds(outline.start, outline.segments);
    // How many others enclose each one, tested at a point of it (the outlines don't cross)
    const depths = try alloc.alloc(u32, outlines.len);
    defer alloc.free(depths);
    var deepest: u32 = 0;
    for (outlines, depths, 0..) |outline, *depth, i| {
        depth.* = 0;
        const p = outline.start;
        for (outlines, boxes, 0..) |other, box, j| {
            if (i == j or p[0] < box.min[0] or p[0] > box.max[0] or p[1] < box.min[1] or p[1] > box.max[1]) continue;
            if (path_mod.encloses(other.start, other.segments, p)) depth.* += 1;
        }
        deepest = @max(deepest, depth.*);
    }
    var nodes: std.ArrayList(u32) = .empty;
    defer nodes.deinit(alloc);
    var region: ?u32 = null;
    for (0..deepest + 1) |level| {
        nodes.clearRetainingCapacity();
        for (outlines, depths) |outline, depth| {
            if (depth == level) try nodes.append(alloc, try counterClockwiseNode(vm, outline));
        }
        if (nodes.items.len == 0) continue;
        const layer = try vm.dag_builder.addBalancedChain(.cs_union_op, nodes.items);
        region = if (region) |r| try vm.dag_builder.addBinary(if (level % 2 == 1) .cs_difference_op else .cs_union_op, r, layer) else layer;
    }
    return region.?;
}

/// The closed path node of `outline`, run counter-clockwise.
fn counterClockwiseNode(vm: *VM, outline: dxf_read.Outline) !u32 {
    if (path_mod.signedArea(outline.start, outline.segments) >= 0) return paths.closedPathNode(vm, outline.start, outline.segments, 0);
    const turned = try path_mod.reversed(vm.allocator, outline.start, outline.segments);
    defer vm.allocator.free(turned);
    return paths.closedPathNode(vm, outline.start, turned, 0);
}
