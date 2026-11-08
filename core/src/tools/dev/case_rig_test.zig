//! The case rig (cases.zig, case_rig.zig): every case on the B-Rep engine passes or is
//! refused by design, every case with a chordal bound passes on the mesh engine, the
//! verdicts come out as they should, and the ladder report reads as documented.

const std = @import("std");
const testing = std.testing;
const cases = @import("cases.zig");
const rig = @import("case_rig.zig");

/// Any case takes well under this on either engine; a run past it is a hang.
const TIME_LIMIT_MS = 60_000;

test "case rig: on the B-Rep engine every case passes or is refused by design, but for the known frontier" {
    const results = try rig.runAll(testing.allocator, testing.io, .brep_native, TIME_LIMIT_MS);
    defer rig.freeResults(testing.allocator, results);
    var wrong: usize = 0;
    for (results) |r| {
        const known = for (cases.KNOWN_FRONTIER) |k| {
            if (std.mem.eql(u8, k.name, r.case.name)) break true;
        } else false;
        switch (r.outcome.verdict) {
            .pass => if (known) {
                wrong += 1;
                std.debug.print("{s} passes: take it off KNOWN_FRONTIER\n", .{r.case.name});
            },
            .refused => try testing.expectEqual(.refused, std.meta.activeTag(r.case.expect)),
            .fail, .crash, .hang => if (!known) {
                wrong += 1;
                std.debug.print("{s} ({s}): {s}: {s}\n", .{ r.case.name, r.case.script, r.outcome.verdict.label(), r.outcome.message orelse "" });
            },
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "case rig: on the mesh engine every case with a chordal bound passes" {
    for (&cases.CASES) |*case| {
        if (case.mesh_bound == null) continue;
        var outcome = try rig.run(testing.allocator, testing.io, case, .manifold, TIME_LIMIT_MS);
        defer outcome.deinit(testing.allocator);
        errdefer std.debug.print("{s} ({s}): {s}: {s}\n", .{ case.name, case.script, outcome.verdict.label(), outcome.message orelse "" });
        try testing.expectEqual(.pass, outcome.verdict);
    }
}

test "case rig: every case has a name of its own and an answer that is not a kernel's" {
    for (&cases.CASES, 0..) |*case, i| {
        try testing.expect(case.name.len > 0 and case.what.len > 0 and case.method.len > 0 and case.from.len > 0);
        for (cases.CASES[0..i]) |earlier| try testing.expect(!std.mem.eql(u8, earlier.name, case.name));
        switch (case.expect) {
            .measures => |m| try testing.expect(m.empty == (m.volume == 0)),
            .refused => try testing.expectEqual(@as(?f64, null), case.mesh_bound),
        }
    }
}

test "case rig: a wrong answer fails, a missing refusal fails, a refusal by design is counted apart, and a slow run hangs" {
    const wrong = cases.Case{ .tier = .primitives, .name = "wrong cube", .script = "cube(2)", .what = "", .method = "a wrong answer", .source = .analytic, .from = "this test", .expect = .{ .measures = .{ .volume = 9 } }, .mesh_bound = cases.EXACT };
    var failed = try rig.run(testing.allocator, testing.io, &wrong, .brep_native, TIME_LIMIT_MS);
    defer failed.deinit(testing.allocator);
    try testing.expectEqual(.fail, failed.verdict);
    try testing.expect(std.mem.indexOf(u8, failed.message.?, "volume 8, expected 9") != null);

    const landed = cases.Case{ .tier = .primitives, .name = "landed", .script = "cube(2)", .what = "", .method = "", .source = .analytic, .from = "this test", .expect = .{ .refused = .{ .feature = .boolean, .until = "M9" } }, .mesh_bound = null };
    var built = try rig.run(testing.allocator, testing.io, &landed, .brep_native, TIME_LIMIT_MS);
    defer built.deinit(testing.allocator);
    try testing.expectEqual(.fail, built.verdict);
    try testing.expect(std.mem.indexOf(u8, built.message.?, "wants its closed form") != null);

    const refused = cases.Case{ .tier = .booleans, .name = "refused", .script = "cube(2) + cube(2).translate(1, 1, 1)", .what = "", .method = "", .source = .analytic, .from = "this test", .expect = .{ .refused = .{ .feature = .boolean, .until = "M4" } }, .mesh_bound = null };
    var apart = try rig.run(testing.allocator, testing.io, &refused, .brep_native, TIME_LIMIT_MS);
    defer apart.deinit(testing.allocator);
    errdefer std.debug.print("refused sample: {s}\n", .{apart.message orelse ""});
    try testing.expectEqual(.refused, apart.verdict);
    try testing.expect(std.mem.indexOf(u8, apart.message.?, "until M4") != null);

    const slow = cases.Case{ .tier = .primitives, .name = "slow", .script = "begin\n  n = 0\n  while true\n    n += 1\n  end\nend", .what = "", .method = "", .source = .analytic, .from = "this test", .expect = .{ .measures = .{ .volume = 1 } }, .mesh_bound = null };
    var hung = try rig.run(testing.allocator, testing.io, &slow, .brep_native, 50);
    defer hung.deinit(testing.allocator);
    errdefer std.debug.print("slow sample: {s}\n", .{hung.message orelse ""});
    try testing.expectEqual(.hang, hung.verdict);
}

test "case rig: the ladder report lists each tier's counts and frontier" {
    const a = cases.CASES[0];
    var b = cases.CASES[1];
    b.name = "a box that fails";
    var c = cases.CASES[6];
    c.tier = .booleans;
    const results = [_]rig.Result{
        .{ .case = &a, .outcome = .{ .verdict = .pass } },
        .{ .case = &b, .outcome = .{ .verdict = .fail, .message = @constCast("volume 5, expected 6") } },
        .{ .case = &c, .outcome = .{ .verdict = .refused, .message = @constCast("until M4: can't") } },
    };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try rig.writeLadder(&out.writer, "B-Rep", &results);
    try testing.expectEqualStrings(
        \\Ladder on the B-Rep engine, 3 cases:
        \\  01 primitives: 1 pass, 1 fail; frontier: a box that fails (fail: volume 5, expected 6)
        \\  02 booleans: 1 refused by design
        \\  all: 1 pass, 1 fail, 1 refused by design; frontier: 01 primitives, a box that fails
        \\
    , out.written());
}
