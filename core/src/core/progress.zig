//! `Progress`: what long work tells of itself as it goes, for a host to show: the step it
//! is at, and how much of a measured amount is done. The work below the CLI (the evaluator,
//! the session, the package manager) takes one without knowing who shows it; the CLI's
//! progress line (cli/progress.zig) is the one host. `Progress.none`, the default, tells no
//! one.

const std = @import("std");

pub const Progress = struct {
    context: ?*anyopaque = null,
    vtable: *const VTable = &silent,

    pub const none: Progress = .{};

    /// What an amount counts.
    pub const Unit = enum { files, bytes };

    /// How much of a step is done: `done` of `total` `unit`s, the total null when it isn't
    /// known (a download without a Content-Length).
    pub const Amount = struct {
        done: u64,
        total: ?u64 = null,
        unit: Unit,
    };

    pub const VTable = struct {
        step: *const fn (context: ?*anyopaque, name: []const u8, amount: ?Amount) void,
        done: *const fn (context: ?*anyopaque, name: []const u8) void,
    };

    /// The work is at the step `name` (the host copies it), with `amount` done when it is
    /// measured; told again as the amount grows. Shown until `done`, in place of the stage
    /// the host set. Callable from any thread.
    pub fn step(self: Progress, name: []const u8, amount: ?Amount) void {
        self.vtable.step(self.context, name, amount);
    }

    /// The step `name` ended. The host shows its own stage again, unless another step was
    /// told since (work on another thread), which stays.
    pub fn done(self: Progress, name: []const u8) void {
        self.vtable.done(self.context, name);
    }

    const silent: VTable = .{ .step = ignoreStep, .done = ignoreDone };

    fn ignoreStep(_: ?*anyopaque, _: []const u8, _: ?Amount) void {}
    fn ignoreDone(_: ?*anyopaque, _: []const u8) void {}
};
