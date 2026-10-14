const std = @import("std");
const api = @import("api.zig");
const MemoryVfs = @import("vfs/memory.zig").MemoryVfs;

// Use the thread-safe C allocator provided by wasi-libc
// This prevents spinlock deadlocks in multi-threaded wasm and gracefully
// falls back to standard malloc in single-threaded builds.
const allocator = std.heap.c_allocator;

/// A real Io for the VM. Script features such as `benchmark { }` (Clock.now) and `debugger`
/// (stdin/stdout) dereference `vm.io`; passing `undefined` trapped the wasm instance.
/// The single-threaded Threaded backend maps onto WASI clocks/fds and needs no setup.
fn wasmIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

// --- Global Error State ---
/// Longest message `get_last_error` returns; longer ones are cut at a UTF-8 boundary.
pub const MAX_ERROR_MSG_LEN = 1024;

// Messages are copied in, so they may come from memory freed right after (e.g. the VM's).
// The array's sentinel keeps even a full-length message NUL-terminated for JS.
var last_error_buf: [MAX_ERROR_MSG_LEN:0]u8 = blk: {
    var buf: [MAX_ERROR_MSG_LEN:0]u8 = @splat(0);
    const initial = "None";
    @memcpy(buf[0..initial.len], initial);
    break :blk buf;
};

fn setLastError(msg: []const u8) void {
    var len = @min(msg.len, MAX_ERROR_MSG_LEN);
    // JS decodes the bytes as UTF-8: a continuation byte (0b10xxxxxx) at the cut means the
    // sequence it belongs to started earlier, so cut before that sequence instead.
    if (len < msg.len) {
        while (len > 0 and msg[len] & 0b1100_0000 == 0b1000_0000) len -= 1;
    }
    @memcpy(last_error_buf[0..len], msg[0..len]);
    if (len < MAX_ERROR_MSG_LEN) last_error_buf[len] = 0;
}

// --- Global VFS State ---
// SAFETY: Initialized securely in getMemVfs() before any external access.
var global_mem_vfs: MemoryVfs = undefined;
var vfs_initialized: bool = false;

fn getMemVfs() *MemoryVfs {
    if (!vfs_initialized) {
        global_mem_vfs = MemoryVfs.init(allocator);
        vfs_initialized = true;
    }
    return &global_mem_vfs;
}

pub export fn get_last_error() [*:0]const u8 {
    return &last_error_buf;
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
    defer line_index.deinit(allocator);
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

fn inner_build_model(source: []const u8, format: []const u8, use_draco: bool, diagnostic: *api.BuildDiagnostic) ![]const u8 {
    // File access still goes through the in-memory VFS override; the Io is only used for
    // clocks/stdio by stdlib diagnostics and the debugger.
    return try api.buildModelWithDiagnostic(allocator, wasmIo(), source, format, use_draco, null, getMemVfs().vfs(), diagnostic);
}

// --- WASM Export Boundaries ---

pub export fn format_code_wasm(source_ptr: [*]const u8, source_len: usize, out_len: *usize) ?[*]const u8 {
    std.debug.assert(@intFromPtr(source_ptr) != 0);

    const source = source_ptr[0..source_len];
    if (inner_format(source)) |res| {
        out_len.* = res.len;
        return res.ptr;
    } else |err| {
        setLastError(if (err == error.SyntaxError) "Syntax Error" else "Internal Formatting Error");
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
        setLastError("Extraction Error");
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
        setLastError("Internal Linter Error");
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

    var diagnostic: api.BuildDiagnostic = .{};
    defer diagnostic.deinit(allocator);

    if (inner_build_model(source, format, use_draco, &diagnostic)) |res| {
        out_len.* = res.len;
        return res.ptr;
    } else |err| {
        if (diagnostic.message) |msg| {
            // "line:col: message" for syntax errors, the uncaught error for runtime ones
            setLastError(msg);
        } else if (err == error.SyntaxError) {
            setLastError("Syntax Error");
        } else if (err == error.UnsupportedFormat) {
            setLastError("Unsupported Format");
        } else {
            // e.g. NoGeometry or a compile error: the name still says more than nothing
            var buf: [MAX_ERROR_MSG_LEN]u8 = undefined;
            setLastError(std.fmt.bufPrint(&buf, "Build Error: {s}", .{@errorName(err)}) catch "Build Error");
        }
        out_len.* = 0;
        return null;
    }
}
