//! The exports of the WebAssembly build, over `api.zig`: `format_code_wasm`, `check_code_wasm`,
//! `extract_params_wasm`, `build_model_wasm` and `preview_wasm` (a build and a preview read
//! the files given with the call, packed as vfs/packed.zig has them, from an in-memory VFS of
//! that call alone), plus `version_wasm`, `wasm_alloc`/`wasm_free` and `get_last_error`.

const std = @import("std");
const api = @import("api.zig");
const version = @import("version.zig");
const lint_finding = @import("tools/lint/finding.zig");
const MemoryVfs = @import("vfs/memory.zig").MemoryVfs;
const packed_files = @import("vfs/packed.zig");

// Use the thread-safe C allocator provided by wasi-libc
// This prevents spinlock deadlocks in multi-threaded wasm and gracefully
// falls back to standard malloc in single-threaded builds.
const allocator = std.heap.c_allocator;

// --- Global Error State ---
/// Longest message `get_last_error` returns; longer ones are cut at a UTF-8 boundary.
pub const MAX_ERROR_MSG_LEN = 1024;

/// A real Io for the VM. Script features such as `benchmark { }` (Clock.now) and `debugger`
/// (stdin/stdout) dereference `vm.io`; passing `undefined` trapped the wasm instance.
/// The single-threaded Threaded backend maps onto WASI clocks/fds and needs no setup.
fn wasmIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

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

pub export fn get_last_error() [*:0]const u8 {
    return &last_error_buf;
}

pub export fn wasm_alloc(len: usize) ?[*]u8 {
    // A block near the whole 32-bit address space never fits, and wasi-libc's malloc (Zig's
    // own) adds its header to `len` unchecked: the overflow panicked, killing the instance.
    if (len > std.math.maxInt(usize) - std.wasm.page_size) return null;
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

pub export fn wasm_free(ptr: [*]u8, len: usize) void {
    allocator.free(ptr[0..len]);
}

/// The files a call was given (vfs/packed.zig's buffer; empty for none), as the file system
/// its script reads and writes: in memory, this call's alone, so no script sees another's
/// files, and a script's exports go nowhere. The caller deinits it.
fn filesOf(files: []const u8) !MemoryVfs {
    var vfs = MemoryVfs.init(allocator);
    errdefer vfs.deinit();
    try packed_files.unpack(vfs.vfs(), files);
    return vfs;
}

// --- Inner Zig Native Functions ---

fn inner_format(source: []const u8) ![]const u8 {
    // Return the raw slice directly. No null-termination needed
    // because we pass the explicit length back to JavaScript.
    return try api.formatCode(allocator, source, .{});
}

/// The findings of `source` as a JSON array, each in the shape `check --format json` gives
/// it (tools/lint/finding.zig) without a path: syntax errors among them.
fn inner_check(source: []const u8) ![]const u8 {
    const diags = try api.checkCode(allocator, wasmIo(), source, .{});
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

fn inner_extract_params(source: []const u8) ![]const u8 {
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

fn inner_build_model(source: []const u8, params_json: []const u8, files: []const u8, format: []const u8, use_draco: bool, diagnostic: *api.BuildDiagnostic) ![]const u8 {
    // The Io is only used for clocks/stdio by stdlib diagnostics and the debugger: the files
    // are the call's own.
    const export_format = api.ExportFormat.parse(format) orelse return error.UnsupportedFormat;
    var params: api.ParamValues = .{};
    defer params.deinit(allocator);
    if (try putParams(&params, params_json)) |refusal| {
        diagnostic.message = refusal;
        return error.InvalidParams;
    }
    var vfs = try filesOf(files);
    defer vfs.deinit();
    return try api.buildModel(allocator, wasmIo(), source, .{ .format = export_format, .draco = use_draco, .params = &params, .vfs = vfs.vfs(), .diagnostic = diagnostic, .interactive = true });
}

fn inner_preview(source: []const u8, params_json: []const u8, files: []const u8) ![]const u8 {
    var params: api.ParamValues = .{};
    defer params.deinit(allocator);
    if (try putParams(&params, params_json)) |refusal| {
        defer allocator.free(refusal);
        return api.previewFailure(allocator, source, refusal);
    }
    var vfs = try filesOf(files);
    defer vfs.deinit();
    return api.previewScript(allocator, wasmIo(), source, .{ .params = &params, .vfs = vfs.vfs() });
}

/// Sets `params` from `json`, a JSON object of names and values (empty for none). Null when
/// it took them; else why it refused them, owned, told apart from a script's own errors:
/// "parameters: line 1, column 3: invalid JSON".
fn putParams(params: *api.ParamValues, json: []const u8) !?[]u8 {
    if (json.len == 0) return null;
    var why: ?[]u8 = null;
    params.putJson(allocator, json, &why) catch |err| {
        defer if (why) |w| allocator.free(w);
        if (err != error.InvalidParams) return err;
        return try allocator.print("parameters: {s}", .{why orelse "they aren't one JSON object of names and values"});
    };
    return null;
}

// --- WASM Export Boundaries ---

/// What the module says of itself (version.zig), as `kupcad version --json` prints it:
/// `{"version": "0.1.0", "protocolVersion": 1, "os": "wasi", "arch": "wasm32"}`, for a page
/// that loads the module from a URL to show, and to check the protocol version of. Freed with
/// wasm_free, as every result is.
pub export fn version_wasm(out_len: *usize) ?[*]const u8 {
    const json = std.json.Stringify.valueAlloc(allocator, version.Info{}, .{}) catch {
        setLastError("Out of memory");
        out_len.* = 0;
        return null;
    };
    out_len.* = json.len;
    return json.ptr;
}

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

/// The preview frame (preview/frame.zig) of `source` with the parameter values in `params`
/// (a JSON object, as build_model_wasm takes; empty for none) and the files it imports in
/// `files` (packed as vfs/packed.zig has them; empty for none): its model as GLB or SVG, with
/// its parts, warnings, parameters and, when it failed, why. A script that doesn't run, and
/// values that aren't JSON, give a frame saying so; null (and get_last_error) only when the
/// module itself fails, or the files aren't packed right.
pub export fn preview_wasm(
    source_ptr: [*]const u8,
    source_len: usize,
    params_ptr: [*]const u8,
    params_len: usize,
    files_ptr: [*]const u8,
    files_len: usize,
    out_len: *usize,
) ?[*]const u8 {
    if (inner_preview(source_ptr[0..source_len], params_ptr[0..params_len], files_ptr[0..files_len])) |res| {
        out_len.* = res.len;
        return res.ptr;
    } else |err| {
        var buf: [MAX_ERROR_MSG_LEN]u8 = undefined;
        setLastError(std.mem.print(&buf, "Preview Error: {s}", .{@errorName(err)}) catch "Preview Error");
        out_len.* = 0;
        return null;
    }
}

/// Builds `source` with the parameter values in `params` (a JSON object of names and
/// numbers, strings, booleans or arrays of them, as `kupcad build -P` reads; empty for none) and the files it
/// imports in `files` (packed as vfs/packed.zig has them; empty for none), and exports it as
/// `format`.
pub export fn build_model_wasm(
    source_ptr: [*]const u8,
    source_len: usize,
    params_ptr: [*]const u8,
    params_len: usize,
    files_ptr: [*]const u8,
    files_len: usize,
    format_ptr: [*]const u8,
    format_len: usize,
    use_draco: bool,
    out_len: *usize,
) ?[*]const u8 {
    const source = source_ptr[0..source_len];
    const params = params_ptr[0..params_len];
    const files = files_ptr[0..files_len];
    const format = format_ptr[0..format_len];

    var diagnostic: api.BuildDiagnostic = .{};
    defer diagnostic.deinit(allocator);

    if (inner_build_model(source, params, files, format, use_draco, &diagnostic)) |res| {
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
            setLastError(std.mem.print(&buf, "Build Error: {s}", .{@errorName(err)}) catch "Build Error");
        }
        out_len.* = 0;
        return null;
    }
}
