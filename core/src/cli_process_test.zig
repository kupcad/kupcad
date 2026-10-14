//! Runs the built `kupcad` binary and checks what a shell or CI job sees: the exit
//! status and the text on stdout/stderr. Unit tests can't catch a command that prints an
//! error and then exits 0, which is exactly the bug class these guard.

const std = @import("std");
const testing = std.testing;
const options = @import("cli_test_options");

const VALID_SCRIPT = "cube(10)\n";

const Run = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }
};

/// Runs `kupcad args...` with `cwd` as its working directory, in `env` if given.
fn kupcad(cwd: []const u8, args: []const []const u8) !Run {
    return kupcadIn(cwd, args, null);
}

fn kupcadIn(cwd: []const u8, args: []const []const u8, env: ?*const std.process.Environ.Map) !Run {
    // The build hands us a path relative to the build root; the child runs elsewhere.
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, options.kupcad_exe, testing.allocator);
    defer testing.allocator.free(exe);
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, exe);
    try argv.appendSlice(testing.allocator, args);
    const res = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = cwd }, .environ_map = env });
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = res.stdout, .stderr = res.stderr };
}

/// A temp dir holding `valid.kup` and one script per kind of error; tests run kupcad
/// inside it.
const Sandbox = struct {
    tmp: testing.TmpDir,
    path: [:0]u8,

    fn init() !Sandbox {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "valid.kup", .data = VALID_SCRIPT });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "semantic_error.kup", .data = "f = ->(x) { break x }\ncube(1)\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "syntax_error.kup", .data = "x = )\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "compile_error.kup", .data = "cube = 5\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "class.kup", .data = "class Foo\n  BAR = 7\nend\n" });
        const path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *Sandbox) void {
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

const Expect = struct {
    args: []const []const u8,
    code: u8,
    /// Must appear in stdout or stderr.
    contains: ?[]const u8 = null,
    /// Must appear in neither (e.g. an error trace or a false "Success").
    absent: ?[]const u8 = null,
};

fn expectRuns(cases: []const Expect) !void {
    var sb = try Sandbox.init();
    defer sb.deinit();
    for (cases) |case| {
        const run = try kupcad(sb.path, case.args);
        defer run.deinit();
        errdefer {
            std.debug.print("$ kupcad", .{});
            for (case.args) |arg| std.debug.print(" {s}", .{arg});
            std.debug.print("\nexit {d}\nstdout:\n{s}\nstderr:\n{s}\n", .{ run.code, run.stdout, run.stderr });
        }
        try testing.expectEqual(case.code, run.code);
        if (case.contains) |needle| {
            try testing.expect(std.mem.indexOf(u8, run.stdout, needle) != null or std.mem.indexOf(u8, run.stderr, needle) != null);
        }
        if (case.absent) |needle| {
            try testing.expect(std.mem.indexOf(u8, run.stdout, needle) == null and std.mem.indexOf(u8, run.stderr, needle) == null);
        }
    }
}

test "kupcad: help, version and unknown commands" {
    try expectRuns(&.{
        .{ .args = &.{}, .code = 1, .contains = "Usage: kupcad <command>" },
        .{ .args = &.{"--help"}, .code = 0, .contains = "Commands:" },
        .{ .args = &.{"-h"}, .code = 0, .contains = "  pkg" },
        .{ .args = &.{"help"}, .code = 0, .contains = "  watch" },
        .{ .args = &.{"--version"}, .code = 0, .contains = "kupcad " ++ options.version ++ "\n" },
        .{ .args = &.{"-V"}, .code = 0, .contains = options.version },
        .{ .args = &.{"frobnicate"}, .code = 1, .contains = "Unknown command 'frobnicate'" },
        // Per-command help: `check --help` used to try to read a file named "--help".
        .{ .args = &.{ "check", "--help" }, .code = 0, .contains = "Usage: kupcad check", .absent = "Could not read" },
        .{ .args = &.{ "check", "valid.kup", "-h" }, .code = 0, .contains = "Usage: kupcad check", .absent = "Success" },
        .{ .args = &.{ "build", "--help" }, .code = 0, .contains = "-p, --param <name=value>" },
        .{ .args = &.{ "fmt", "--help" }, .code = 0, .contains = "Usage: kupcad fmt" },
        .{ .args = &.{ "doc", "-h" }, .code = 0, .contains = "Usage: kupcad doc" },
        .{ .args = &.{ "watch", "--help" }, .code = 0, .contains = "Usage: kupcad watch" },
        .{ .args = &.{ "pkg", "--help" }, .code = 0, .contains = "add <alias>=<url>" },
        .{ .args = &.{ "pkg", "add", "--help" }, .code = 0, .contains = "Usage: kupcad pkg" },
        .{ .args = &.{ "lsp", "--help" }, .code = 0, .contains = "Usage: kupcad lsp" },
        .{ .args = &.{ "dev", "-h" }, .code = 0, .contains = "Usage: kupcad dev" },
        .{ .args = &.{"--help"}, .code = 0, .contains = "Run 'kupcad <command> --help'" },
    });
}

test "kupcad: every command exits non-zero when it fails" {
    // fmt, doc, a bare/unknown pkg command and check on a missing file all used to exit 0.
    try expectRuns(&.{
        .{ .args = &.{"fmt"}, .code = 1 },
        .{ .args = &.{ "fmt", "missing.kup" }, .code = 1 },
        .{ .args = &.{"doc"}, .code = 1, .contains = "Missing input file path" },
        .{ .args = &.{ "doc", "missing.kup" }, .code = 1, .contains = "Could not read 'missing.kup'" },
        .{ .args = &.{ "check", "missing.kup" }, .code = 1, .absent = "Success" },
        .{ .args = &.{"pkg"}, .code = 1, .contains = "Usage: kupcad pkg <init|add|install|prune|doctor>" },
        .{ .args = &.{ "pkg", "frobnicate" }, .code = 1, .contains = "Unknown pkg command 'frobnicate'", .absent = "ManifestNotFound" },
        .{ .args = &.{"watch"}, .code = 1, .contains = "Missing input file path" },
        .{ .args = &.{"dev"}, .code = 1 },
        .{ .args = &.{ "dev", "frobnicate" }, .code = 1, .contains = "Unknown dev subcommand" },
        .{ .args = &.{ "build", "valid.kup", "--bogus" }, .code = 1, .contains = "Unknown option '--bogus'" },
        .{ .args = &.{ "build", "valid.kup", "-o" }, .code = 1, .contains = "Missing output path after -o" },
        // An option a command doesn't take is an error with its usage, not a file path.
        .{ .args = &.{ "check", "valid.kup", "--bogus" }, .code = 1, .contains = "Unknown option '--bogus'\n\nUsage: kupcad check", .absent = "Could not read" },
        .{ .args = &.{ "fmt", "--bogus", "valid.kup" }, .code = 1, .contains = "Unknown option '--bogus'" },
        .{ .args = &.{"check"}, .code = 1, .contains = "Missing file path\n\nUsage: kupcad check" },
    });
}

test "kupcad: errors found in a file fail the command and are counted" {
    // check printed a resolver error but summarised "0 errors" and exited 0, and fmt
    // exited 0 on a file it could not format: each command's walk overwrote the count
    // its per-file callback had kept. build printed "Build failed: 0 syntax errors".
    try expectRuns(&.{
        .{ .args = &.{ "check", "semantic_error.kup" }, .code = 1, .contains = "1 file(s) inspected, 1 errors" },
        .{ .args = &.{ "check", "syntax_error.kup" }, .code = 1, .contains = "Invalid expression starting with ')'" },
        .{ .args = &.{ "fmt", "syntax_error.kup" }, .code = 1 },
        .{ .args = &.{ "build", "semantic_error.kup", "-o", "out.stl" }, .code = 1, .contains = "Cannot use 'break' outside of a loop" },
        // A compile error is found by check too, not only when building.
        .{ .args = &.{ "check", "compile_error.kup" }, .code = 1, .contains = "'cube' is a built-in and can't be assigned" },
        .{ .args = &.{ "build", "compile_error.kup", "-o", "out.stl" }, .code = 1, .contains = "compile_error.kup:1:1:" },
    });
}

test "kupcad: commands succeed with exit 0 on valid input" {
    try expectRuns(&.{
        // dev never freed its compiler, so a script with a class reported a leak.
        .{ .args = &.{ "dev", "disasm", "class.kup" }, .code = 0, .absent = "leaked" },
        .{ .args = &.{ "dev", "bench", "class.kup" }, .code = 0, .absent = "leaked" },
        .{ .args = &.{ "fmt", "valid.kup" }, .code = 0, .contains = "cube(10)" },
        .{ .args = &.{ "doc", "valid.kup" }, .code = 0 },
        .{ .args = &.{ "check", "valid.kup" }, .code = 0, .contains = "Success" },
        .{ .args = &.{ "build", "valid.kup", "-o", "out.stl" }, .code = 0, .contains = "Successfully built out.stl" },
    });
}

test "kupcad: piped output has no colour codes unless CLICOLOR_FORCE asks for them" {
    // check and build wrote ANSI escape codes into pipes and log files.
    var sb = try Sandbox.init();
    defer sb.deinit();
    const commands = [_][]const []const u8{
        &.{ "check", "semantic_error.kup" },
        &.{ "check", "valid.kup" },
        &.{ "build", "syntax_error.kup", "-o", "out.stl" },
    };
    for (commands) |args| {
        errdefer std.debug.print("$ kupcad {s}\n", .{args[0]});
        const plain = try kupcad(sb.path, args);
        defer plain.deinit();
        try testing.expect(std.mem.indexOfScalar(u8, plain.stdout, 0x1b) == null);
        try testing.expect(std.mem.indexOfScalar(u8, plain.stderr, 0x1b) == null);
    }

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("CLICOLOR_FORCE", "1");
    const forced = try kupcadIn(sb.path, &.{ "check", "semantic_error.kup" }, &env);
    defer forced.deinit();
    try testing.expect(std.mem.indexOf(u8, forced.stderr, "\x1b[31m1 errors") != null);
}
