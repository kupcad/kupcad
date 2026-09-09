const std = @import("std");
const builtin = @import("builtin");

extern fn locus_parallel_for(
    start: usize,
    end: usize,
    func: *const fn (usize, ?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
) void;

// --- Wasm Shared Threading State ---
var wasm_work_idx = std.atomic.Value(usize).init(0);
var wasm_work_end: usize = 0;
var wasm_work_ctx: ?*anyopaque = null;
var wasm_work_func: ?*const fn (usize, ?*anyopaque) callconv(.c) void = null;

/// Exported so JavaScript Web Workers can call in and steal work lock-free
export fn locus_wasm_worker_loop() void {
    const f = wasm_work_func orelse return;
    while (true) {
        // Atomically claim the next index
        const i = wasm_work_idx.fetchAdd(1, .acquire);
        if (i >= wasm_work_end) break;
        f(i, wasm_work_ctx);
    }
}

/// A cross-platform parallel execution loop owned natively by the Locus kernel.
pub fn parallelFor(
    start: usize,
    end: usize,
    comptime Context: type,
    ctx: *Context,
    comptime func: fn (usize, *Context) void,
) void {
    const Wrapper = struct {
        fn c_func(idx: usize, c_ctx: ?*anyopaque) callconv(.c) void {
            const typed_ctx = @as(*Context, @ptrCast(@alignCast(c_ctx.?)));
            func(idx, typed_ctx);
        }
    };

    if (builtin.target.cpu.arch == .wasm32) {
        if (builtin.single_threaded) {
            // Standard sequential fallback (wasm_threads = false)
            var i: usize = start;
            while (i < end) : (i += 1) {
                func(i, ctx);
            }
        } else {
            // Initialize the shared state for the Web Workers
            wasm_work_idx.store(start, .release);
            wasm_work_end = end;
            wasm_work_ctx = ctx;
            wasm_work_func = Wrapper.c_func;

            // FUTURE: Add an `extern fn` call here to tell JS to wake up the Web Workers

            // The main thread also pitches in and processes the queue!
            locus_wasm_worker_loop();

            // FUTURE: Add an atomic wait/yield here to block until all workers finish
        }
    } else {
        // Native Desktop uses Intel TBB C++ bindings
        locus_parallel_for(start, end, Wrapper.c_func, ctx);
    }
}
