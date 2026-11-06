//! Locus's `Parallel` over oneTBB (src/bindings/parallel_c.cpp): the B-Rep engine's
//! independent work runs on oneTBB's threads where the build has them (native builds with
//! -Dmanifold_parallel, the default), and in order on the calling thread where it hasn't
//! (WebAssembly). `kupcad_set_max_threads` (manifold.zig) caps these threads too, since
//! oneTBB's global control is one per process.

const locus = @import("locus");

extern fn kupcad_parallel_for(start: usize, end: usize, body: locus.parallel.Parallel.Body, ctx: *anyopaque) callconv(.c) void;
extern fn kupcad_parallel_threads() callconv(.c) usize;

fn forRange(_: ?*anyopaque, start: usize, end: usize, body_context: *anyopaque, body: locus.parallel.Parallel.Body) void {
    // oneTBB's ranges must not run backwards
    if (start >= end) return;
    kupcad_parallel_for(start, end, body, body_context);
}

fn threads(_: ?*anyopaque) usize {
    return kupcad_parallel_threads();
}

const vtable: locus.parallel.Parallel.VTable = .{ .forRange = forRange, .threads = threads };

/// What the B-Rep driver hands Locus.
pub const parallel: locus.parallel.Parallel = .{ .context = null, .vtable = &vtable };

/// Whether `parallel` spreads work over threads (the build has oneTBB).
pub fn spreadsOverThreads() bool {
    return kupcad_parallel_threads() > 1;
}
