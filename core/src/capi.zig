//! libkupcad's exports, declared for C in include/kupcad.h, over `embed.zig` (which the
//! WebAssembly module, wasm.zig, shares): `kupcad_version`, `kupcad_format`, `kupcad_check`,
//! `kupcad_params` and `kupcad_build`, each returning a result the caller reads with
//! `kupcad_result_*` and frees with `kupcad_result_free`. The library is a host's in-process
//! guest, so it never writes to the host's stdout or stderr, and logs nothing (`std_options`):
//! a result says all there is. Calls share no state, so threads may make them at once.

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");
const embed = @import("embed.zig");
const version = @import("version.zig");
const manifold = @import("bindings/manifold.zig");
const json_text = @import("core/json_text.zig");

/// The ABI include/kupcad.h declares (KUPCAD_ABI_VERSION): a change to a declared function
/// raises it, and a binding refuses a library that says another.
pub const ABI_VERSION: u32 = 1;

/// malloc's: thread-safe, and the host's own. The tests' allocator under test, so they find what
/// a call leaks.
const allocator = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

pub const std_options: std.Options = .{ .logFn = logNothing };

/// What a call returns when even its result can't be allocated: static, so a call never
/// returns NULL, and never freed.
const out_of_memory: Result = .{ .status = .out_of_memory, .message = "out of memory" };

/// kupcad_status, as the header numbers it.
pub const Status = enum(c_int) {
    ok = 0,
    script_error = 1,
    invalid_argument = 2,
    out_of_memory = 3,
    internal_error = 4,
};

/// The header's kupcad_result: a host holds only pointers to it.
pub const kupcad_result = opaque {};

const Result = struct {
    status: Status,
    data: []const u8 = "",
    message: ?[:0]const u8 = null,
    report: ?[:0]const u8 = null,
};

fn logNothing(
    comptime _: std.log.Level,
    comptime _: @TypeOf(.EnumLiteral),
    comptime _: []const u8,
    _: anytype,
) void {}

/// The Io the VM keeps for its clocks (`benchmark`) and stdio, none of which a call writes:
/// statically initialized, so loading the library installs no signal handlers in the host.
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn handle(result: *const Result) *kupcad_result {
    return @ptrCast(@constCast(result));
}

fn resultOf(ptr: *const kupcad_result) *const Result {
    return @ptrCast(@alignCast(ptr));
}

/// A result holding `data` and `report`, owned, taken.
fn succeeded(data: []const u8, report: ?[:0]const u8) *kupcad_result {
    const result = allocator.create(Result) catch {
        allocator.free(data);
        if (report) |r| allocator.free(r);
        return handle(&out_of_memory);
    };
    result.* = .{ .status = .ok, .data = data, .report = report };
    return handle(result);
}

/// A result saying `status` and `message` (copied), with `report` (owned, taken) when given.
fn failed(status: Status, message: []const u8, report: ?[:0]const u8) *kupcad_result {
    if (status == .out_of_memory) {
        if (report) |r| allocator.free(r);
        return handle(&out_of_memory);
    }
    const result = allocator.create(Result) catch {
        if (report) |r| allocator.free(r);
        return handle(&out_of_memory);
    };
    // kupcad.h promises UTF-8: a message quoting a name a file gave (a DXF layer's, in its
    // codepage) may hold any bytes
    const owned = json_text.textZ(allocator, message) catch {
        allocator.destroy(result);
        if (report) |r| allocator.free(r);
        return handle(&out_of_memory);
    };
    result.* = .{ .status = status, .message = owned, .report = report };
    return handle(result);
}

/// `ptr[0..len]`, where a host may pass NULL for nothing.
fn bytesOf(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else "";
}

pub export fn kupcad_abi_version() u32 {
    return ABI_VERSION;
}

pub export fn kupcad_version() *kupcad_result {
    const json = std.json.Stringify.valueAlloc(allocator, version.Info{}, .{}) catch return handle(&out_of_memory);
    return succeeded(json, null);
}

pub export fn kupcad_format(source: ?[*]const u8, source_len: usize) *kupcad_result {
    var diagnostic: embed.Diagnostic = .{};
    defer diagnostic.deinit(allocator);
    const formatted = embed.format(allocator, bytesOf(source, source_len), &diagnostic) catch |err| return switch (err) {
        error.OutOfMemory => handle(&out_of_memory),
        error.SyntaxError => failed(.script_error, diagnostic.message orelse "the script doesn't parse", null),
        // The formatter checks that its output means the same program; when it doesn't, it
        // has a bug, and the source stays as it was
        error.FormatChangedProgram => failed(.internal_error, "the formatter would change what the script does: please report it, with the script", null),
        else => failed(.internal_error, @errorName(err), null),
    };
    return succeeded(formatted, null);
}

pub export fn kupcad_check(source: ?[*]const u8, source_len: usize) *kupcad_result {
    const findings = embed.check(allocator, io(), bytesOf(source, source_len)) catch |err| return internal(err);
    return succeeded(findings, null);
}

pub export fn kupcad_params(source: ?[*]const u8, source_len: usize) *kupcad_result {
    const schema = embed.params(allocator, bytesOf(source, source_len)) catch |err| return internal(err);
    return succeeded(schema, null);
}

fn internal(err: anyerror) *kupcad_result {
    return if (err == error.OutOfMemory) handle(&out_of_memory) else failed(.internal_error, @errorName(err), null);
}

pub export fn kupcad_build(
    source: ?[*]const u8,
    source_len: usize,
    format: ?[*:0]const u8,
    params_json: ?[*]const u8,
    params_json_len: usize,
    files: ?[*]const u8,
    files_len: usize,
    memory_limit: u64,
    timeout_ms: u64,
    draco: bool,
) *kupcad_result {
    // A host that loads the library may fork between builds (a preforking web server)
    defer manifold.releaseWorkers();
    const format_name = std.mem.span(format orelse return failed(.invalid_argument, "no format: one of " ++ api.ExportFormat.NAMES, null));
    var diagnostic: embed.Diagnostic = .{};
    defer diagnostic.deinit(allocator);
    var report: api.RunReport = .{};
    defer report.deinit(allocator);

    const options: embed.Build = .{
        .format = format_name,
        .params = bytesOf(params_json, params_json_len),
        .files = bytesOf(files, files_len),
        .draco = draco,
        .memory_limit = if (memory_limit == 0) null else std.math.cast(usize, memory_limit) orelse std.math.maxInt(usize),
        .time_limit_ms = if (timeout_ms == 0) null else timeout_ms,
        .report = &report,
    };
    const model = embed.build(allocator, io(), bytesOf(source, source_len), options, &diagnostic) catch |err| {
        const status: Status = switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.UnsupportedFormat, error.InvalidParams, error.MalformedFiles => .invalid_argument,
            // The script's: it doesn't parse or compile, raised, or left nothing to export
            else => .script_error,
        };
        // A build refused before it ran has no report
        const report_json = if (status == .script_error) reportOf(&report) else null;
        if (diagnostic.message) |message| return failed(status, message, report_json);
        return switch (err) {
            error.UnsupportedFormat => unsupportedFormat(format_name),
            error.MalformedFiles => failed(.invalid_argument, "the files aren't packed as kupcad.h describes: a length runs past the end", null),
            else => failed(status, @errorName(err), report_json),
        };
    };
    const report_json = reportOf(&report) orelse {
        allocator.free(model);
        return handle(&out_of_memory);
    };
    return succeeded(model, report_json);
}

/// The report as kupcad.h describes it, NUL-terminated; null when it can't be allocated.
fn reportOf(report: *const api.RunReport) ?[:0]const u8 {
    const json = embed.reportJson(allocator, report) catch return null;
    defer allocator.free(json);
    return allocator.dupeSentinel(u8, json, 0) catch null;
}

fn unsupportedFormat(name: []const u8) *kupcad_result {
    const message = std.fmt.allocPrint(allocator, "'{s}' isn't a format: one of {s}", .{ name, api.ExportFormat.NAMES }) catch return handle(&out_of_memory);
    defer allocator.free(message);
    return failed(.invalid_argument, message, null);
}

pub export fn kupcad_result_status(result: *const kupcad_result) Status {
    return resultOf(result).status;
}

pub export fn kupcad_result_data(result: *const kupcad_result, len: ?*usize) [*]const u8 {
    const data = resultOf(result).data;
    if (len) |l| l.* = data.len;
    return data.ptr;
}

pub export fn kupcad_result_message(result: *const kupcad_result, len: ?*usize) ?[*:0]const u8 {
    const message = resultOf(result).message orelse "";
    if (len) |l| l.* = message.len;
    return if (resultOf(result).message) |m| m.ptr else null;
}

pub export fn kupcad_result_report(result: *const kupcad_result) ?[*:0]const u8 {
    return if (resultOf(result).report) |r| r.ptr else null;
}

pub export fn kupcad_result_free(ptr: ?*kupcad_result) void {
    const result = resultOf(ptr orelse return);
    if (result == &out_of_memory) return;
    allocator.free(result.data);
    if (result.message) |m| allocator.free(m);
    if (result.report) |r| allocator.free(r);
    allocator.destroy(@constCast(result));
}
