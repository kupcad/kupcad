//! The library's entry points for the CLI, the LSP and the WASM build: format, lint and fix
//! source (`formatDocument`, `checkDocument`, `fixCode`), extract the parameter schema
//! (`extractSchema`), and run a script and export its model (`buildModel`, `exportModelFromVm`).

const std = @import("std");
const builtin = @import("builtin");
const VM = @import("vm/vm.zig").VM;
const chunk = @import("vm/chunk.zig");
const value = @import("core/value.zig");
const Compiler = @import("compiler/compiler.zig").Compiler;
const registry = @import("stdlib/registry.zig");
const kernel = @import("kernel/kernel.zig");
const extractor = @import("tools/doc/extractor.zig");
const geom = @import("kernel/geometry_handle.zig");
const Vfs = @import("vfs/vfs.zig").Vfs;
const ReadOnlyVfs = @import("vfs/readonly.zig").ReadOnlyVfs;
const limits = @import("core/limits.zig");
const Formatter = @import("tools/fmt/formatter.zig").Formatter;
const equivalence = @import("tools/fmt/equivalence.zig");
const Linter = @import("tools/lint/linter.zig").Linter;
const stl_exporter = @import("exporters/3d/stl.zig");
const gltf_exporter = @import("exporters/3d/gltf.zig");
const step_exporter = @import("exporters/3d/step.zig");
const threemf_exporter = @import("exporters/3d/threemf.zig");
const obj_exporter = @import("exporters/3d/obj.zig");
const HandleScope = @import("vm/scope.zig").HandleScope;
const bom = @import("stdlib/bom.zig");

pub const UiSchema = extractor.UiSchema;
pub const FormatterConfig = @import("tools/fmt/config.zig").Config;
pub const Document = @import("core/document.zig").Document;
pub const LineIndex = @import("core/line_index.zig").LineIndex;
pub const LinterConfig = @import("tools/lint/config.zig").Config;
const suppressions = @import("tools/lint/suppressions.zig");
const fixer = @import("tools/lint/fixer.zig");
pub const LinterDiagnostic = @import("tools/lint/linter.zig").LinterDiagnostic;
pub const Diagnostic = @import("core/errors.zig").Diagnostic;
pub const ParamValues = @import("core/param_values.zig").ParamValues;
pub const ParamValue = @import("core/param_values.zig").ParamValue;

/// How many times fixCode re-checks and applies before it stops (as ESLint does): fixes
/// that keep making room for each other must still end.
const MAX_FIX_PASSES = 10;
/// How deep a model's Arrays of shapes inside Arrays are followed (an Array can hold itself).
const MAX_MODEL_NESTING = 64;
/// The most items an Array of the model may hold, so an item's number fits its path.
const MAX_MODEL_ITEMS = 1_000_000_000;

/// Formats a parsed Document; the caller owns the result. It is checked before it is
/// returned: it must parse, mean the same program (tools/fmt/equivalence.zig) and keep
/// every comment in order.
/// Otherwise the formatter has a bug, reported as error.FormatChangedProgram, and the
/// caller keeps the source as it was rather than overwrite it.
pub fn formatDocument(allocator: std.mem.Allocator, doc: *const Document, config: FormatterConfig) ![]const u8 {
    if (doc.diagnostics.len > 0) return error.SyntaxError;
    if (doc.tree.root == .none) return error.SyntaxError;
    var formatter = Formatter.forDocument(allocator, doc, config);
    defer formatter.deinit();
    try formatter.registerDefaultRules();
    const formatted = try formatter.format(&doc.tree, doc.tree.root);
    errdefer allocator.free(formatted);
    if (!try formatKeepsProgram(allocator, doc, formatted)) return error.FormatChangedProgram;
    return formatted;
}

/// Whether `formatted` parses, keeps `doc`'s comments in order and is the same program.
pub fn formatKeepsProgram(allocator: std.mem.Allocator, doc: *const Document, formatted: []const u8) !bool {
    var reparsed = try Document.parse(allocator, formatted);
    defer reparsed.deinit();
    if (reparsed.diagnostics.len > 0 or reparsed.comments.len != doc.comments.len) return false;
    for (doc.comments, reparsed.comments) |before, after| {
        if (!std.mem.eql(u8, before.lexeme, after.lexeme)) return false;
    }
    return equivalence.samePrograms(allocator, &doc.tree, &reparsed.tree);
}

/// Formats raw KupCAD source code (Convenience wrapper).
pub fn formatCode(allocator: std.mem.Allocator, source: []const u8, config: FormatterConfig) ![]const u8 {
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();
    return formatDocument(allocator, &doc, config);
}

/// Lints an already parsed Document and, when it parsed cleanly, compiles it, so a compile
/// error (such as assigning to `cube`) is reported by `kupcad check` and the editor just as
/// `kupcad build` would. Caller owns the returned array of diagnostics.
pub fn checkDocument(allocator: std.mem.Allocator, io: std.Io, doc: *const Document, config: LinterConfig) ![]LinterDiagnostic {
    var linter = Linter.init(allocator, config);
    defer linter.deinit();
    try linter.registerDefaultRules();
    try linter.checkDocument(doc);
    try suppressions.apply(allocator, &linter.diagnostics, doc.comments, &doc.line_index, config);
    if (doc.diagnostics.len == 0) {
        if (try compileError(allocator, io, doc)) |compile_error| {
            errdefer allocator.free(compile_error.message);
            try linter.diagnostics.append(allocator, .{ .loc = compile_error.loc, .severity = .@"error", .origin = .{ .error_code = compile_error.code }, .message = compile_error.message });
        }
    }
    // In source order, whichever rule or stage found them.
    std.mem.sort(LinterDiagnostic, linter.diagnostics.items, {}, struct {
        fn before(_: void, x: LinterDiagnostic, y: LinterDiagnostic) bool {
            return x.loc.offset < y.loc.offset;
        }
    }.before);
    return linter.diagnostics.toOwnedSlice(allocator);
}

/// Compiles `doc` (without running it) and returns its compile error, if any, with a
/// message the caller owns.
fn compileError(allocator: std.mem.Allocator, io: std.Io, doc: *const Document) !?Diagnostic {
    var vm = try VM.init(allocator, io);
    defer vm.deinit();
    vm.mute_errors = true;
    try registry.registerStandardLibrary(&vm);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(allocator);
    var comp = Compiler.forDocument(allocator, doc, &out_chunk, &vm);
    defer comp.deinit();
    comp.compile(doc.tree.root) catch |err| {
        if (err == error.OutOfMemory) return err;
        const found = comp.errorDiagnostic() orelse return null;
        return .{ .loc = found.loc, .code = found.code, .message = try allocator.dupe(u8, found.message) };
    };
    return null;
}

/// `source` with every safe lint fix applied (`kupcad check --fix`). It repeats until
/// nothing more applies (one fix can make room for another) and keeps a pass only if the
/// result has no more syntax or compile errors than before and builds the same model
/// (fixKeepsModel), so a fix can never break or change the part. Caller owns `source`;
/// `fixes` counts the findings resolved.
pub fn fixCode(allocator: std.mem.Allocator, io: std.Io, source: []const u8, config: LinterConfig) !FixResult {
    var current = try allocator.dupe(u8, source);
    errdefer allocator.free(current);
    var fixes: usize = 0;
    var pass: usize = 0;
    // The model of `source`, taken the first time a pass has something to apply.
    var original_model: ?u64 = null;
    var model_taken = false;
    while (pass < MAX_FIX_PASSES) : (pass += 1) {
        const diags = try checkCode(allocator, io, current, config);
        defer freeDiagnostics(allocator, diags);
        const applied = try fixer.applySafeFixes(allocator, current, diags) orelse break;
        errdefer allocator.free(applied.source);

        const after = try checkCode(allocator, io, applied.source, config);
        defer freeDiagnostics(allocator, after);
        if (!model_taken) {
            original_model = try modelFingerprint(allocator, io, source);
            model_taken = true;
        }
        if (errorCount(after) > errorCount(diags) or !try fixKeepsModel(allocator, io, original_model, applied.source)) {
            allocator.free(applied.source);
            return .{ .source = current, .fixes = fixes, .refused = true };
        }
        allocator.free(current);
        current = applied.source;
        fixes += applied.fixes;
    }
    return .{ .source = current, .fixes = fixes, .refused = false };
}

pub const FixResult = struct {
    source: []u8,
    fixes: usize,
    /// A pass was dropped because it would have added errors or changed the model (a bug
    /// in a rule's fix).
    refused: bool,
};

/// Whether `candidate` builds the model whose fingerprint is `original`. When the original
/// can't be told (its script fails, or it leaves a shape with no DAG node) there is nothing
/// to compare and only the error count guards the fix; a candidate that fails where the
/// original ran changed it.
pub fn fixKeepsModel(allocator: std.mem.Allocator, io: std.Io, original: ?u64, candidate: []const u8) !bool {
    const before = original orelse return true;
    const after = try modelFingerprint(allocator, io, candidate) orelse return false;
    return after == before;
}

/// A hash of the model `source` builds: its shapes' DAG node hashes (which cover every
/// operation, number and setting below them, by content, and need no kernel work), its
/// ghosts' meshes and its materials. Null when it can't be told: the script doesn't parse
/// or compile, fails, passes the interactive limits, or leaves a shape with no DAG node.
/// The script runs with every write discarded, so one that exports leaves no file, and
/// with its output dropped: `kupcad check --fix` printed what the script `puts`.
fn modelFingerprint(allocator: std.mem.Allocator, io: std.Io, source: []const u8) !?u64 {
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();
    if (doc.diagnostics.len > 0) return null;

    var vm = try VM.init(allocator, io);
    defer vm.deinit();
    vm.mute_errors = true;
    var sandbox = ReadOnlyVfs.init(vm.vfs, null);
    vm.vfs = sandbox.vfs();
    vm.line_index = &doc.line_index;
    vm.hooks.setLimit(limits.INTERACTIVE_INSTRUCTION_LIMIT);
    vm.setMemoryLimit(limits.INTERACTIVE_MEMORY_LIMIT);
    try registry.registerStandardLibrary(&vm);
    vm.host.print_handler = null; // puts, print, inspect, benchmark

    var program = chunk.Chunk.init();
    defer program.free(allocator);
    var compiler = Compiler.forDocument(allocator, &doc, &program, &vm);
    defer compiler.deinit();
    compiler.compile(doc.tree.root) catch return null;
    if (vm.interpret(&program) != .ok) return null;

    var hasher = std.hash.Wyhash.init(0);
    if (vm.stack_top > 0 and !hashShapes(&hasher, &vm, vm.stack[0], 0)) return null;
    for (vm.display_list.items) |ghost| {
        if (!(kernel.hashMesh(&hasher, allocator, ghost) catch return null)) hasher.update(std.mem.asBytes(&ghost.engine));
    }
    for (vm.materials.items) |m| m.hashInto(&hasher);
    return hasher.final();
}

/// modelFingerprint, for tests that compare models (api_test.zig).
pub fn modelFingerprintForTest(allocator: std.mem.Allocator, io: std.Io, source: []const u8) !?u64 {
    if (!builtin.is_test) @compileError("tests only");
    return modelFingerprint(allocator, io, source);
}

/// Feeds the DAG hashes of the shapes in `val` (a shape, or an Array or assembly of them)
/// to `hasher`; false for a shape that has no DAG node.
fn hashShapes(hasher: *std.hash.Wyhash, vm: *const VM, val: value.Value, depth: usize) bool {
    const hashes = vm.dag_builder.node_hashes.items;
    const node: ?u32 = if (val.isGeometry()) val.asGeometry().dag_idx else if (val.isCrossSection()) val.asCrossSection().dag_idx else null;
    if (node) |idx| {
        if (idx >= hashes.len) return false;
        hasher.update(std.mem.asBytes(&hashes[idx]));
        return true;
    }
    const items: []const value.Value = if (val.isAssembly()) val.asAssembly().parts.items.items else if (val.isArray()) val.asArray().items.items else return true;
    if (depth >= MAX_MODEL_NESTING) return false;
    for (items) |item| {
        if (!hashShapes(hasher, vm, item, depth + 1)) return false;
    }
    return true;
}

/// Syntax and compile errors: the findings no rule made.
fn errorCount(diags: []const LinterDiagnostic) usize {
    var n: usize = 0;
    for (diags) |d| {
        if (d.origin == .error_code) n += 1;
    }
    return n;
}

/// Lints raw KupCAD source code (Convenience wrapper).
pub fn checkCode(allocator: std.mem.Allocator, io: std.Io, source: []const u8, config: LinterConfig) ![]LinterDiagnostic {
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();
    return checkDocument(allocator, io, &doc, config);
}

/// The parameters a parsed document declares (`param(:name, default:, validate:)`) and its
/// `# @title`, `# @description` and `# @author` comments, as `kupcad doc` prints them.
pub fn extractSchema(allocator: std.mem.Allocator, doc: *const Document, source: []const u8) !UiSchema {
    return extractor.extractSchema(allocator, doc, source);
}

/// Puts `values` in the VM's `params` Map (which registering the standard library makes),
/// keyed by symbol, where `param(:name)` finds and reads them by its declared type: a text
/// value goes in as a String.
pub fn injectParams(vm: *VM, values: *const ParamValues) !void {
    if (values.map.count() == 0) return;
    const params_map = (vm.globals.get("params") orelse return).asMap();
    for (values.map.keys(), values.map.values()) |name, v| {
        // Each allocation may collect: the key and the value are rooted until the Map holds them
        const key = try vm.allocateSymbol(name);
        vm.push(key);
        defer _ = vm.pop();
        const val: value.Value = switch (v) {
            .number => |n| value.Value.initNumber(n),
            .boolean => |b| value.Value.initBool(b),
            .text => |t| try vm.allocateString(t),
        };
        vm.push(val);
        defer _ = vm.pop();
        try params_map.map.put(vm.gc.trackingAllocator(), key, val);
    }
}

/// The meshes of the model the script left: its ghosts (the display list), then its
/// Solids (collectModel), each evaluated. The handles are borrowed (see VM.ensureConcrete).
pub fn modelParts(allocator: std.mem.Allocator, vm: *VM, out: *std.ArrayList(geom.GeometryHandle)) !void {
    var model = try collectModel(allocator, vm);
    defer model.deinit(allocator);
    try out.appendSlice(allocator, model.ghosts);
    for (model.solids.items) |part| try out.append(allocator, try vm.ensureConcrete(part));
}

/// The shapes the script left as its model: its final value, a Solid or a Sketch, an
/// Assembly's parts, or an Array's items, Arrays inside it included (they were dropped).
/// `collectModel` fills it and `requireExportable` says whether a format can hold it.
pub const Model = struct {
    solids: std.ArrayList(value.Value) = .empty,
    sketches: std.ArrayList(value.Value) = .empty,
    /// The ghosts the script showed (the display list; borrowed from the VM).
    ghosts: []const geom.GeometryHandle = &.{},
    /// The model's name: its Assembly's, if it is one.
    title: ?[]const u8 = null,

    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        self.solids.deinit(allocator);
        self.sketches.deinit(allocator);
    }
};

/// The model the script left, from its final value. A value that is no model raises in
/// the VM (a TypeError saying what it is) and fails with error.RuntimeError: an item that
/// isn't a shape, such as a Number, was silently left out, and nested Arrays with it.
pub fn collectModel(allocator: std.mem.Allocator, vm: *VM) !Model {
    var model: Model = .{ .ghosts = vm.display_list.items };
    errdefer model.deinit(allocator);
    if (vm.stack_top == 0) return model;
    const final_val = vm.stack[0];
    if (final_val.isNil()) return model;
    if (final_val.isAssembly()) model.title = final_val.asAssembly().name.chars;
    var path = ItemPath{};
    if (!try collectShapes(allocator, vm, &model, final_val, &path)) {
        return vm.fail(.TypeError, "the script's last value ({s}) is not a model: end it with a Solid, a Sketch, an Assembly or an Array of them", .{vm.typeName(final_val)});
    }
    return model;
}

/// Where an item is in the model's Arrays, for an error naming it: "item 2", "item 2.1".
const ItemPath = struct {
    buf: [MAX_MODEL_NESTING * ITEM_PATH_DIGITS]u8 = undefined,
    len: usize = 0,

    const ITEM_PATH_DIGITS = 12; // ".", then the digits of an index up to MAX_MODEL_ITEMS

    fn push(self: *ItemPath, index: usize) void {
        const written = std.fmt.bufPrint(self.buf[self.len..], "{s}{d}", .{ if (self.len == 0) "" else ".", index }) catch unreachable;
        self.len += written.len;
    }

    fn text(self: *const ItemPath) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Adds the shapes of `val` to `model`: a Solid, a Sketch, an Assembly's parts, or an
/// Array's items (recursively). False for a value that is none of those at the top; inside
/// an Array, such a value raises a TypeError naming its item.
fn collectShapes(allocator: std.mem.Allocator, vm: *VM, model: *Model, val: value.Value, path: *ItemPath) !bool {
    if (val.isGeometry()) {
        try model.solids.append(allocator, val);
    } else if (val.isCrossSection()) {
        try model.sketches.append(allocator, val);
    } else if (val.isAssembly()) {
        for (val.asAssembly().parts.items.items) |part| try model.solids.append(allocator, part);
    } else if (val.isArray()) {
        if (path.len >= MAX_MODEL_NESTING * (ItemPath.ITEM_PATH_DIGITS - 1)) {
            return vm.fail(.ValueError, "the model's Arrays nest deeper than {d} levels", .{MAX_MODEL_NESTING});
        }
        for (val.asArray().items.items, 1..) |item, index| {
            if (index > MAX_MODEL_ITEMS) return vm.fail(.ValueError, "the model's Array holds more than {d} items", .{MAX_MODEL_ITEMS});
            const mark = path.len;
            defer path.len = mark;
            path.push(index);
            if (!try collectShapes(allocator, vm, model, item, path)) {
                return vm.fail(.TypeError, "the model's item {s} ({s}) is not a shape: a model holds Solids, Sketches and Arrays of them", .{ path.text(), vm.typeName(item) });
            }
        }
    } else return false;
    return true;
}

/// Whether `format` can hold `model`; raises in the VM (and fails with error.RuntimeError)
/// when it can't: a 3D format refuses a Sketch (extrude it) and a model with no Solid,
/// unless the format shows ghosts and there are some.
pub fn requireExportable(vm: *VM, model: *const Model, format: ExportFormat) !void {
    comptime for (std.enums.values(ExportFormat)) |f| {
        if (f.dimension() == .@"2d") @compileError("requireExportable has no rules for a 2D format yet");
    };
    switch (format.dimension()) {
        .@"2d" => unreachable,
        .@"3d" => {
            if (model.sketches.items.len > 0) {
                const which = if (model.solids.items.len == 0 and model.sketches.items.len == 1) "is" else "holds";
                return vm.fail(.TypeError, "the model {s} a Sketch, which {s} (a 3D format) can't hold: extrude it (.extrude(h)) to a Solid", .{ which, @tagName(format) });
            }
            if (model.solids.items.len == 0 and !(format.showsGhosts() and model.ghosts.len > 0)) {
                return vm.fail(.GeometryError, "the model holds no Solid: nothing to write as {s}", .{@tagName(format)});
            }
        },
    }
}

/// The parts list (stdlib/bom.zig) of the model the script left (collectModel), as
/// `kupcad build --bom` writes it; raises in the VM when the model holds no Solid.
pub fn billOfMaterials(allocator: std.mem.Allocator, vm: *VM) ![]u8 {
    var model = try collectModel(allocator, vm);
    defer model.deinit(allocator);
    if (model.solids.items.len == 0) return vm.fail(.GeometryError, "the model holds no Solid: nothing for the parts list", .{});
    const parts = try bom.collect(vm, allocator, model.solids.items);
    defer allocator.free(parts);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try bom.writeJson(allocator, &out.writer, parts);
    return out.toOwnedSlice();
}

/// The formats a model exports to. The tag names are what `kupcad build --format` and the
/// browser build call them; the format travelled as a string, compared at every use. What
/// each can hold and needs is read from here (its dimension, extensions, Draco, engine),
/// where it was spread over the CLI's tables and the exporters' checks.
pub const ExportFormat = enum {
    stl,
    glb,
    gltf,
    step,
    /// 3D Manufacturing Format: each part once, placed once per copy (exporters/3d/threemf.zig).
    @"3mf",
    /// Wavefront OBJ: an object per Solid, in millimetres and Z up (exporters/3d/obj.zig).
    obj,

    /// What a format holds: a 3D format the model's Solids, a 2D one its Sketches.
    pub const Dimension = enum { @"2d", @"3d" };

    /// "stl, glb, gltf, step, 3mf", for messages.
    pub const NAMES = blk: {
        var list: []const u8 = "";
        for (@typeInfo(ExportFormat).@"enum".field_names, 0..) |name, i| list = list ++ (if (i == 0) "" else ", ") ++ name;
        break :blk list;
    };

    /// ".stl, .glb, .gltf, .step, .stp, .3mf", for messages.
    pub const EXTENSIONS = blk: {
        var list: []const u8 = "";
        for (std.enums.values(ExportFormat)) |format| {
            for (format.extensions()) |ext| list = list ++ (if (list.len == 0) "" else ", ") ++ ext;
        }
        break :blk list;
    };

    /// The format named `name`, or null for a name that is none.
    pub fn parse(name: []const u8) ?ExportFormat {
        return std.meta.stringToEnum(ExportFormat, name);
    }

    /// The format an output file's extension (`.stl`, in any case) implies, or null.
    pub fn forExtension(ext: []const u8) ?ExportFormat {
        for (std.enums.values(ExportFormat)) |format| {
            for (format.extensions()) |candidate| {
                if (std.ascii.eqlIgnoreCase(ext, candidate)) return format;
            }
        }
        return null;
    }

    pub fn dimension(self: ExportFormat) Dimension {
        return switch (self) {
            .stl, .glb, .gltf, .step, .@"3mf", .obj => .@"3d",
        };
    }

    /// The file extensions written in it, the usual one first (`extension`).
    pub fn extensions(self: ExportFormat) []const []const u8 {
        return switch (self) {
            .stl => &.{".stl"},
            .glb => &.{".glb"},
            .gltf => &.{".gltf"},
            .step => &.{ ".step", ".stp" },
            .@"3mf" => &.{".3mf"},
            .obj => &.{".obj"},
        };
    }

    /// The extension a file written in it gets, with its dot.
    pub fn extension(self: ExportFormat) []const u8 {
        return self.extensions()[0];
    }

    /// Whether a material library (`.mtl`) can go beside it: OBJ's.
    pub fn supportsMaterialLibrary(self: ExportFormat) bool {
        return switch (self) {
            .obj => true,
            .stl, .glb, .gltf, .step, .@"3mf" => false,
        };
    }

    /// Whether its meshes can be Draco-compressed (a glTF extension).
    pub fn supportsDraco(self: ExportFormat) bool {
        return switch (self) {
            .glb, .gltf => true,
            .stl, .step, .@"3mf", .obj => false,
        };
    }

    /// Whether it holds the ghosts the script showed beside the model: the viewer's
    /// formats do, a file for a slicer or a CAD package doesn't.
    pub fn showsGhosts(self: ExportFormat) bool {
        return switch (self) {
            .glb, .gltf => true,
            .stl, .step, .@"3mf", .obj => false,
        };
    }

    /// The engine the script must run on for it, if it needs one: STEP needs exact
    /// B-Rep geometry, not meshes.
    pub fn requiredEngine(self: ExportFormat) ?geom.EngineType {
        return switch (self) {
            .step => .brep_native,
            .stl, .glb, .gltf, .@"3mf", .obj => null,
        };
    }
};

/// How a model is exported, beyond its format: what `kupcad build`'s flags ask for.
pub const ExportOptions = struct {
    /// Compress glb and gltf meshes with Draco.
    draco: bool = false,
    /// The material library an OBJ names (`mtllib`), written by `exportMaterialLibrary`;
    /// null for an OBJ without materials.
    mtl_name: ?[]const u8 = null,
};

/// The material library (`.mtl`) of the model: the script's materials, as an OBJ written
/// with `ExportOptions.mtl_name` refers to them.
pub fn exportMaterialLibrary(allocator: std.mem.Allocator, vm: *const VM) ![]u8 {
    return obj_exporter.buildMaterialLibrary(allocator, vm.materials.items);
}

/// Where an OBJ's material library goes: beside it, named after it (part.obj's is
/// part.mtl). Caller owns the result.
pub fn materialLibraryPath(allocator: std.mem.Allocator, obj_path: []const u8) ![]u8 {
    return allocator.print("{s}.mtl", .{obj_path[0 .. obj_path.len - std.fs.path.extension(obj_path).len]});
}

/// The model the script left (collectModel) in `format`, its ghosts (the display list)
/// beside it where the format shows them. A failure the script can read about (a model the
/// format can't hold, an engine that can't mesh, a failed union) is raised in the VM first,
/// so `vm.last_error` says what went wrong.
pub fn exportModelFromVm(
    allocator: std.mem.Allocator,
    vm: *VM,
    format: ExportFormat,
    options: ExportOptions,
) ![]const u8 {
    var model = try collectModel(allocator, vm);
    defer model.deinit(allocator);
    try requireExportable(vm, &model, format);
    return exportSolids(allocator, vm, format, options, model.solids.items, model.ghosts, model.title);
}

/// `solids` (rooted by the caller), with the meshes of `ghosts`, in `format`; `title` names
/// a 3MF model. error.NoGeometry when what is written has no triangle.
fn exportSolids(
    allocator: std.mem.Allocator,
    vm: *VM,
    format: ExportFormat,
    options: ExportOptions,
    solids: []const value.Value,
    ghosts: []const geom.GeometryHandle,
    title: ?[]const u8,
) ![]const u8 {
    switch (format) {
        // The parts once each, placed per copy: the Solids themselves, not their meshes. The
        // ghosts are the viewer's, as in an STL.
        .@"3mf" => return threemf_exporter.build(allocator, vm, solids, title),
        .obj => return obj_exporter.build(allocator, vm, solids, title, options.mtl_name),
        .step => {
            var handles = try handlesOf(allocator, vm, solids, ghosts);
            defer handles.deinit(allocator);
            try step_exporter.requireExactParts(vm, handles.items);
            return step_exporter.buildStepBuffer(allocator, handles.items);
        },
        .stl, .glb, .gltf => {
            var handles = try handlesOf(allocator, vm, solids, ghosts);
            defer handles.deinit(allocator);
            // Refuse parts the engine can't tessellate before any work on them.
            for (handles.items) |h| try vm.requireFeature(h.engine, .mesh);
            // STL holds one mesh: the model's parts are united, the ghosts left out.
            if (format == .stl) return stl_exporter.buildStlOfParts(allocator, vm, handles.items[ghosts.len..]);
            const container: gltf_exporter.Container = if (format == .gltf) .gltf else .glb;
            return gltf_exporter.buildGltfBuffer(allocator, vm, handles.items, options.draco, container);
        },
    }
}

/// `ghosts`, then the meshes of `solids` (evaluated; borrowed, see VM.ensureConcrete).
fn handlesOf(allocator: std.mem.Allocator, vm: *VM, solids: []const value.Value, ghosts: []const geom.GeometryHandle) !std.ArrayList(geom.GeometryHandle) {
    var handles: std.ArrayList(geom.GeometryHandle) = .empty;
    errdefer handles.deinit(allocator);
    try handles.ensureTotalCapacity(allocator, ghosts.len + solids.len);
    handles.appendSliceAssumeCapacity(ghosts);
    for (solids) |solid| handles.appendAssumeCapacity(try vm.ensureConcrete(solid));
    return handles;
}

/// One file `kupcad build --split` writes: a part of the model, as made (no placement).
pub const PartFile = struct {
    /// The part's name (the geometry graph's), or null when it has none.
    name: ?[]const u8,
    /// How many copies of it the model holds.
    count: u32,
    /// Owned by the allocator `exportPartsFromVm` was given.
    bytes: []const u8,
};

/// Each part of the model's parts list (stdlib/bom.zig) in `format`, without its placement:
/// a file to print each from. Raises in the VM when the format can't hold the model
/// (requireExportable; a split has no ghosts to show).
pub fn exportPartsFromVm(allocator: std.mem.Allocator, vm: *VM, format: ExportFormat, options: ExportOptions) ![]PartFile {
    var model = try collectModel(allocator, vm);
    defer model.deinit(allocator);
    model.ghosts = &.{};
    try requireExportable(vm, &model, format);
    const grouping = try bom.group(vm, allocator, model.solids.items);
    defer grouping.deinit(allocator);

    var files: std.ArrayList(PartFile) = .empty;
    errdefer freePartFiles(allocator, files.items);
    defer files.deinit(allocator);
    for (grouping.parts) |part| {
        // Rooted while it is evaluated and written; a scope, as an error raised in it
        // unwinds the stack
        var scope = HandleScope.init(vm);
        defer scope.deinit();
        const made = try bom.madeOf(vm, part);
        vm.push(made);
        const bytes = try exportSolids(allocator, vm, format, options, &.{made}, &.{}, part.name);
        errdefer allocator.free(bytes);
        try files.append(allocator, .{ .name = part.name, .count = part.count, .bytes = bytes });
    }
    return files.toOwnedSlice(allocator);
}

pub fn freePartFiles(allocator: std.mem.Allocator, files: []const PartFile) void {
    for (files) |file| allocator.free(file.bytes);
}

/// Why a build failed, in words a script author can act on. Filled by
/// `buildModel` (BuildOptions.diagnostic); `message` is owned by the allocator passed to it.
pub const BuildDiagnostic = struct {
    /// "line:col: message" for a syntax error, or the error as the CLI prints it
    /// (e.g. "RuntimeError: ...") when running or exporting the script failed.
    /// Null when the failure has no message (e.g. out of memory or an unsupported format).
    message: ?[]u8 = null,

    pub fn deinit(self: *BuildDiagnostic, allocator: std.mem.Allocator) void {
        if (self.message) |msg| allocator.free(msg);
        self.* = .{};
    }
};

/// Renders a parse diagnostic as "line:col: message" with the 1-based line and UTF-8 byte
/// column that `kupcad check` prints. Caller owns the returned slice.
pub fn formatDiagnostic(allocator: std.mem.Allocator, line_index: *const LineIndex, diagnostic: Diagnostic) ![]u8 {
    return diagnostic.formatLine(allocator, line_index);
}

/// How buildModel builds: what it exports to, and what it runs the script with.
pub const BuildOptions = struct {
    format: ExportFormat,
    /// Compress glb and gltf meshes with Draco.
    draco: bool = false,
    /// Values for `param(:name, ...)`, as `-p` and `-P` give them.
    params: ?*const ParamValues = null,
    /// The filesystem imports and exports go through (the native one when null).
    vfs: ?Vfs = null,
    /// When the build fails with a message, `diagnostic.message` is set to it. Pass a
    /// fresh `.{}`.
    diagnostic: ?*BuildDiagnostic = null,
};

/// Runs `source` and exports the resulting geometry as `options.format`. Caller owns the
/// bytes. Fails with error.SyntaxError if the script does not parse cleanly. It took its
/// options as eight positional parameters, in two functions.
pub fn buildModel(allocator: std.mem.Allocator, io: std.Io, source: []const u8, options: BuildOptions) ![]const u8 {
    const format = options.format;
    const diagnostic = options.diagnostic;
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();

    // The parser recovers by dropping what it cannot read, so compiling the tree anyway
    // would export a model with statements silently missing.
    if (doc.diagnostics.len > 0) {
        if (diagnostic) |d| d.message = formatDiagnostic(allocator, &doc.line_index, doc.diagnostics[0]) catch null;
        return error.SyntaxError;
    }

    var vm = try VM.init(allocator, io);
    defer vm.deinit();

    if (options.vfs) |vfs| vm.vfs = vfs;
    vm.line_index = &doc.line_index;
    try registry.registerStandardLibrary(&vm);

    if (format.requiredEngine()) |engine| {
        var settings = vm.config();
        settings.engine = engine;
        try vm.setConfig(settings);
    }

    if (options.params) |params| try injectParams(&vm, params);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(allocator);

    var comp = Compiler.forDocument(allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    comp.compile(doc.tree.root) catch |err| {
        // Reported like a syntax error: `cube = 5` used to give only "error.ProtectedSymbol".
        if (diagnostic) |d| if (comp.errorDiagnostic()) |compile_error| {
            d.message = formatDiagnostic(allocator, &doc.line_index, compile_error) catch null;
        };
        return err;
    };

    const result = vm.interpret(&out_chunk);
    if (result != .ok) {
        if (diagnostic) |d| d.message = dupeVmError(allocator, &vm);
        return error.RuntimeError;
    }
    // Whatever was reported during a run that still succeeded did not fail it.
    vm.clearLastError();

    // Geometry is evaluated lazily, so kernel errors (e.g. the mesh budget) surface here.
    return exportModelFromVm(allocator, &vm, format, .{ .draco = options.draco }) catch |err| {
        if (diagnostic) |d| d.message = dupeVmError(allocator, &vm);
        return err;
    };
}

/// Copies the VM's record of the error that failed it; null if there is none or on OOM,
/// since the caller is already failing and the message is only a courtesy.
fn dupeVmError(allocator: std.mem.Allocator, vm: *const VM) ?[]u8 {
    const msg = vm.last_error orelse return null;
    return allocator.dupe(u8, msg) catch null;
}

/// Safely frees an array of LinterDiagnostics and their inner allocated strings.
pub fn freeDiagnostics(allocator: std.mem.Allocator, diags: []LinterDiagnostic) void {
    for (diags) |d| d.deinit(allocator);
    allocator.free(diags);
}
