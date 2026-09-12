const std = @import("std");
const api = @import("api.zig");
const Vfs = @import("vfs/vfs.zig").Vfs;
const MemoryVfs = @import("vfs/memory.zig").MemoryVfs;

// Use the thread-safe C allocator provided by wasi-libc
// This prevents spinlock deadlocks in multi-threaded wasm and gracefully
// falls back to standard malloc in single-threaded builds.
const allocator = std.heap.c_allocator;

// --- Global Error State ---
var last_error_msg: [*]const u8 = "None".ptr;

// --- Global VFS State ---
var global_mem_vfs: MemoryVfs = undefined;
var vfs_initialized: bool = false;

fn getMemVfs() *MemoryVfs {
    if (!vfs_initialized) {
        global_mem_vfs = MemoryVfs.init(allocator);
        vfs_initialized = true;
    }
    return &global_mem_vfs;
}

pub export fn get_last_error() [*]const u8 {
    return last_error_msg;
}

pub export fn wasm_alloc(len: usize) ?[*]u8 {
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

pub export fn wasm_free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

pub export fn clear_vfs_wasm() void {
    if (vfs_initialized) {
        global_mem_vfs.deinit();
    }
    global_mem_vfs = MemoryVfs.init(allocator);
    vfs_initialized = true;
}

pub export fn put_file_wasm(
    path_ptr: [*]const u8,
    path_len: usize,
    content_ptr: [*]const u8,
    content_len: usize,
) bool {
    const path = path_ptr[0..path_len];
    const content = content_ptr[0..content_len];

    // MemoryVfs internally dupes the memory, making it safe from JS GC sweeps
    getMemVfs().vfs().writeFile(path, content) catch return false;
    return true;
}

// --- Inner Zig Native Functions ---

fn inner_format(source: []const u8) ![]const u8 {
    // Return the raw slice directly. No null-termination needed
    // because we pass the explicit length back to JavaScript.
    return try api.formatCode(allocator, source, .{});
}

fn inner_check(source: []const u8) ![]const u8 {
    // Note: checkCode safely returns syntax errors as part of the diagnostics array.
    const diags = try api.checkCode(allocator, source, .{});
    defer api.freeDiagnostics(allocator, diags);

    var line_index = try api.LineIndex.init(allocator, source);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll("[");
    for (diags, 0..) |d, i| {
        if (i > 0) try out.writer.writeAll(",");
        const flat_diag = .{
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

    return try out.toOwnedSlice();
}

fn inner_extract_params(source: []const u8) ![]const u8 {
    var doc = try api.Document.parse(allocator, source);
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const schema = try api.extractSchema(arena.allocator(), &doc, source);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.print("{f}", .{std.json.fmt(schema, .{})});
    return try out.toOwnedSlice();
}

fn inner_build_model(source: []const u8, format: []const u8, use_draco: bool) ![]const u8 {
    return try api.buildModel(allocator, undefined, source, format, use_draco, null, getMemVfs().vfs());
}

// --- WASM Export Boundaries ---

pub export fn format_code_wasm(source_ptr: [*]const u8, source_len: usize, out_len: *usize) ?[*]const u8 {
    std.debug.assert(@intFromPtr(source_ptr) != 0);

    const source = source_ptr[0..source_len];
    if (inner_format(source)) |res| {
        out_len.* = res.len;
        return res.ptr;
    } else |err| {
        last_error_msg = if (err == error.SyntaxError) "Syntax Error".ptr else "Internal Formatting Error".ptr;
        out_len.* = 0;
        return null;
    }
}

pub export fn extract_params_wasm(source_ptr: [*]const u8, source_len: usize, out_len: *usize) ?[*]const u8 {
    const source = source_ptr[0..source_len];
    if (inner_extract_params(source)) |res| {
        out_len.* = res.len;
        return res.ptr;
    } else |_| {
        last_error_msg = "Extraction Error".ptr;
        out_len.* = 0;
        return null;
    }
}

pub export fn check_code_wasm(source_ptr: [*]const u8, source_len: usize, out_len: *usize) ?[*]const u8 {
    const source = source_ptr[0..source_len];
    if (inner_check(source)) |res| {
        out_len.* = res.len;
        return res.ptr;
    } else |_| {
        last_error_msg = "Internal Linter Error".ptr;
        out_len.* = 0;
        return null;
    }
}

pub export fn build_model_wasm(
    source_ptr: [*]const u8,
    source_len: usize,
    format_ptr: [*]const u8,
    format_len: usize,
    use_draco: bool,
    out_len: *usize,
) ?[*]const u8 {
    const source = source_ptr[0..source_len];
    const format = format_ptr[0..format_len];

    if (inner_build_model(source, format, use_draco)) |res| {
        out_len.* = res.len;
        return res.ptr;
    } else |err| {
        if (err == error.SyntaxError) {
            last_error_msg = "Syntax Error".ptr;
        } else if (err == error.UnsupportedFormat) {
            last_error_msg = "Unsupported Format".ptr;
        } else {
            last_error_msg = "Build Error".ptr;
        }
        out_len.* = 0;
        return null;
    }
}
