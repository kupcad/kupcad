const std = @import("std");
const builtin = @import("builtin");

extern fn locus_parallel_for(
    start: usize,
    end: usize,
    func: *const fn (usize, ?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
) void;

/// A cross-platform parallel execution loop owned natively by the Locus kernel.
pub fn parallelFor(
    start: usize,
    end: usize,
    comptime Context: type,
    ctx: *Context,
    comptime func: fn (usize, *Context) void,
) void {
    if (builtin.target.cpu.arch == .wasm32) {
        var i: usize = start;
        while (i < end) : (i += 1) {
            func(i, ctx);
        }
    } else {
        const Wrapper = struct {
            fn c_func(idx: usize, c_ctx: ?*anyopaque) callconv(.c) void {
                const typed_ctx = @as(*Context, @ptrCast(@alignCast(c_ctx.?)));
                func(idx, typed_ctx);
            }
        };
        locus_parallel_for(start, end, Wrapper.c_func, ctx);
    }
}
