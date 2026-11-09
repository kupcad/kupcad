//! The trace of an operation (docs/architecture.md §12): with `options.trace` set, the
//! operation's arguments go to the host's sink first, as JSON, then the body after each
//! phase (io/body_json.zig), so a failing operation is inspected as a sequence of bodies
//! and replayed from its inputs. Without a sink, each call costs a branch.

const std = @import("std");
const diagnostics = @import("../diagnostics.zig");
const Body = @import("../topology/body.zig").Body;
const body_json = @import("body_json.zig");

/// Sends `operation`'s arguments to the sink of `options`, if any, as the phase
/// "arguments": `args` is plain data std.json writes (numbers, arrays, enums as their
/// names, structs of them), the inputs that are not bodies (the bodies are the phases').
pub fn arguments(allocator: std.mem.Allocator, options: *const diagnostics.Options, operation: []const u8, args: anytype) error{OutOfMemory}!void {
    return data(allocator, options, operation, "arguments", args);
}

/// Sends plain data (as `arguments` takes it) to the sink of `options`, if any, as the
/// phase `name` of `operation`: an operation's arguments, a writer's report.
pub fn data(allocator: std.mem.Allocator, options: *const diagnostics.Options, operation: []const u8, name: []const u8, value: anytype) error{OutOfMemory}!void {
    const sink = options.trace orelse return;
    const text = std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    defer allocator.free(text);
    sink.write(sink.context, operation, name, text);
}

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
