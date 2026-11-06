//! `kupcad dev brep-readiness` (locus/docs/architecture.md §12): every script given, built
//! on the B-Rep engine as a STEP export builds it, and what each still lacks there, so the
//! kernel's milestones are checked against the examples and not only the parity table.
//! `check` runs one script; `writeReport` prints the lines and the count.

const std = @import("std");
const api = @import("../../api.zig");
const Vfs = @import("../../vfs/vfs.zig").Vfs;

/// What a script's run on the B-Rep engine came to.
pub const Outcome = union(enum) {
    builds,
    /// The first failure, as the CLI prints it (owned).
    refused: []u8,
    /// A failure with no message of the script's (out of memory, a crash kept).
    failed: anyerror,

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        if (self.* == .refused) allocator.free(self.refused);
        self.* = undefined;
    }
};

pub const Result = struct {
    /// The script as it was named.
    path: []const u8,
    outcome: Outcome,
};

/// Runs `source` on the B-Rep engine (a STEP build, which needs it), reading files through
/// `files`.
pub fn check(allocator: std.mem.Allocator, io: std.Io, source: []const u8, files: Vfs) !Outcome {
    var diag: api.BuildDiagnostic = .{};
    defer diag.deinit(allocator);
    // The run's output and warnings are kept off the console: the report is the output
    var report: api.RunReport = .{};
    defer report.deinit(allocator);
    const step = api.buildModel(allocator, io, source, .{ .format = .step, .vfs = files, .diagnostic = &diag, .report = &report }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const message = diag.message orelse return .{ .failed = err };
            return .{ .refused = try allocator.dupe(u8, message) };
        },
    };
    allocator.free(step);
    return .builds;
}

/// A line per script, then how many build.
pub fn writeReport(out: *std.Io.Writer, results: []const Result) !void {
    var builds: usize = 0;
    for (results) |r| {
        switch (r.outcome) {
            .builds => {
                builds += 1;
                try out.print("{s}: builds\n", .{r.path});
            },
            .refused => |message| try out.print("{s}: {s}\n", .{ r.path, message }),
            .failed => |err| try out.print("{s}: failed ({s})\n", .{ r.path, @errorName(err) }),
        }
    }
    try out.print("{d} of {d} script{s} build on the B-Rep engine\n", .{ builds, results.len, if (results.len == 1) "" else "s" });
}
