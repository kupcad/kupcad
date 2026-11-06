//! The trace of an operation (docs/architecture.md §12): with `options.trace` set, the body
//! after each phase goes to the host's sink as its JSON (io/body_json.zig), so a failing
//! operation is inspected as a sequence of bodies. Without a sink, `phase` costs a branch.

const std = @import("std");
const diagnostics = @import("../diagnostics.zig");
const Body = @import("../topology/body.zig").Body;
const body_json = @import("body_json.zig");

/// Sends `body` to the sink of `options`, if any, as the state after `phase` of `operation`.
pub fn phase(allocator: std.mem.Allocator, options: *const diagnostics.Options, body: *const Body, operation: []const u8, name: []const u8) error{OutOfMemory}!void {
    const sink = options.trace orelse return;
    // A dump fails for memory alone on a body an operation holds
    const text = body_json.dump(allocator, body) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    defer allocator.free(text);
    sink.write(sink.context, operation, name, text);
}
