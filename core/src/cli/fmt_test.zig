const std = @import("std");
const testing = std.testing;
const fmt_cmd = @import("fmt.zig");

const FORMATTED = "x = 1 + 2\n";
const UNFORMATTED = "x=1+  2";
const BROKEN = "x = )\n";

/// A temp dir with one formatted, one unformatted and one broken script.
const Fixture = struct {
    tmp: testing.TmpDir,
    dir: [:0]u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "good.kup", .data = FORMATTED });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "messy.kup", .data = UNFORMATTED });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "broken.kup", .data = BROKEN });
        return .{ .tmp = tmp, .dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator) };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.dir);
        self.tmp.cleanup();
    }

    fn path(self: *Fixture, name: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ self.dir, name });
    }

    fn read(self: *Fixture, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1 << 16));
    }

    /// Runs fmt on `names` in `mode`; returns the outcome and everything it reported.
    fn run(self: *Fixture, names: []const []const u8, mode: fmt_cmd.Mode, output: *std.Io.Writer.Allocating) !fmt_cmd.Outcome {
        var paths: std.ArrayList([]const u8) = .empty;
        defer {
            for (paths.items) |p| testing.allocator.free(p);
            paths.deinit(testing.allocator);
        }
        for (names) |name| try paths.append(testing.allocator, try self.path(name));
        return fmt_cmd.run(testing.allocator, paths.items, .{}, mode, .{ .io = testing.io, .capture = &output.writer });
    }

    fn expectContents(self: *Fixture, name: []const u8, expected: []const u8) !void {
        const actual = try self.read(name);
        defer testing.allocator.free(actual);
        try testing.expectEqualStrings(expected, actual);
    }
};

test "fmt: without a flag, prints each file formatted and changes nothing" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(fmt_cmd.Outcome.success, try fx.run(&.{"messy.kup"}, .print, &out));
    try testing.expectEqualStrings(FORMATTED, out.written());
    try fx.expectContents("messy.kup", UNFORMATTED);
}

test "fmt --check: passes on formatted files, names the others and fails, writing nothing" {
    var fx = try Fixture.init();
    defer fx.deinit();

    var clean: std.Io.Writer.Allocating = .init(testing.allocator);
    defer clean.deinit();
    try testing.expectEqual(fmt_cmd.Outcome.success, try fx.run(&.{"good.kup"}, .check, &clean));
    try testing.expectEqualStrings("", clean.written());

    var dirty: std.Io.Writer.Allocating = .init(testing.allocator);
    defer dirty.deinit();
    try testing.expectEqual(fmt_cmd.Outcome.failure, try fx.run(&.{ "good.kup", "messy.kup" }, .check, &dirty));
    const messy = try fx.path("messy.kup");
    defer testing.allocator.free(messy);
    const expected = try testing.allocator.print("{s}\n1 file needs formatting; run kupcad fmt --write to fix it.\n", .{messy});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, dirty.written());
    try fx.expectContents("messy.kup", UNFORMATTED);
}

test "fmt --write: rewrites only the files that change, keeping their permissions" {
    var fx = try Fixture.init();
    defer fx.deinit();
    const messy_file = try fx.tmp.dir.openFile(testing.io, "messy.kup", .{});
    const mode_before = (try messy_file.stat(testing.io)).permissions;
    messy_file.close(testing.io);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectEqual(fmt_cmd.Outcome.success, try fx.run(&.{ "good.kup", "messy.kup" }, .write, &out));
    const messy = try fx.path("messy.kup");
    defer testing.allocator.free(messy);
    const listed = try testing.allocator.print("{s}\n", .{messy});
    defer testing.allocator.free(listed);
    try testing.expectEqualStrings(listed, out.written());
    try fx.expectContents("messy.kup", FORMATTED);
    try fx.expectContents("good.kup", FORMATTED);
    const after = try fx.tmp.dir.statFile(testing.io, "messy.kup", .{});
    try testing.expectEqual(mode_before, after.permissions);

    // Nothing is left to format.
    var again: std.Io.Writer.Allocating = .init(testing.allocator);
    defer again.deinit();
    try testing.expectEqual(fmt_cmd.Outcome.success, try fx.run(&.{ "good.kup", "messy.kup" }, .check, &again));
}

test "fmt: a file with syntax errors fails and is never written" {
    var fx = try Fixture.init();
    defer fx.deinit();
    for ([_]fmt_cmd.Mode{ .print, .check, .write }) |mode| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try testing.expectEqual(fmt_cmd.Outcome.failure, try fx.run(&.{"broken.kup"}, mode, &out));
        try testing.expect(std.mem.find(u8, out.written(), "has syntax errors") != null);
        try fx.expectContents("broken.kup", BROKEN);
    }
}
