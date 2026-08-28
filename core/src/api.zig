const std = @import("std");
const VM = @import("vm/vm.zig").VM;
const chunk = @import("vm/chunk.zig");
const value = @import("core/value.zig");
const Compiler = @import("compiler/compiler.zig").Compiler;
const registry = @import("stdlib/registry.zig");
const kernel = @import("kernel/kernel.zig");
const extractor = @import("tools/doc/extractor.zig");
const profiler_mod = @import("vm/profiler.zig");
const geom = @import("kernel/geometry_handle.zig");
const Formatter = @import("tools/fmt/formatter.zig").Formatter;
const Linter = @import("tools/lint/linter.zig").Linter;
const stl_exporter = @import("exporters/3d/stl.zig");
const gltf_exporter = @import("exporters/3d/gltf.zig");
const step_exporter = @import("exporters/3d/step.zig");

pub const UiSchema = extractor.UiSchema;
pub const FormatterConfig = @import("tools/fmt/config.zig").Config;
pub const Document = @import("core/document.zig").Document;
pub const LineIndex = @import("core/line_index.zig").LineIndex;
pub const LinterConfig = @import("tools/lint/config.zig").Config;
pub const LinterDiagnostic = @import("tools/lint/linter.zig").LinterDiagnostic;

/// Formats an already parsed Document. Caller owns the returned slice.
pub fn formatDocument(allocator: std.mem.Allocator, doc: *const Document, config: FormatterConfig) ![]const u8 {
    if (doc.diagnostics.len > 0) return error.SyntaxError;
    if (doc.tree.root == .none) return error.SyntaxError;
    var formatter = Formatter.init(allocator, doc.tokens.starts, &doc.line_index, doc.comments, config);
    defer formatter.deinit();
    try formatter.registerDefaultRules();
    return formatter.format(&doc.tree, doc.tree.root);
}

/// Formats raw KupCAD source code (Convenience wrapper).
pub fn formatCode(allocator: std.mem.Allocator, source: []const u8, config: FormatterConfig) ![]const u8 {
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();
    return formatDocument(allocator, &doc, config);
}

/// Lints an already parsed Document. Caller owns the returned array of diagnostics.
pub fn checkDocument(allocator: std.mem.Allocator, doc: *const Document, config: LinterConfig) ![]LinterDiagnostic {
    var linter = Linter.init(allocator, config);
    defer linter.deinit();
    try linter.registerDefaultRules();
    try linter.check(&doc.tree, doc.tokens.starts, doc.tokens.lengths, doc.tree.root, doc.diagnostics);
    return linter.diagnostics.toOwnedSlice(allocator);
}

/// Lints raw KupCAD source code (Convenience wrapper).
pub fn checkCode(allocator: std.mem.Allocator, source: []const u8, config: LinterConfig) ![]LinterDiagnostic {
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();
    return checkDocument(allocator, &doc, config);
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

/// Compiles and evaluates a KupCAD script, returning the binary buffer for the requested format.
/// Supports formats: "stl", "glb", "gltf", "step".
/// The caller owns the returned slice and must free it.
pub fn buildModel(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    format: []const u8,
    cli_params: ?std.StringHashMap(f64),
) ![]const u8 {
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();

    var vm = try VM.init(allocator, io);
    defer vm.deinit();

    vm.line_index = &doc.line_index;
    try registry.registerStandardLibrary(&vm);

    // Force the native B-Rep engine for STEP exports to ensure exact analytical geometry
    if (std.mem.eql(u8, format, "step")) {
        vm.config_stack.items[0].engine = .brep_native;
    }

    // Inject CLI Params into the Global Map
    if (cli_params) |cli_p| {
        const p_val = vm.globals.get("params").?;
        const map_obj = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", p_val.asObj())));
        var it = cli_p.iterator();
        while (it.next()) |entry| {
            const sym_key = try vm.allocateSymbol(entry.key_ptr.*);
            vm.push(sym_key);
            defer _ = vm.pop();
            try map_obj.map.put(vm.allocator, sym_key, value.Value.initNumber(entry.value_ptr.*));
        }
    }

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(allocator);

    var comp = Compiler.init(allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    if (result != .ok) return error.RuntimeError;

    var export_handles: std.ArrayListUnmanaged(geom.GeometryHandle) = .empty;
    defer export_handles.deinit(allocator);

    for (vm.display_list.items) |ghost_handle| {
        try export_handles.append(allocator, ghost_handle);
    }

    var main_handle_opt: ?geom.GeometryHandle = null;
    var batch_created_handle: ?geom.GeometryHandle = null;
    defer if (batch_created_handle) |h| kernel.destruct(h);

    if (vm.stack_top > 0) {
        const final_val = vm.stack[0];

        if (final_val.isGeometry()) {
            // 1. Direct Geometry Object
            const main_handle = try vm.ensureConcrete(final_val);
            try export_handles.append(allocator, main_handle);
            main_handle_opt = main_handle;
        } else if (final_val.isAssembly()) {
            // 2. Assembly Object (Extract all member parts)
            var asm_handles: std.ArrayListUnmanaged(geom.GeometryHandle) = .empty;
            defer asm_handles.deinit(allocator);

            for (final_val.asAssembly().parts.items.items) |part_val| {
                if (part_val.isGeometry()) {
                    const h = try vm.ensureConcrete(part_val);
                    try export_handles.append(allocator, h);
                    try asm_handles.append(allocator, h);
                }
            }

            if (asm_handles.items.len == 1) {
                main_handle_opt = asm_handles.items[0];
            } else if (asm_handles.items.len > 1) {
                // Combine multi-part assemblies into a single CSG mesh ONLY for STL!
                if (std.mem.eql(u8, format, "stl")) {
                    main_handle_opt = kernel.batchBoolean(allocator, asm_handles.items, .union_op);
                    batch_created_handle = main_handle_opt;
                }
            }
        } else if (final_val.isArray()) {
            // 3. Array of Geometries
            var arr_handles: std.ArrayListUnmanaged(geom.GeometryHandle) = .empty;
            defer arr_handles.deinit(allocator);

            for (final_val.asArray().items.items) |part_val| {
                if (part_val.isGeometry()) {
                    const h = try vm.ensureConcrete(part_val);
                    try export_handles.append(allocator, h);
                    try arr_handles.append(allocator, h);
                }
            }

            if (arr_handles.items.len == 1) {
                main_handle_opt = arr_handles.items[0];
            } else if (arr_handles.items.len > 1) {
                if (std.mem.eql(u8, format, "stl")) {
                    main_handle_opt = kernel.batchBoolean(allocator, arr_handles.items, .union_op);
                    batch_created_handle = main_handle_opt;
                }
            }
        }
    }

    if (export_handles.items.len == 0) return error.NoGeometry;

    // --- Route to appropriate exporter ---
    if (std.mem.eql(u8, format, "stl")) {
        if (main_handle_opt) |h| {
            return stl_exporter.buildStlBuffer(allocator, h);
        } else {
            return error.NoGeometry;
        }
    } else if (std.mem.eql(u8, format, "glb") or std.mem.eql(u8, format, "gltf")) {
        return gltf_exporter.buildGltfBuffer(allocator, &vm, export_handles.items);
    } else if (std.mem.eql(u8, format, "step")) {
        // Pass the entire slice of separate bodies natively
        return step_exporter.buildStepBuffer(allocator, export_handles.items);
    } else {
        return error.UnsupportedFormat;
    }
}

/// Safely frees an array of LinterDiagnostics and their inner allocated strings.
pub fn freeDiagnostics(allocator: std.mem.Allocator, diags: []LinterDiagnostic) void {
    for (diags) |d| allocator.free(d.message);
    allocator.free(diags);
}
