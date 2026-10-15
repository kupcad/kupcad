const std = @import("std");
const VM = @import("vm/vm.zig").VM;
const chunk = @import("vm/chunk.zig");
const value = @import("core/value.zig");
const Compiler = @import("compiler/compiler.zig").Compiler;
const registry = @import("stdlib/registry.zig");
const kernel = @import("kernel/kernel.zig");
const error_kind = @import("vm/error_kind.zig");
const extractor = @import("tools/doc/extractor.zig");
const profiler_mod = @import("vm/profiler.zig");
const geom = @import("kernel/geometry_handle.zig");
const Vfs = @import("vfs/vfs.zig").Vfs;
const Formatter = @import("tools/fmt/formatter.zig").Formatter;
const equivalence = @import("tools/fmt/equivalence.zig");
const Linter = @import("tools/lint/linter.zig").Linter;
const stl_exporter = @import("exporters/3d/stl.zig");
const gltf_exporter = @import("exporters/3d/gltf.zig");
const step_exporter = @import("exporters/3d/step.zig");

pub const UiSchema = extractor.UiSchema;
pub const FormatterConfig = @import("tools/fmt/config.zig").Config;
pub const Document = @import("core/document.zig").Document;
pub const LineIndex = @import("core/line_index.zig").LineIndex;
pub const LinterConfig = @import("tools/lint/config.zig").Config;
const suppressions = @import("tools/lint/suppressions.zig");
pub const LinterDiagnostic = @import("tools/lint/linter.zig").LinterDiagnostic;
pub const Diagnostic = @import("core/errors.zig").Diagnostic;

/// Formats an already parsed Document. Caller owns the returned slice.
/// Formats a parsed Document. The result is checked before it is returned: it must parse,
/// mean the same program (tools/fmt/equivalence.zig) and keep every comment in order.
/// Otherwise the formatter has a bug, reported as error.FormatChangedProgram, and the
/// caller keeps the source as it was rather than overwrite it.
pub fn formatDocument(allocator: std.mem.Allocator, doc: *const Document, config: FormatterConfig) ![]const u8 {
    if (doc.diagnostics.len > 0) return error.SyntaxError;
    if (doc.tree.root == .none) return error.SyntaxError;
    var formatter = Formatter.init(allocator, doc.tokens.starts, &doc.line_index, doc.comments, config);
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
    try linter.check(&doc.tree, doc.tokens.starts, doc.tokens.lengths, doc.tree.root, doc.diagnostics);
    try suppressions.apply(allocator, &linter.diagnostics, doc.comments, &doc.line_index, config);
    if (doc.diagnostics.len == 0) {
        if (try compileError(allocator, io, doc)) |compile_error| {
            errdefer allocator.free(compile_error.message);
            try linter.diagnostics.append(allocator, .{ .loc = compile_error.loc, .severity = .@"error", .message = compile_error.message });
        }
    }
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
    var comp = Compiler.init(allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    comp.compile(doc.tree.root) catch |err| {
        if (err == error.OutOfMemory) return err;
        const found = comp.errorDiagnostic() orelse return null;
        return .{ .loc = found.loc, .message = try allocator.dupe(u8, found.message) };
    };
    return null;
}

/// Lints raw KupCAD source code (Convenience wrapper).
pub fn checkCode(allocator: std.mem.Allocator, io: std.Io, source: []const u8, config: LinterConfig) ![]LinterDiagnostic {
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();
    return checkDocument(allocator, io, &doc, config);
}

pub fn benchmarkScript(allocator: std.mem.Allocator, source: []const u8, io: std.Io, writer: anytype) !void {
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();
    if (doc.diagnostics.len > 0) return error.ParseError;

    var vm = try VM.init(allocator, io);
    defer vm.deinit();

    vm.line_index = &doc.line_index;
    vm.mute_errors = true; // Mute VM stderr output during benchmarks and tests
    try registry.registerStandardLibrary(&vm);

    var p = profiler_mod.Profiler.init(allocator, io);
    defer p.deinit();
    vm.profiler = &p;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(allocator);

    var comp = Compiler.init(allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    if (result != .ok) {
        return error.RuntimeError;
    }
    try p.dumpProfile(writer);
}

/// Scans a parsed document and extracts all parameter definitions and docstrings.
pub fn extractSchema(allocator: std.mem.Allocator, doc: *const Document, source: []const u8) !UiSchema {
    return extractor.extractSchema(allocator, doc, source);
}

/// Safely injects a map of f64 CLI parameters into the active VM's global `params` map.
pub fn injectParamsIntoVm(vm: *VM, cli_params: std.StringHashMapUnmanaged(f64)) !void {
    if (cli_params.count() == 0) return;

    // Retrieve the global `params` map initialized by the standard library
    const p_val = vm.globals.get("params") orelse return;
    const map_obj: *value.ObjMap = @alignCast(@fieldParentPtr("obj", p_val.asObj()));

    var it = cli_params.iterator();
    while (it.next()) |entry| {
        // Allocate the dictionary key as an interned symbol
        const sym_key = try vm.allocateSymbol(entry.key_ptr.*);

        // Push to the VM stack temporarily to protect it from the Garbage Collector
        // in case the map.put operation triggers an allocation that causes a GC sweep
        vm.push(sym_key);
        defer _ = vm.pop();

        // Insert the key and the numeric value into the VM's map
        try map_obj.map.put(vm.gc.trackingAllocator(), sym_key, value.Value.initNumber(entry.value_ptr.*));
    }
}

/// Extracts evaluated Geometry from the VM stack/display list and routes it to the requested 3D exporter.
/// A failure the script can read about (an engine that can't mesh, a failed union) is
/// raised in the VM first, so `vm.last_error` says what went wrong.
pub fn exportModelFromVm(
    allocator: std.mem.Allocator,
    vm: *VM,
    format: []const u8,
    use_draco: bool,
) ![]const u8 {
    const is_stl = std.mem.eql(u8, format, "stl");
    const is_gltf = std.mem.eql(u8, format, "glb") or std.mem.eql(u8, format, "gltf");
    const is_step = std.mem.eql(u8, format, "step");
    if (!is_stl and !is_gltf and !is_step) return error.UnsupportedFormat;

    // The model: the value the script left on the stack, a solid or an assembly's or an
    // array's parts.
    var parts: std.ArrayListUnmanaged(geom.GeometryHandle) = .empty;
    defer parts.deinit(allocator);
    if (vm.stack_top > 0) {
        const final_val = vm.stack[0];
        if (final_val.isGeometry()) {
            try parts.append(allocator, try vm.ensureConcrete(final_val));
        } else {
            const items: []const value.Value = if (final_val.isAssembly())
                final_val.asAssembly().parts.items.items
            else if (final_val.isArray())
                final_val.asArray().items.items
            else
                &.{};
            for (items) |part| {
                if (part.isGeometry()) try parts.append(allocator, try vm.ensureConcrete(part));
            }
        }
    }

    // Ghosted items (the display list) are exported beside the model.
    var export_handles: std.ArrayListUnmanaged(geom.GeometryHandle) = .empty;
    defer export_handles.deinit(allocator);
    try export_handles.appendSlice(allocator, vm.display_list.items);
    try export_handles.appendSlice(allocator, parts.items);
    if (export_handles.items.len == 0) return error.NoGeometry;

    if (is_step) return step_exporter.buildStepBuffer(allocator, export_handles.items);

    // Mesh formats: refuse parts the engine can't tessellate before any work on them.
    for (export_handles.items) |h| try vm.requireFeature(h.engine, .mesh);
    if (is_gltf) {
        // GLTF handles multiple distinct meshes naturally
        const container: gltf_exporter.Container = if (std.mem.eql(u8, format, "gltf")) .gltf else .glb;
        return gltf_exporter.buildGltfBuffer(allocator, vm, export_handles.items, use_draco, container);
    }

    // STL holds one mesh: the model's parts are united, the ghosts left out.
    switch (parts.items.len) {
        0 => return error.NoGeometry,
        1 => return stl_exporter.buildStlBuffer(allocator, parts.items[0]),
        else => {
            try vm.requireFeature(parts.items[0].engine, .boolean);
            const united = kernel.batchBoolean(allocator, parts.items, .union_op) orelse {
                _ = vm.raiseError(.GeometryError, error_kind.KERNEL_FAILED_FMT, .{"union"});
                return error.RuntimeError;
            };
            defer kernel.destruct(united);
            return stl_exporter.buildStlBuffer(allocator, united);
        },
    }
}

/// Why a build failed, in words a script author can act on. Filled by
/// `buildModelWithDiagnostic`; `message` is owned by the allocator passed to it.
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

/// Runs `source` and exports the resulting geometry as `format`. Caller owns the bytes.
/// Fails with error.SyntaxError if the script does not parse cleanly.
pub fn buildModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    format: []const u8,
    use_draco: bool,
    cli_params: ?std.StringHashMap(f64),
    vfs_override: ?Vfs,
) ![]const u8 {
    return buildModelWithDiagnostic(allocator, io, source, format, use_draco, cli_params, vfs_override, null);
}

/// `buildModel` that also explains a failure: when the build fails with a message and
/// `diagnostic` is given, `diagnostic.message` is set to it. Pass a fresh `.{}`.
pub fn buildModelWithDiagnostic(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    format: []const u8,
    use_draco: bool,
    cli_params: ?std.StringHashMap(f64),
    vfs_override: ?Vfs,
    diagnostic: ?*BuildDiagnostic,
) ![]const u8 {
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

    if (vfs_override) |vfs| vm.vfs = vfs;
    vm.line_index = &doc.line_index;
    try registry.registerStandardLibrary(&vm);

    // STEP requires exact B-Rep geometry, not polygonal Manifold meshes
    if (std.mem.eql(u8, format, "step")) {
        var settings = vm.config();
        settings.engine = .brep_native;
        try vm.setConfig(settings);
    }

    // Inject parameters securely
    if (cli_params) |cli_p| {
        try injectParamsIntoVm(&vm, cli_p.unmanaged);
    }

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(allocator);

    var comp = Compiler.init(allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
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
    return exportModelFromVm(allocator, &vm, format, use_draco) catch |err| {
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
    for (diags) |d| allocator.free(d.message);
    allocator.free(diags);
}
