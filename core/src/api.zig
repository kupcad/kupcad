const std = @import("std");
const VM = @import("vm/vm.zig").VM;
const chunk = @import("vm/chunk.zig");
const value = @import("core/value.zig");
const Compiler = @import("compiler/compiler.zig").Compiler;
const registry = @import("stdlib/registry.zig");
const kernel = @import("kernel/kernel.zig");
const extractor = @import("tools/doc/extractor.zig");

const Formatter = @import("tools/fmt/formatter.zig").Formatter;
const Linter = @import("tools/lint/linter.zig").Linter;

pub const ParamMetadata = extractor.ParamMetadata;
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

/// Scans a parsed document and extracts all parameter definitions and docstrings.
pub fn extractParameters(allocator: std.mem.Allocator, doc: *const Document) ![]ParamMetadata {
    return extractor.extractParameters(allocator, doc);
}

/// Compiles and evaluates a KupCAD script, returning a binary STL buffer.
/// The caller owns the returned slice and must free it.
pub fn buildStl(allocator: std.mem.Allocator, source: []const u8, cli_params: ?std.StringHashMap(f64)) ![]const u8 {
    var doc = try Document.parse(allocator, source);
    defer doc.deinit();

    var vm = try VM.init(allocator, undefined);
    defer vm.deinit();

    try registry.registerStandardLibrary(&vm);

    // Inject CLI Params into the Global Map
    if (cli_params) |cli_p| {
        // Retrieve the map we just allocated in registerStandardLibrary
        const p_val = vm.globals.get("params").?;
        const map_obj = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", p_val.asObj())));

        var it = cli_p.iterator();
        while (it.next()) |entry| {
            // KupCAD DSL uses Symbols for keys (e.g., params[:width])
            const sym_key = try vm.allocateSymbol(entry.key_ptr.*);

            // Protect the newly allocated symbol from GC during iteration
            vm.push(sym_key);
            defer _ = vm.pop();

            try map_obj.keys.append(vm.allocator, sym_key);
            try map_obj.values.append(vm.allocator, value.Value.initNumber(entry.value_ptr.*));
        }
    }

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(allocator);

    var comp = Compiler.init(allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    try comp.compile(doc.tree.root);

    const result = vm.interpret(&out_chunk);
    if (result != .ok) return error.RuntimeError;
    if (vm.stack_top == 0) return error.NoGeometry;

    const final_val = vm.stack[0];
    if (!final_val.isGeometry()) return error.NotGeometry;

    // Force Manifold to evaluate the CSG DAG into a concrete mesh
    const handle = try vm.ensureConcrete(final_val);
    const mesh = kernel.getMesh(allocator, handle) orelse return error.MeshExtractionFailed;
    defer allocator.free(mesh.vert_props);
    defer allocator.free(mesh.tri_verts);

    // Build the binary STL buffer directly using appendSlice
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // STL Header (80 bytes)
    try out.appendNTimes(allocator, 0, 80);

    // Triangle Count (4 bytes)
    const tri_count: u32 = @intCast(mesh.tri_verts.len / 3);
    try out.appendSlice(allocator, std.mem.asBytes(&tri_count));

    var i: usize = 0;
    while (i < mesh.tri_verts.len) : (i += 3) {
        // Dummy normal (3 floats)
        const zero: f32 = 0.0;
        try out.appendSlice(allocator, std.mem.asBytes(&zero));
        try out.appendSlice(allocator, std.mem.asBytes(&zero));
        try out.appendSlice(allocator, std.mem.asBytes(&zero));

        // 3 Vertices (x, y, z floats)
        for (0..3) |v| {
            const idx = mesh.tri_verts[i + v];
            const v_idx = idx * mesh.num_prop;
            try out.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v_idx]));
            try out.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v_idx + 1]));
            try out.appendSlice(allocator, std.mem.asBytes(&mesh.vert_props[v_idx + 2]));
        }

        // Attribute byte count (2 bytes)
        const attr_count: u16 = 0;
        try out.appendSlice(allocator, std.mem.asBytes(&attr_count));
    }

    return try out.toOwnedSlice(allocator);
}

/// Safely frees an array of LinterDiagnostics and their inner allocated strings.
pub fn freeDiagnostics(allocator: std.mem.Allocator, diags: []LinterDiagnostic) void {
    for (diags) |d| allocator.free(d.message);
    allocator.free(diags);
}
