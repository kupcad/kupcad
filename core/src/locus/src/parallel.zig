//! `parallelFor`: runs a function for each index of a range, in order on the calling thread.
//! It ran on oneTBB's threads through bindings/parallel_c.cpp, which went with the package
//! (docs/architecture.md §4, D4): a `Parallel` interface the host implements (KupCAD's over
//! oneTBB, the default serial) replaces it later in M0. No operation uses it yet.

/// Calls `func(i, ctx)` once for each `i` in [start, end), in order; nothing for an empty or
/// backwards range.
pub fn parallelFor(
    start: usize,
    end: usize,
    comptime Context: type,
    ctx: *Context,
    comptime func: fn (usize, *Context) void,
) void {
    if (start >= end) return;
    var i = start;
    while (i < end) : (i += 1) func(i, ctx);
}
