const std = @import("std");
const api = @import("api.zig");

// --- Global Error State ---
var last_error_msg: [*]const u8 = "None\x00".ptr;

pub export fn get_last_error() [*]const u8 {
    return last_error_msg;
}

pub export fn wasm_alloc(len: usize) ?[*]u8 {
    const slice = std.heap.wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

pub export fn wasm_free(ptr: [*]u8, len: usize) void {
    std.heap.wasm_allocator.free(ptr[0..len]);
}

// --- Inner Zig Native Functions ---

fn inner_format(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    const formatted = try api.formatCode(allocator, source, .{});
    defer allocator.free(formatted);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, formatted);
    try out.append(allocator, 0);

    return try out.toOwnedSlice(allocator);
}

fn inner_check(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    // Note: checkCode safely returns syntax errors as part of the diagnostics array.
    // It only throws an error on catastrophic failures (e.g., OutOfMemory).
    const diags = try api.checkCode(allocator, source, .{});
    defer api.freeDiagnostics(allocator, diags);

    // Initialize the LineIndex
    var line_index = try api.LineIndex.init(allocator, source);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll("[");
    for (diags, 0..) |d, i| {
        if (i > 0) try out.writer.writeAll(",");
        const flat_diag = .{
            // Calculate dynamic line and column
            .line = line_index.getLine(d.loc.offset) + 1,
            .col = line_index.getUtf8Column(d.loc.offset) + 1,
            .offset = d.loc.offset,
            .length = d.loc.length,
            .severity = d.severity.toString(),
            .message = d.message,
        };
        try out.writer.print("{f}", .{std.json.fmt(flat_diag, .{})});
    }
    try out.writer.writeAll("]");
    try out.writer.writeAll("\x00");

    return out.written();
}

fn inner_extract_params(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var doc = try api.Document.parse(allocator, source);
    defer doc.deinit();

    // Use an Arena allocator here to cheaply manage the JSON nested tree
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const schema = try api.extractSchema(arena.allocator(), &doc, source);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    // std.json natively formats the `UiSchema` wrapper perfectly
    try out.writer.print("{f}", .{std.json.fmt(schema, .{})});
    try out.writer.writeByte(0); // Null-terminate for JS
    return try out.toOwnedSlice();
}

fn inner_build_stl(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    return try api.buildStl(allocator, undefined, source, null);
}

// --- WASM Export Boundaries ---

pub export fn format_code_wasm(source_ptr: [*]const u8, source_len: usize) ?[*]const u8 {
    // Never trust the JavaScript host to pass valid pointers
    std.debug.assert(@intFromPtr(source_ptr) != 0);

    const source = source_ptr[0..source_len];
    if (inner_format(std.heap.wasm_allocator, source)) |res| {
        return res.ptr;
    } else |err| {
        // Set the global error state and return 0 (null)
        if (err == error.SyntaxError) {
            last_error_msg = "Syntax Error\x00".ptr;
        } else {
            last_error_msg = "Internal Formatting Error\x00".ptr;
        }
        return null;
    }
}

pub export fn extract_params_wasm(source_ptr: [*]const u8, source_len: usize) ?[*]const u8 {
    const source = source_ptr[0..source_len];
    if (inner_extract_params(std.heap.wasm_allocator, source)) |res| {
        return res.ptr;
    } else |_| {
        last_error_msg = "Extraction Error\x00".ptr;
        return null;
    }
}

pub export fn check_code_wasm(source_ptr: [*]const u8, source_len: usize) ?[*]const u8 {
    const source = source_ptr[0..source_len];
    if (inner_check(std.heap.wasm_allocator, source)) |res| {
        return res.ptr;
    } else |_| {
        last_error_msg = "Internal Linter Error\x00".ptr;
        return null;
    }
}

/// Builds an STL from a KupCAD script.
/// Returns a pointer to the STL bytes, and populates `out_len`.
/// The caller MUST free the pointer using `wasm_free(ptr, out_len)`.
pub export fn build_stl_wasm(source_ptr: [*]const u8, source_len: usize, out_len: *usize) ?[*]const u8 {
    const source = source_ptr[0..source_len];
    if (inner_build_stl(std.heap.wasm_allocator, source)) |res| {
        out_len.* = res.len;
        return res.ptr;
    } else |err| {
        if (err == error.SyntaxError) {
            last_error_msg = "Syntax Error\x00".ptr;
        } else {
            last_error_msg = "Build Error\x00".ptr;
        }
        out_len.* = 0;
        return null;
    }
}
