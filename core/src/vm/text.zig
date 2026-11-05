//! `Text`: what the VM or a native writes out for a script, a String it makes (an
//! interpolation, `inspect`, `%`, an error's message) or what it prints (`puts`, `warn`), in
//! memory the memory limit counts as it grows. Written in the VM's own allocator, outside the
//! limit, a structure shown whole took hundreds of megabytes before the String it made was
//! refused, and printed, never was.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("vm.zig").VM;

pub const Text = struct {
    vm: *VM,
    out: std.Io.Writer.Allocating,

    pub fn init(vm: *VM) Text {
        return .{ .vm = vm, .out = .init(vm.gc.trackingAllocator()) };
    }

    pub fn deinit(self: *Text) void {
        self.out.deinit();
    }

    /// `val` as `puts` shows it (VM.writeDisplay): an instance by its to_s, a script's too.
    pub fn display(self: *Text, val: value.Value) !void {
        self.vm.writeDisplay(val, &self.out.writer) catch |err| return refused(err);
    }

    /// `val` as `inspect` shows it (VM.writeInspect).
    pub fn inspect(self: *Text, val: value.Value) !void {
        self.vm.writeInspect(val, &self.out.writer) catch |err| return refused(err);
    }

    /// `val` as the VM writes it, calling no script's method: `inspect` quotes a String.
    pub fn stringify(self: *Text, val: value.Value, is_inspect: bool) error{OutOfMemory}!void {
        val.stringify(is_inspect, &self.out.writer) catch return error.OutOfMemory;
    }

    pub fn writeAll(self: *Text, bytes: []const u8) error{OutOfMemory}!void {
        self.out.writer.writeAll(bytes) catch return error.OutOfMemory;
    }

    /// The writer, for a helper that writes into the Text; what it fails with is
    /// `refused`'s to name.
    pub fn writer(self: *Text) *std.Io.Writer {
        return &self.out.writer;
    }

    /// What has been written.
    pub fn written(self: *Text) []u8 {
        return self.out.written();
    }

    /// The text as a String, taken without a copy; the Text is empty after.
    pub fn toString(self: *Text) !value.Value {
        return self.vm.allocateStringTakeOwnership(try self.out.toOwnedSlice());
    }

    /// What `err`, from writing into a Text, is: its writer fails only when the memory limit
    /// refuses it room, an OutOfMemoryError for the script (it was "puts failed
    /// (WriteFailed)").
    pub fn refused(err: anyerror) anyerror {
        return if (err == error.WriteFailed) error.OutOfMemory else err;
    }
};
