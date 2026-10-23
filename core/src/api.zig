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
const Vfs = @import("vfs/vfs.zig").Vfs;
const ReadOnlyVfs = @import("vfs/readonly.zig").ReadOnlyVfs;
const limits = @import("core/limits.zig");
const Formatter = @import("tools/fmt/formatter.zig").Formatter;
const equivalence = @import("tools/fmt/equivalence.zig");
const Linter = @import("tools/lint/linter.zig").Linter;
const format_mod = @import("exporters/format.zig");
const model_mod = @import("exporters/model.zig");
const export_mod = @import("exporters/export.zig");

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

// The export layer (exporters/format.zig, model.zig, export.zig), for the CLI and the
// browser build
pub const ExportFormat = format_mod.ExportFormat;
pub const ExportOptions = format_mod.ExportOptions;
pub const Model = model_mod.Model;
pub const collectModel = model_mod.collectModel;
pub const modelParts = model_mod.modelParts;
pub const billOfMaterials = model_mod.billOfMaterials;
pub const exportModelFromVm = export_mod.exportModelFromVm;
pub const PartFile = export_mod.PartFile;
pub const exportPartsFromVm = export_mod.exportPartsFromVm;
pub const freePartFiles = export_mod.freePartFiles;
pub const exportMaterialLibrary = export_mod.exportMaterialLibrary;
pub const materialLibraryPath = export_mod.materialLibraryPath;

/// How many times fixCode re-checks and applies before it stops (as ESLint does): fixes
/// that keep making room for each other must still end.
const MAX_FIX_PASSES = 10;

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
    if (val.isPath()) {
        const p = val.asPath();
        hasher.update(std.mem.asBytes(&p.start));
        hasher.update(std.mem.sliceAsBytes(p.segments));
        return true;
    }
    const items: []const value.Value = if (val.isAssembly()) val.asAssembly().parts.items.items else if (val.isArray()) val.asArray().items.items else return true;
    if (depth >= model_mod.MAX_MODEL_NESTING) return false;
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
