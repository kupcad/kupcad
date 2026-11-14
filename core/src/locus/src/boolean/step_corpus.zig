//! The boolean results the tests check, written as STEP for OpenCascade to read back (the
//! research review's item 18; `pnpm check:locus-step` from the repository root runs
//! core/scripts/validate-locus-step.py over them): every result `pipeline_test.sound`
//! passes (the corpus's cases, the degeneracy tests', the pipeline's and the coverage
//! corpus's) and the results of the solids fuzzer's plain run, each as `NNNNN.step` in the
//! directory `-Dstep-corpus` names, with a line of `manifest.txt`: the file, what Locus says
//! of it (its solids, faces, exact volume and area, and the largest gap its boolean
//! reported: a reader's volume may differ by the gap over the area), and what made it.
//! Nothing is written without the option: the tests touch no file system otherwise, and
//! run under wasmtime.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Body = @import("../topology/body.zig").Body;
const step_write = @import("../io/step_write.zig");
const decompose = @import("../construct/decompose.zig");
const mass = @import("../measure/mass.zig");
const Diagnostics = @import("../diagnostics.zig").Diagnostics;

/// The directory the files go to; empty, none are written.
const DIR: []const u8 = @import("test_paths").step_corpus;
/// The manifest's name in `DIR`.
const MANIFEST = "manifest.txt";

/// The files written so far, the next one's number.
var written: u32 = 0;

/// Whether results are written: the option given, on a system with files.
pub fn enabled() bool {
    return DIR.len > 0 and builtin.os.tag != .wasi;
}

/// `body`, made by `what`, its boolean's largest gap `gap`, written as the next file; an
/// empty result, with nothing to read back, is not. A body of several solids with voids is
/// written as its parts, as KupCAD's driver writes it.
pub fn add(body: *const Body, what: []const u8, gap: f64) !void {
    if (!enabled() or body.kind != .solid or body.isEmpty()) return;
    const allocator = testing.allocator;
    const io = testing.io;
    var diag = Diagnostics.init(allocator);
    defer diag.deinit();
    var parts: []Body = &.{};
    defer {
        for (parts) |*p| p.deinit();
        allocator.free(parts);
    }
    var bodies: std.ArrayList(*const Body) = .empty;
    defer bodies.deinit(allocator);
    if (step_write.writesWhole(body)) {
        try bodies.append(allocator, body);
    } else {
        parts = try decompose.decompose(allocator, body, .{}, &diag);
        for (parts) |*p| try bodies.append(allocator, p);
    }
    const text = try step_write.write(allocator, bodies.items);
    defer allocator.free(text);
    const m = try mass.mass(body, .{}, &diag);
    var solids: usize = 0;
    for (body.shells.items) |s| solids += @intFromBool(!s.tombstone and s.kind == .outer);

    try std.Io.Dir.cwd().createDirPath(io, DIR);
    var dir = try std.Io.Dir.cwd().openDir(io, DIR, .{});
    defer dir.close(io);
    var name_buf: [16]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{d:0>5}.step", .{written});
    try dir.writeFile(io, .{ .sub_path = name, .data = text });
    var manifest = try dir.createFile(io, MANIFEST, .{ .truncate = written == 0 });
    defer manifest.close(io);
    var line_buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "{s} solids={d} faces={d} volume={e} area={e} gap={e} {s}\n", .{ name, solids, body.counts().faces, m.volume, m.area, gap, what });
    try manifest.writePositionalAll(io, line, try manifest.length(io));
    written += 1;
}
