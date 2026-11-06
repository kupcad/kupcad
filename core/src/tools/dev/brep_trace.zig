//! `kupcad dev brep-trace` (locus/docs/architecture.md §12): a script run on the B-Rep engine
//! with Locus's trace on, the body after each phase of each operation written as a file
//! into a folder, `001-transform-mapped.json`, `002-transform-checked.json`, …, so a
//! failing operation is read as a sequence of bodies. `FileSink` is the trace sink; `run`
//! sets it on the driver around one build.

const std = @import("std");
const api = @import("../../api.zig");
const driver = @import("../../kernel/engines/brep/driver.zig");
const Vfs = @import("../../vfs/vfs.zig").Vfs;

/// A sink writing each phase's JSON into `dir`, numbered in order of arrival. A write that
/// fails is kept in `failure` (the sink can't return it) and ends the trace.
pub const FileSink = struct {
    io: std.Io,
    dir: std.Io.Dir,
    count: usize = 0,
    failure: ?anyerror = null,

    pub fn trace(self: *FileSink) driver.Trace {
        return .{ .context = self, .write = write };
    }

    fn write(context: ?*anyopaque, operation: []const u8, phase: []const u8, body_json: []const u8) void {
        const self: *FileSink = @ptrCast(@alignCast(context.?));
        if (self.failure != null) return;
        self.count += 1;
        var name_buf: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{d:0>3}-{s}-{s}.json", .{ self.count, operation, phase }) catch {
            self.failure = error.NameTooLong;
            return;
        };
        self.dir.writeFile(self.io, .{ .sub_path = name, .data = body_json }) catch |err| {
            self.failure = err;
        };
    }
};

/// Builds `source` on the B-Rep engine (reading files through `files`) with every phase
/// written into `dir`; the number of phases written. A script that fails still leaves the
/// phases before its failure; its message is in `diagnostic`.
pub fn run(allocator: std.mem.Allocator, io: std.Io, source: []const u8, files: Vfs, dir: std.Io.Dir, diagnostic: *api.BuildDiagnostic) !usize {
    var sink = FileSink{ .io = io, .dir = dir };
    driver.setTrace(sink.trace());
    defer driver.setTrace(null);
    if (api.buildModel(allocator, io, source, .{ .format = .step, .vfs = files, .diagnostic = diagnostic })) |step| {
        allocator.free(step);
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    }
    if (sink.failure) |err| return err;
    return sink.count;
}
