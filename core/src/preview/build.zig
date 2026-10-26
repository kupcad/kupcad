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
/// The warning of a model whose Solids hold no triangle, or whose Sketches no outline.
const EMPTY_MODEL = "the model is empty: there is nothing to show";

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
    var header = try headerOf(arena, script);
    header.params.values = try valuesOf(arena, vm, header.params.schema);
    header.timing.runMs = stopwatch.milliseconds(run.run_ns);
    var warnings: std.ArrayList(frame.Warning) = .empty;
    for (vm.report.warnings.items) |w| try warnings.append(arena, warningOf(w.message, w.position));
    header.output = try textOf(arena, vm.report.output.items);
    header.outputCut = vm.report.output_cut;

    var clock = stopwatch.Stopwatch.start(vm.io);
    // What a run that still succeeded reported failed nothing: an error of showing it is new
    if (run.ok) vm.clearLastError();
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

/// `bytes` as text: a script prints what it likes, and a string that isn't UTF-8 would be
/// written as an array of numbers; each sequence that isn't one is U+FFFD.
fn textOf(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    return std.fmt.allocPrint(arena, "{f}", .{std.unicode.fmtUtf8(bytes)});
}

/// The frame of a script that didn't get to run: its schema, as far as it parses, and why.
pub fn ofFailure(allocator: std.mem.Allocator, script: Script, failure: frame.Failure) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var header = try headerOf(arena_state.allocator(), script);
    header.@"error" = failure;
    return frame.encode(allocator, header, "");
}

/// The header of `script`'s frame with its schema, showing nothing yet and no values taken.
fn headerOf(arena: std.mem.Allocator, script: Script) !frame.Header {
    return .{
        .document = script.name,
        .kind = .none,
        .params = .{ .schema = try extractor.extractSchema(arena, script.doc, script.source), .values = .{} },
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

/// The frame of a script that doesn't parse or compile, as `diagnostic` says in its lines.
pub fn ofDiagnostic(allocator: std.mem.Allocator, script: Script, diagnostic: Diagnostic) ![]u8 {
    return ofFailure(allocator, script, failureOfDiagnostic(script.doc, diagnostic));
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
        .path = vm.report.refused_path,
    };
}

/// What a frame shows of a run: its model (a kind of body, its parts, the body), or that
/// it failed.
const Shown = union(enum) {
    failed,
    model: struct { kind: frame.Kind, parts: []const frame.Part = &.{}, body: []const u8 = "" },
};

/// The model the run left: its Solids (and ghosts) as GLB, else its Sketches and Paths as
/// SVG, else nothing. Sketches beside Solids aren't shown, and a model that is empty (no
/// triangle, no outline) shows nothing: a warning says so, where an export raises. A
/// document that ends in no model at all (a module of definitions) shows its ghosts, or
/// nothing, where an export would refuse it. Owned by `arena`.
fn shown(arena: std.mem.Allocator, vm: *VM, warnings: *std.ArrayList(frame.Warning)) !Shown {
    const model: model_mod.Model = if (model_mod.isModel(vm.finalValue())) try model_mod.collectModel(arena, vm) else .{ .ghosts = vm.display_list.items };
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
        const drawing = try export_mod.drawingOf(arena, vm, model.sketches.items, &.{}, model.paths.items);
        if (drawing.bounds == null) {
            try warnings.append(arena, warningOf(EMPTY_MODEL, null));
            return .{ .model = .{ .kind = .none } };
        }
        return .{ .model = .{ .kind = .@"2d", .body = try export_mod.writeDrawing(arena, .svg, .{}, &drawing) } };
    }
    return .{ .model = .{ .kind = .none } };
}

/// The parts `solids` are copies of, each with the names of its copies' nodes as the GLB
/// export gives them (parts.CopyNames, in the Solids' order), and its measures where its
/// engine can take them.
fn partsOf(arena: std.mem.Allocator, vm: *VM, solids: []const value.Value) ![]const frame.Part {
    const grouping = try parts_mod.group(vm, arena, solids);
    var names = try parts_mod.CopyNames.init(arena, &grouping);
    const nodes = try arena.alloc(std.ArrayList([]const u8), grouping.parts.len);
    @memset(nodes, .empty);
    for (grouping.copies) |copy| try nodes[copy.part].append(arena, try names.next(arena, copy));
    const out = try arena.alloc(frame.Part, grouping.parts.len);
    for (grouping.parts, nodes, out) |part, part_nodes, *o| {
        const measured = try parts_mod.measuresOf(vm, part, .leave_out);
        o.* = .{
            .name = part_nodes.items[0],
            .count = part.count,
            .nodes = part_nodes.items,
            .color = if (part.material) |m| try hexColor(arena, m) else null,
            .opacity = if (part.material) |m| m.alpha else 1,
            .volume = if (measured) |m| m.volume else null,
            .size = if (measured) |m| m.size else null,
        };
    }
    return out;
}

/// "#rrggbb" of `material`'s colour.
fn hexColor(arena: std.mem.Allocator, material: MaterialDef) ![]const u8 {
    return arena.print("#{x:0>2}{x:0>2}{x:0>2}", .{ material.rgb[0], material.rgb[1], material.rgb[2] });
}

/// The value each of the script's own parameters (its schema's, in its order) took in the
/// run: the panel's, not one its imports declared. A parameter left nil, one holding a
/// number no JSON can hold (an infinite default), and one the run didn't reach are left out.
fn valuesOf(arena: std.mem.Allocator, vm: *const VM, schema: extractor.UiSchema) !param_values.ParamValues {
    var declared: std.StringHashMapUnmanaged(value.Value) = .empty;
    for (vm.param_registry.items(.name), vm.param_registry.items(.current_value)) |name, v| {
        try declared.put(arena, name.asSymbol().chars, v);
    }
    var values: param_values.ParamValues = .{};
    for (schema.parameters) |spec| {
        const taken = try paramValue(arena, declared.get(spec.name) orelse continue) orelse continue;
        try values.put(arena, spec.name, taken);
    }
    return values;
}

/// `v` as JSON gives a parameter's value (its text borrowed, its arrays and objects in
/// `arena`); null for nil and for what JSON can't hold.
fn paramValue(arena: std.mem.Allocator, v: value.Value) !?param_values.ParamValue {
    if (v.isNumber()) return if (std.math.isFinite(v.asNumber())) .{ .number = v.asNumber() } else null;
    if (v.isBool()) return .{ .boolean = v.asBool() };
    if (v.nameChars()) |text| return .{ .text = text };
    // param() read it, so it nests no deeper than a parameter's may
    if (v.isArray()) {
        const items = v.asArray().items.items;
        const elements = try arena.alloc(param_values.ParamValue, items.len);
        for (items, elements) |item, *element| element.* = try paramValue(arena, item) orelse return null;
        return .{ .array = elements };
    }
    if (!v.isMap()) return null;
    const map = v.asMap();
    const fields = try arena.alloc(param_values.ParamValue.Field, map.count());
    var entries = map.entries();
    var i: usize = 0;
    while (entries.next()) |entry| : (i += 1) {
        fields[i] = .{ .name = entry.key.nameChars() orelse return null, .value = try paramValue(arena, entry.value) orelse return null };
    }
    return .{ .object = fields };
}

/// A warning of the run as a frame places it, at its line and column (null for none).
pub fn warningOf(message: []const u8, position: ?LinePosition) frame.Warning {
    return .{ .message = message, .line = lineOf(position), .column = columnOf(position) };
}

fn lineOf(position: ?LinePosition) ?u32 {
    return if (position) |p| p.line else null;
}

fn columnOf(position: ?LinePosition) ?u32 {
    return if (position) |p| p.column else null;
}
