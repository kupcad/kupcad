//! `import_dxf` and `import_svg`: a drawing's outlines as a Sketch, or with `paths: true`
//! its open lines (a laser's score lines, which enclose nothing) as Paths. The readers
//! (exporters/2d/dxf_read.zig, svg_read.zig) give both; each outline becomes a closed path
//! of the geometry graph, its arcs known to a drawing, and they nest by the even-odd rule,
//! as a laser cutter reads a drawing: an outline inside one other is a hole, inside two an
//! island in the hole, and so on.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const HandleScope = @import("../vm/scope.zig").HandleScope;
const arguments = @import("arguments.zig");
const Signature = @import("signature.zig").Signature;
const limits = @import("../core/limits.zig");
const path_mod = @import("../core/path.zig");
const paths = @import("paths.zig");
const dxf_read = @import("../exporters/2d/dxf_read.zig");
const svg_read = @import("../exporters/2d/svg_read.zig");
const Diagnostic = @import("../exporters/diagnostic.zig").Diagnostic;
const file_import = @import("file_import.zig");

pub const IMPORT_DXF = Signature{ .positional = &.{"path"}, .keywords = &.{ "layers", "tolerance", "paths" }, .sizes = &.{"tolerance"} };
pub const IMPORT_SVG = Signature{ .positional = &.{"path"}, .keywords = &.{ "tolerance", "paths" }, .sizes = &.{"tolerance"} };

/// `import_dxf(path, layers:, tolerance:, paths:)`: the Sketch the DXF file's outlines
/// fill, on the `layers:` named (a String or an Array of them; every layer without it),
/// pieces whose ends are within `tolerance:` (the active tolerance without it) joined; with
/// `paths: true`, its open lines (the joined pieces that don't close) as an Array of
/// Paths. What `import plate from "./plate.dxf"` calls.
pub fn nativeImportDxf(vm: *VM, args: []const value.Value) !value.Value {
    const Opts = struct { layers: ?value.Value = null, tolerance: ?f64 = null, paths: bool = false };
    const parsed = try arguments.parseKwargsSubset(Opts, IMPORT_DXF.keywords, vm, args, "import_dxf");
    const file_path, const tolerance = try pathAndTolerance(vm, parsed.positional, parsed.opts.tolerance, "import_dxf", "a DXF file");
    const layers = if (parsed.opts.layers) |v| try layerNames(vm, v) else null;
    defer if (layers) |names| vm.allocator.free(names);

    const file = try file_import.read(vm, file_path, "DXF", limits.MAX_DRAWING_BYTES);
    defer vm.allocator.free(file);
    var diag: Diagnostic = .{};
    var drawing = dxf_read.read(vm.allocator, file, .{ .tolerance = tolerance, .layers = layers, .keep_open = parsed.opts.paths }, &diag) catch |err| {
        return file_import.unreadable(vm, err, file_path, "DXF", &diag);
    };
    defer drawing.deinit();
    if (layers) |names| for (names) |name| {
        for (drawing.layers) |known| {
            if (std.mem.eql(u8, known, name)) break;
        } else return noLayer(vm, file_path, name, drawing.layers);
    };
    if (parsed.opts.paths) return pathsOf(vm, drawing.open_paths, file_path, "DXF");
    return sketchOf(vm, drawing.outlines, file_path, "DXF");
}

/// `import_svg(path, tolerance:, paths:)`: the Sketch the SVG file's shapes fill, a
/// subpath whose ends are within `tolerance:` (the active tolerance without it) closed;
/// with `paths: true`, its strokes alone (the open subpaths that aren't filled, and its
/// lines) as an Array of Paths. What `import logo from "./logo.svg"` calls.
pub fn nativeImportSvg(vm: *VM, args: []const value.Value) !value.Value {
    const parsed = try arguments.parseKwargsSubset(struct { tolerance: ?f64 = null, paths: bool = false }, IMPORT_SVG.keywords, vm, args, "import_svg");
    const file_path, const tolerance = try pathAndTolerance(vm, parsed.positional, parsed.opts.tolerance, "import_svg", "an SVG file");
    const file = try file_import.read(vm, file_path, "SVG", limits.MAX_DRAWING_BYTES);
    defer vm.allocator.free(file);
    var diag: Diagnostic = .{};
    var drawing = svg_read.read(vm.allocator, file, .{ .tolerance = tolerance }, &diag) catch |err| {
        return file_import.unreadable(vm, err, file_path, "SVG", &diag);
    };
    defer drawing.deinit();
    if (parsed.opts.paths) return pathsOf(vm, drawing.open_paths, file_path, "SVG");
    return sketchOf(vm, drawing.outlines, file_path, "SVG");
}

/// The path an import was given (its one positional argument, the path of `file`) and its
/// tolerance, the active one unless `given`.
fn pathAndTolerance(vm: *VM, positional: []const value.Value, given: ?f64, comptime method: []const u8, comptime file: []const u8) !struct { []const u8, f64 } {
    if (positional.len != 1) return vm.fail(.ArgumentError, method ++ " expects the path of " ++ file, .{});
    const file_path = try arguments.requireName(vm, positional[0], method, "path");
    const tolerance = given orelse vm.config().tolerance;
    try arguments.requirePositive(vm, tolerance, method, "tolerance");
    return .{ file_path, tolerance };
}

/// The Sketch of a drawing's outlines, an ImportError when it has none.
fn sketchOf(vm: *VM, outlines: []const path_mod.Run, file_path: []const u8, comptime format: []const u8) !value.Value {
    if (outlines.len == 0) return vm.fail(.ImportError, format ++ " file '{s}' has no outline to read", .{file_path});
    return vm.allocateCrossSection(try evenOddNode(vm, outlines));
}

/// A drawing's open lines as an Array of Paths, in the file's order; an ImportError when
/// it has none.
fn pathsOf(vm: *VM, open_paths: []const path_mod.Run, file_path: []const u8, comptime format: []const u8) !value.Value {
    if (open_paths.len == 0) return vm.fail(.ImportError, format ++ " file '{s}' has no open path to read", .{file_path});
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    const list = try vm.gc.allocateArray(vm);
    vm.push(value.Value.initObj(&list.obj));
    for (open_paths) |run| {
        const p = try vm.allocatePath(run.start, run.segments, null, null);
        try list.items.append(vm.gc.trackingAllocator(), p);
    }
    return value.Value.initObj(&list.obj);
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
fn evenOddNode(vm: *VM, outlines: []const path_mod.Run) !u32 {
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
            if (depth == level) try nodes.append(alloc, try paths.closedPathNode(vm, outline.start, outline.segments, 0));
        }
        if (nodes.items.len == 0) continue;
        const layer = try vm.dag_builder.addBalancedChain(.cs_union_op, nodes.items);
        region = if (region) |r| try vm.dag_builder.addBinary(if (level % 2 == 1) .cs_difference_op else .cs_union_op, r, layer) else layer;
    }
    return region.?;
}
