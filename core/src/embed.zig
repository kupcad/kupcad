//! What a host that embeds the core calls, over `api.zig`: the WebAssembly module (wasm.zig)
//! and the C library (capi.zig), each a thin boundary over these. Source and JSON in; text,
//! JSON or model bytes out, owned by the allocator passed. The files a script imports come
//! packed (vfs/packed.zig) and are its call's alone: a file system in memory that no other
//! call sees, where the script's exports go nowhere.

const std = @import("std");
const api = @import("api.zig");
const lint_finding = @import("tools/lint/finding.zig");
const MemoryVfs = @import("vfs/memory.zig").MemoryVfs;
const packed_files = @import("vfs/packed.zig");
const frame = @import("preview/frame.zig");
const preview_build = @import("preview/build.zig");

/// Why a call failed, in words a script's author can act on: "2:5: ..." for a syntax error,
/// the error as the CLI prints it ("RuntimeError: ...") for a run that failed, or why the
/// host's arguments were refused ("parameters: ..."). Pass a fresh `.{}`; deinit it.
pub const Diagnostic = api.BuildDiagnostic;

/// `source` formatted, as `kupcad fmt` formats it. error.SyntaxError when it doesn't parse,
/// `diagnostic.message` its first syntax error.
pub fn format(allocator: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) ![]const u8 {
    var doc = try api.Document.parse(allocator, source);
    defer doc.deinit();
    if (doc.diagnostics.len > 0) {
        diagnostic.message = api.formatDiagnostic(allocator, &doc.line_index, doc.diagnostics[0]) catch null;
        return error.SyntaxError;
    }
    return api.formatDocument(allocator, &doc, .{});
}

/// The findings of `source` as a JSON array, each in the shape `check --format json` gives
/// it (tools/lint/finding.zig) without a path: syntax errors among them.
pub fn check(allocator: std.mem.Allocator, io: std.Io, source: []const u8) ![]const u8 {
    const diags = try api.checkCode(allocator, io, source, .{});
    defer api.freeDiagnostics(allocator, diags);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const line_index = try api.LineIndex.init(arena.allocator(), source);
    const findings = try arena.allocator().alloc(lint_finding.Finding, diags.len);
    for (diags, findings) |d, *f| f.* = try .place(arena.allocator(), &line_index, d);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(findings, .{}, &out.writer);
    return try out.toOwnedSlice();
}

/// The parameters `source` declares and its metadata, as JSON: the schema `kupcad doc` prints.
pub fn params(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var doc = try api.Document.parse(allocator, source);
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const schema = try api.extractSchema(arena.allocator(), &doc);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{f}", .{std.json.fmt(schema, .{})});
    return try out.toOwnedSlice();
}

/// How `build` builds: the format's name (`stl`, `3mf`, `glb`...), the parameter values as a
/// JSON object of names and values, as `kupcad build -P` reads them (empty for none), the
/// files the script imports, packed (empty for none), and api.BuildOptions' switches.
pub const Build = struct {
    format: []const u8,
    params: []const u8 = "",
    files: []const u8 = "",
    draco: bool = false,
    interactive: bool = false,
    memory_limit: ?usize = null,
    report: ?*api.RunReport = null,
};

/// `source` run and its model exported as `options.format`; the caller owns the bytes. A
/// format that isn't one is error.UnsupportedFormat, parameter values that aren't a JSON
/// object of names and values error.InvalidParams (with `diagnostic.message`), and files packed
/// wrong error.MalformedFiles; a script that fails is api.buildModel's error.
pub fn build(allocator: std.mem.Allocator, io: std.Io, source: []const u8, options: Build, diagnostic: *Diagnostic) ![]const u8 {
    const export_format = api.ExportFormat.parse(options.format) orelse return error.UnsupportedFormat;
    var values: api.ParamValues = .{};
    defer values.deinit(allocator);
    if (try putParams(allocator, &values, options.params)) |refusal| {
        diagnostic.message = refusal;
        return error.InvalidParams;
    }
    var vfs = try filesOf(allocator, options.files);
    defer vfs.deinit();
    return api.buildModel(allocator, io, source, .{
        .format = export_format,
        .draco = options.draco,
        .params = &values,
        .vfs = vfs.vfs(),
        .diagnostic = diagnostic,
        .interactive = options.interactive,
        .memory_limit = options.memory_limit,
        .report = options.report,
    });
}

/// The preview frame (preview/frame.zig) of `source` with the parameter values in
/// `params_json` and the files in `files`, as `build` takes them: its model as GLB or SVG,
/// with its parts, warnings, parameters and, when it failed, why. A script that doesn't run,
/// and values that aren't JSON, give a frame saying so; the caller owns it.
pub fn preview(allocator: std.mem.Allocator, io: std.Io, source: []const u8, params_json: []const u8, files: []const u8) ![]const u8 {
    var values: api.ParamValues = .{};
    defer values.deinit(allocator);
    if (try putParams(allocator, &values, params_json)) |refusal| {
        defer allocator.free(refusal);
        return api.previewFailure(allocator, source, refusal);
    }
    var vfs = try filesOf(allocator, files);
    defer vfs.deinit();
    return api.previewScript(allocator, io, source, .{ .params = &values, .vfs = vfs.vfs() });
}

/// A build's report as JSON, in the preview frame's words for the same things:
/// `{"output": "...", "outputCut": false, "warnings": [{"message", "line", "column", "file"}]}`,
/// what the script printed (up to MAX_OUTPUT_BYTES, `outputCut` past them) and what it warned
/// of. The caller owns it.
pub fn reportJson(allocator: std.mem.Allocator, report: *const api.RunReport) ![]u8 {
    const warnings = try allocator.alloc(frame.Warning, report.warnings.items.len);
    defer allocator.free(warnings);
    for (report.warnings.items, warnings) |w, *out| out.* = preview_build.warningOf(w.message, w.position, w.module);
    const Report = struct {
        output: []const u8,
        outputCut: bool,
        warnings: []const frame.Warning,
    };
    return std.json.Stringify.valueAlloc(allocator, Report{
        .output = report.output.items,
        .outputCut = report.output_cut,
        .warnings = warnings,
    }, .{});
}

/// The files a call was given (vfs/packed.zig's buffer; empty for none), as the file system
/// its script reads and writes: in memory, this call's alone. The caller deinits it.
fn filesOf(allocator: std.mem.Allocator, files: []const u8) !MemoryVfs {
    var vfs = MemoryVfs.init(allocator);
    errdefer vfs.deinit();
    try packed_files.unpack(vfs.vfs(), files);
    return vfs;
}

/// Sets `values` from `json`, a JSON object of names and values (empty for none). Null when
/// it took them; else why it refused them, owned, told apart from a script's own errors:
/// "parameters: line 1, column 3: invalid JSON".
fn putParams(allocator: std.mem.Allocator, values: *api.ParamValues, json: []const u8) !?[]u8 {
    if (json.len == 0) return null;
    var why: ?[]u8 = null;
    values.putJson(allocator, json, &why) catch |err| {
        defer if (why) |w| allocator.free(w);
        if (err != error.InvalidParams) return err;
        return try allocator.print("parameters: {s}", .{why orelse "they aren't one JSON object of names and values"});
    };
    return null;
}
