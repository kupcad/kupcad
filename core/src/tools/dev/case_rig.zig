//! Runs the case rig (cases.zig): each case's script on an engine, measured and judged
//! against the case's own answer, and the ladder report with each tier's frontier. The
//! verdicts: `pass`; `fail` (a result off its answer, a refusal where a result was due, or
//! a result where a refusal was due: the milestone landed and the case wants its closed
//! form); `crash` (the host failed under it: out of memory, a kernel failure with no
//! message); `hang` (the run went past its time limit); `refused` (by design, the feature
//! named, counted apart). What the rig can't tell in-process is a crash of the process
//! itself: that ends the run, and the harness around it sees it.

const std = @import("std");
const api = @import("../../api.zig");
const chunk = @import("../../vm/chunk.zig");
const Compiler = @import("../../compiler/compiler.zig").Compiler;
const geom = @import("../../core/geometry_handle.zig");
const kernel = @import("../../kernel/kernel.zig");
const cases = @import("cases.zig");

/// What the B-Rep scripts start with.
const BREP_CONFIG = "CAD.config(engine: :brep)\n";
/// How the VM names a run that went past its limit (VM's TIME_LIMIT_MESSAGE).
const TIME_LIMIT_PREFIX = "Time limit";

pub const Verdict = enum {
    pass,
    fail,
    crash,
    hang,
    refused,

    pub fn label(self: Verdict) []const u8 {
        return switch (self) {
            .pass => "pass",
            .fail => "fail",
            .crash => "crash",
            .hang => "hang",
            .refused => "refused by design",
        };
    }
};

pub const Outcome = struct {
    verdict: Verdict,
    /// Why, for anything but a pass (owned).
    message: ?[]u8 = null,

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        if (self.message) |m| allocator.free(m);
        self.* = undefined;
    }
};

pub const Result = struct {
    case: *const cases.Case,
    outcome: Outcome,
};

/// Runs `case` on `engine` within `time_limit_ms` (null for no limit) and judges it.
pub fn run(allocator: std.mem.Allocator, io: std.Io, case: *const cases.Case, engine: geom.EngineType, time_limit_ms: ?u64) !Outcome {
    const source = try std.mem.concat(allocator, u8, &.{ if (engine == .brep_native) BREP_CONFIG else "", "r = ", case.script });
    defer allocator.free(source);
    var doc = try api.Document.parse(allocator, source);
    defer doc.deinit();
    if (doc.diagnostics.len > 0) return failure(allocator, "the script does not parse: {s}", .{doc.diagnostics[0].message});

    var vm = api.newVm(allocator, io, &doc.line_index, .{ .muted = true, .silent = true, .time_limit_ms = time_limit_ms }) catch |err| return crashed(allocator, err);
    defer vm.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(allocator);
    var comp = Compiler.forDocument(allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    comp.compile(doc.tree.root) catch |err| return failure(allocator, "the script does not compile: {s}", .{@errorName(err)});

    if (vm.interpret(&out_chunk) != .ok) return judgeError(allocator, case, vm.last_error);
    const r = vm.globals.get("r") orelse return failure(allocator, "the script left no r", .{});
    if (!r.isGeometry()) return failure(allocator, "r is not a solid", .{});
    const handle = vm.ensureConcrete(r) catch |err| {
        if (vm.last_error) |message| return judgeError(allocator, case, message);
        if (kernel.takeFailure()) |why| return judgeError(allocator, case, why);
        return crashed(allocator, err);
    };
    if (handle.engine != engine) return failure(allocator, "built on the other engine", .{});
    return judgeMeasures(allocator, case, engine, handle);
}

/// A run that ended in the script's error: a hang, the refusal the case expects, or a
/// failure.
fn judgeError(allocator: std.mem.Allocator, case: *const cases.Case, message: ?[]const u8) !Outcome {
    const text = message orelse "no message";
    if (std.mem.startsWith(u8, text, TIME_LIMIT_PREFIX)) return .{ .verdict = .hang, .message = try allocator.dupe(u8, text) };
    switch (case.expect) {
        .refused => |refusal| {
            if (refusal.feature) |feature| {
                // The feature as the engine names it, "can't combine solids", before any
                // parenthesis of its description
                const described = feature.describe();
                const short = described[0 .. std.mem.indexOf(u8, described, " (") orelse described.len];
                if (std.mem.indexOf(u8, text, "can't") != null and std.mem.indexOf(u8, text, short) != null) return .{ .verdict = .refused, .message = try std.fmt.allocPrint(allocator, "until {s}: {s}", .{ refusal.until, text }) };
                return failure(allocator, "refused, but not for {s}: {s}", .{ @tagName(feature), text });
            }
            const says = refusal.says orelse return failure(allocator, "the case names no feature and no message", .{});
            if (std.mem.indexOf(u8, text, says) != null) return .{ .verdict = .refused, .message = try std.fmt.allocPrint(allocator, "until {s}: {s}", .{ refusal.until, text }) };
            return failure(allocator, "refused, but not saying \"{s}\": {s}", .{ says, text });
        },
        .measures => return failure(allocator, "refused: {s}", .{text}),
    }
}

/// A result against the case's measures: within `EXACT` on the B-Rep engine, within the
/// case's chordal bound on the mesh engine.
fn judgeMeasures(allocator: std.mem.Allocator, case: *const cases.Case, engine: geom.EngineType, handle: geom.GeometryHandle) !Outcome {
    const measures = switch (case.expect) {
        .measures => |m| m,
        .refused => |refusal| return failure(allocator, "built, where a refusal was expected until {s}: the case wants its closed form", .{refusal.until}),
    };
    const bound = if (engine == .brep_native) cases.EXACT else case.mesh_bound orelse return failure(allocator, "the mesh engine has no bound for this case", .{});
    const empty = kernel.isEmpty(handle);
    if (empty != measures.empty) return failure(allocator, "{s}, expected {s}", .{ if (empty) "empty" else "a solid", if (measures.empty) "nothing" else "a solid" });
    if (empty) return .{ .verdict = .pass };
    const volume = kernel.volume(handle);
    if (!within(volume, measures.volume, bound)) return failure(allocator, "volume {d}, expected {d} ({s})", .{ volume, measures.volume, case.method });
    if (measures.area) |expected| {
        const area = kernel.surfaceArea(handle);
        if (!within(area, expected, bound)) return failure(allocator, "area {d}, expected {d} ({s})", .{ area, expected, case.method });
    }
    return .{ .verdict = .pass };
}

fn within(actual: f64, expected: f64, relative: f64) bool {
    return @abs(actual - expected) <= relative * @max(@abs(expected), 1);
}

fn failure(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Outcome {
    return .{ .verdict = .fail, .message = try std.fmt.allocPrint(allocator, fmt, args) };
}

fn crashed(allocator: std.mem.Allocator, err: anyerror) !Outcome {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .verdict = .crash, .message = try allocator.dupe(u8, @errorName(err)) };
}

/// Every case on `engine`, in the ladder's order; the caller frees each outcome.
pub fn runAll(allocator: std.mem.Allocator, io: std.Io, engine: geom.EngineType, time_limit_ms: ?u64) ![]Result {
    var results = try allocator.alloc(Result, cases.CASES.len);
    errdefer allocator.free(results);
    var done: usize = 0;
    errdefer for (results[0..done]) |*r| r.outcome.deinit(allocator);
    for (&cases.CASES, 0..) |*case, i| {
        results[i] = .{ .case = case, .outcome = try run(allocator, io, case, engine, time_limit_ms) };
        done += 1;
    }
    return results;
}

pub fn freeResults(allocator: std.mem.Allocator, results: []Result) void {
    for (results) |*r| r.outcome.deinit(allocator);
    allocator.free(results);
}

/// The ladder: a line per tier with its counts and its frontier (the first case that
/// fails, crashes or hangs), then the totals and the first frontier of all.
pub fn writeLadder(out: *std.Io.Writer, engine_name: []const u8, results: []const Result) !void {
    var totals = std.enums.EnumArray(Verdict, usize).initFill(0);
    var first_frontier: ?*const Result = null;
    try out.print("Ladder on the {s} engine, {d} cases:\n", .{ engine_name, results.len });
    for (std.enums.values(cases.Tier)) |tier| {
        var counts = std.enums.EnumArray(Verdict, usize).initFill(0);
        var frontier: ?*const Result = null;
        var any = false;
        for (results) |*r| {
            if (r.case.tier != tier) continue;
            any = true;
            counts.getPtr(r.outcome.verdict).* += 1;
            totals.getPtr(r.outcome.verdict).* += 1;
            if (frontier == null and isFrontier(r.outcome.verdict)) frontier = r;
        }
        if (!any) continue;
        if (first_frontier == null) first_frontier = frontier;
        try out.print("  {d:0>2} {s}:", .{ @backingInt(tier), tier.label() });
        try writeCounts(out, &counts);
        if (frontier) |r| {
            try out.print("; frontier: {s} ({s}: {s})", .{ r.case.name, r.outcome.verdict.label(), r.outcome.message orelse "" });
        }
        try out.writeAll("\n");
    }
    try out.writeAll("  all:");
    try writeCounts(out, &totals);
    if (first_frontier) |r| {
        try out.print("; frontier: {d:0>2} {s}, {s}\n", .{ @backingInt(r.case.tier), r.case.tier.label(), r.case.name });
    } else {
        try out.writeAll("; no frontier\n");
    }
}

fn isFrontier(verdict: Verdict) bool {
    return switch (verdict) {
        .fail, .crash, .hang => true,
        .pass, .refused => false,
    };
}

fn writeCounts(out: *std.Io.Writer, counts: *const std.enums.EnumArray(Verdict, usize)) !void {
    var first = true;
    for (std.enums.values(Verdict)) |verdict| {
        const n = counts.get(verdict);
        if (n == 0) continue;
        try out.print("{s}{d} {s}", .{ if (first) " " else ", ", n, verdict.label() });
        first = false;
    }
}
