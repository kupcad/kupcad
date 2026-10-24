//! The preview frame (frame.zig) of a script's run: the model it left (its Solids and ghosts
//! as GLB, as `export_gltf` writes them, or its Sketches and Paths as SVG, as `export_svg`
//! does), the parts, the warnings, the parameters (the schema `kupcad doc` gives and the
//! values the run took) and why it failed, if it did. `ofRun` makes one from a VM right after
//! it ran, while it still holds what the run left; `ofFailure` one for a script that didn't
//! get to run (it doesn't parse or compile, or its host refused its parameter values), and
//! `ofImportFailure` one for a script a module it imports stopped.

const std = @import("std");
const frame = @import("frame.zig");
const VM = @import("../vm/vm.zig").VM;
const value = @import("../core/value.zig");
const Document = @import("../frontend/document.zig").Document;
const Diagnostic = @import("../core/errors.zig").Diagnostic;
const extractor = @import("../tools/doc/extractor.zig");
const model_mod = @import("../exporters/model.zig");
const export_mod = @import("../exporters/export.zig");
const parts_mod = @import("../exporters/parts.zig");
const MaterialDef = @import("../core/material.zig").MaterialDef;
const param_values = @import("../core/param_values.zig");
const stopwatch = @import("../core/stopwatch.zig");
const LinePosition = @import("../vm/run_report.zig").LinePosition;

/// What a frame says of a run that failed with no message of its own.
const FAILED_WITHOUT_MESSAGE = "the script failed";
/// The warning of a model whose Solids hold no triangle.
const EMPTY_MODEL = "the model's Solids are empty: there is nothing to show";

/// The script a frame is of.
pub const Script = struct {
    /// Its parse and its text, for its parameter schema.
    doc: *const Document,
    source: []const u8,
    /// What its host calls it, the header's `document`; null for none.
    name: ?[]const u8 = null,
};

/// A run of the script the VM has just finished.
pub const Run = struct {
    vm: *VM,
    /// It ended without an error; else the VM's last error says why.
    ok: bool,
    /// How long it ran, in nanoseconds.
    run_ns: u64,
};

/// The frame of `run`, owned by `allocator`. Showing the model can fail in the VM as an
/// export does (an engine that can't mesh, a last value that is no model): the frame then
/// says why, as for a failed run.
pub fn ofRun(allocator: std.mem.Allocator, script: Script, run: Run) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const vm = run.vm;
    var header = try headerOf(arena, script, try valuesOf(arena, vm));
    header.timing.runMs = stopwatch.milliseconds(run.run_ns);
    var warnings: std.ArrayList(frame.Warning) = .empty;
    for (vm.report.warnings.items) |w| try warnings.append(arena, warningOf(w.message, w.position));

    var clock = stopwatch.Stopwatch.start(vm.io);
    const view: Shown = if (run.ok) shown(arena, vm, &warnings) catch |err| switch (err) {
        // Raised in the VM: why is its last error
        error.RuntimeError => .failed,
        else => |e| return e,
    } else .failed;
    header.timing.renderMs = stopwatch.milliseconds(clock.lap());
    header.warnings = warnings.items;
    switch (view) {
        .failed => header.@"error" = failureOf(vm),
        .model => |m| {
            header.kind = m.kind;
            header.parts = m.parts;
            return frame.encode(allocator, header, m.body);
        },
    }
    return frame.encode(allocator, header, "");
}

/// The frame of a script that didn't get to run: its schema, as far as it parses, and why.
pub fn ofFailure(allocator: std.mem.Allocator, script: Script, failure: frame.Failure) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var header = try headerOf(arena_state.allocator(), script, .{});
    header.@"error" = failure;
    return frame.encode(allocator, header, "");
}

/// The header of `script`'s frame with the parameter values a run took, showing nothing yet.
fn headerOf(arena: std.mem.Allocator, script: Script, values: param_values.ParamValues) !frame.Header {
    return .{
        .document = script.name,
        .kind = .none,
        .params = .{ .schema = try extractor.extractSchema(arena, script.doc, script.source), .values = values },
        .timing = .{ .runMs = 0, .renderMs = 0 },
    };
}

/// The frame of a script that didn't run because the module it imports at `module_path`
/// failed, as `failure` says in that module's lines: the message names the module and the
/// place, and the line and column, which would be the script's, are left out.
pub fn ofImportFailure(allocator: std.mem.Allocator, script: Script, module_path: []const u8, failure: frame.Failure) ![]u8 {
    const message = if (failure.line) |line|
        try std.fmt.allocPrint(allocator, "{s}:{d}:{d}: {s}", .{ module_path, line, failure.column orelse 1, failure.message })
    else
        try std.fmt.allocPrint(allocator, "{s}: {s}", .{ module_path, failure.message });
    defer allocator.free(message);
    return ofFailure(allocator, script, .{ .message = message });
}

/// Why a script doesn't parse or compile: `diagnostic`, placed in `doc`.
pub fn failureOfDiagnostic(doc: *const Document, diagnostic: Diagnostic) frame.Failure {
    const at = doc.line_index.humanPosition(diagnostic.loc.offset);
    return .{ .message = diagnostic.message, .line = at.line, .column = at.column };
}

/// Why a run failed: the VM's last error, where it was, and the parameter it refused.
pub fn failureOf(vm: *const VM) frame.Failure {
    return .{
        .message = vm.last_error orelse FAILED_WITHOUT_MESSAGE,
        .line = lineOf(vm.last_error_position),
        .column = columnOf(vm.last_error_position),
        .param = vm.report.refused_param,
    };
}

/// What a frame shows of a run: its model (a kind of body, its parts, the body), or that
/// it failed.
const Shown = union(enum) {
    failed,
    model: struct { kind: frame.Kind, parts: []const frame.Part = &.{}, body: []const u8 = "" },
};

/// The model the run left: its Solids (and ghosts) as GLB, else its Sketches and Paths as
/// SVG, else nothing. Sketches beside Solids aren't shown, and Solids that are empty show
/// nothing: a warning says so. A document that ends in no model at all (a module of
/// definitions) shows its ghosts, or nothing, where an export would refuse it. Owned by
/// `arena`.
fn shown(arena: std.mem.Allocator, vm: *VM, warnings: *std.ArrayList(frame.Warning)) !Shown {
    const model: model_mod.Model = if (model_mod.isModel(model_mod.finalValue(vm))) try model_mod.collectModel(arena, vm) else .{ .ghosts = vm.display_list.items };
    const flat = model.sketches.items.len + model.paths.items.len;
    if (model.solids.items.len > 0 or model.ghosts.len > 0) {
        if (flat > 0) {
            const message = try arena.print("the preview shows the model's Solids; its {d} Sketches and Paths beside them aren't shown (export them as SVG or DXF to see them)", .{flat});
            try warnings.append(arena, warningOf(message, null));
        }
        const glb = export_mod.exportShapes(arena, vm, .glb, .{}, .{ .solids = model.solids.items, .ghosts = model.ghosts, .title = model.title }) catch |err| switch (err) {
            error.NoGeometry => {
                try warnings.append(arena, warningOf(EMPTY_MODEL, null));
                return .{ .model = .{ .kind = .none } };
            },
            else => |e| return e,
        };
        return .{ .model = .{ .kind = .@"3d", .parts = try partsOf(arena, vm, model.solids.items), .body = glb } };
    }
    if (flat > 0) {
        const svg = try export_mod.exportShapes(arena, vm, .svg, .{}, .{ .sketches = model.sketches.items, .paths = model.paths.items });
        return .{ .model = .{ .kind = .@"2d", .body = svg } };
    }
    return .{ .model = .{ .kind = .none } };
}

/// The parts `solids` are copies of, each with the names of its copies' nodes as the GLB
/// export gives them (parts.CopyNames, in the Solids' order).
fn partsOf(arena: std.mem.Allocator, vm: *VM, solids: []const value.Value) ![]const frame.Part {
    const grouping = try parts_mod.group(vm, arena, solids);
    var names = try parts_mod.CopyNames.init(arena, &grouping);
    const nodes = try arena.alloc(std.ArrayList([]const u8), grouping.parts.len);
    @memset(nodes, .empty);
    for (grouping.copies) |copy| try nodes[copy.part].append(arena, try names.next(arena, copy));
    const out = try arena.alloc(frame.Part, grouping.parts.len);
    for (grouping.parts, nodes, out) |part, part_nodes, *o| o.* = .{
        .name = part_nodes.items[0],
        .count = part.count,
        .nodes = part_nodes.items,
        .color = if (part.material) |m| try hexColor(arena, m) else null,
        .opacity = if (part.material) |m| m.alpha else 1,
    };
    return out;
}

/// "#rrggbb" of `material`'s colour.
fn hexColor(arena: std.mem.Allocator, material: MaterialDef) ![]const u8 {
    return arena.print("#{x:0>2}{x:0>2}{x:0>2}", .{ material.rgb[0], material.rgb[1], material.rgb[2] });
}

/// The value each parameter took in the run, in the order it declared them. A number no
/// JSON can hold (an infinite default) is left out.
fn valuesOf(arena: std.mem.Allocator, vm: *const VM) !param_values.ParamValues {
    var values: param_values.ParamValues = .{};
    for (vm.param_registry.items(.name), vm.param_registry.items(.current_value)) |name, v| {
        const taken = paramValue(v) orelse continue;
        try values.put(arena, name.asSymbol().chars, taken);
    }
    return values;
}

fn paramValue(v: value.Value) ?param_values.ParamValue {
    if (v.isNumber()) return if (std.math.isFinite(v.asNumber())) .{ .number = v.asNumber() } else null;
    if (v.isBool()) return .{ .boolean = v.asBool() };
    if (v.nameChars()) |text| return .{ .text = text };
    return null;
}

fn warningOf(message: []const u8, position: ?LinePosition) frame.Warning {
    return .{ .message = message, .line = lineOf(position), .column = columnOf(position) };
}

fn lineOf(position: ?LinePosition) ?u32 {
    return if (position) |p| p.line else null;
}

fn columnOf(position: ?LinePosition) ?u32 {
    return if (position) |p| p.column else null;
}
