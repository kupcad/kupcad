//! `Parallel`: how an operation splits independent work over threads, supplied by the host
//! (KupCAD's over oneTBB; a browser's workers one day), with `serial` as the default that
//! runs everything on the calling thread, in order. Locus itself starts no thread
//! (docs/architecture.md §4, D4). Whatever runs in parallel merges its results in index
//! order, so a threaded run gives the bytes a serial one does (§6).

const std = @import("std");

pub const Parallel = struct {
    context: ?*anyopaque,
    vtable: *const VTable,

    /// The body of a range, as the implementation calls it: `body(index, body_context)`.
    /// C-callable, so a host in any language can implement `forRange`.
    pub const Body = *const fn (index: usize, body_context: *anyopaque) callconv(.c) void;

    pub const VTable = struct {
        /// Calls `body(i, body_context)` once for each `i` in `[start, end)`, in any order
        /// and on any thread, and returns once every call has. `start >= end` runs nothing.
        forRange: *const fn (context: ?*anyopaque, start: usize, end: usize, body_context: *anyopaque, body: Body) void,
        /// How many threads `forRange` may use: 1 for a serial implementation.
        threads: *const fn (context: ?*anyopaque) usize,
    };

    /// The default: every index on the calling thread, in order.
    pub const serial: Parallel = .{ .context = null, .vtable = &serial_vtable };

    /// Calls `func(i, ctx)` once for each `i` in `[start, end)`; with a threaded
    /// implementation on several threads at once, so `func` must be safe to run alongside
    /// itself and each index's work independent of the others'.
    pub fn forRange(self: Parallel, start: usize, end: usize, comptime Context: type, ctx: *Context, comptime func: fn (usize, *Context) void) void {
        const Adapter = struct {
            fn body(index: usize, body_context: *anyopaque) callconv(.c) void {
                func(index, @ptrCast(@alignCast(body_context)));
            }
        };
        if (start >= end) return;
        self.vtable.forRange(self.context, start, end, @ptrCast(ctx), Adapter.body);
    }

    pub fn threads(self: Parallel) usize {
        return self.vtable.threads(self.context);
    }
};

const serial_vtable: Parallel.VTable = .{ .forRange = serialForRange, .threads = serialThreads };

fn serialForRange(_: ?*anyopaque, start: usize, end: usize, body_context: *anyopaque, body: Parallel.Body) void {
    var i = start;
    while (i < end) : (i += 1) body(i, body_context);
}

fn serialThreads(_: ?*anyopaque) usize {
    return 1;
}
