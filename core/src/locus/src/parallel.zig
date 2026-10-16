//! `parallelFor`: runs a function for each index of a range, on oneTBB's threads where the
//! build has oneTBB (native builds), and in order on the calling thread where it hasn't
//! (WebAssembly, or a build with -Dmanifold_parallel=false). No operation uses it yet; it
//! is ready for the first that will.

extern fn locus_parallel_for(
    start: usize,
    end: usize,
    func: *const fn (usize, ?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
) void;
extern fn locus_parallel_threads() bool;

/// Whether `parallelFor` spreads its work over threads (the build has oneTBB).
pub fn spreadsOverThreads() bool {
    return locus_parallel_threads();
}

/// Calls `func(i, ctx)` once for each `i` in [start, end), in no particular order and, with
/// oneTBB, on several threads at once: `func` must be safe to run alongside itself, and each
/// index's work independent of the others'.
pub fn parallelFor(
    start: usize,
    end: usize,
    comptime Context: type,
    ctx: *Context,
    comptime func: fn (usize, *Context) void,
) void {
    const Wrapper = struct {
        fn c_func(idx: usize, c_ctx: ?*anyopaque) callconv(.c) void {
            const typed_ctx: *Context = @ptrCast(@alignCast(c_ctx.?));
            func(idx, typed_ctx);
        }
    };
    // oneTBB's ranges must not run backwards
    if (start >= end) return;
    locus_parallel_for(start, end, Wrapper.c_func, ctx);
}
