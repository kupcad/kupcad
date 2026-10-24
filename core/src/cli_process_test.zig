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

/// Runs `kupcad args...` with `cwd` as its working directory, in the test's own
/// environment without the colour variables: the developer's shell (CLICOLOR_FORCE=1 is
/// common) used to colour the piped output these tests read.
fn kupcad(cwd: []const u8, args: []const []const u8) !Run {
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    for ([_][]const u8{ "CLICOLOR_FORCE", "NO_COLOR", "FORCE_COLOR" }) |name| _ = env.swapRemove(name);
    return kupcadIn(cwd, args, &env);
}

fn kupcadIn(cwd: []const u8, args: []const []const u8, env: ?*const std.process.Environ.Map) !Run {
    // The build hands us a path relative to the build root; the child runs elsewhere.
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, options.kupcad_exe, testing.allocator);
    defer testing.allocator.free(exe);
    var argv: std.ArrayList([]const u8) = .empty;
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
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "unused.kup", .data = "x = 1\ncube(1)\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "fixme.kup", .data = "spare = 1\ncube(1)\n" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "strict.json", .data = "{ \"lint\": { \"unused-variable\": \"error\" } }" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "quiet.json", .data = "{ \"lint\": { \"unused-variable\": \"off\" } }" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "typo.json", .data = "{\n  \"lint\": {\n    \"unused-variabel\": \"off\"\n  }\n}" });
        try tmp.dir.createDirPath(testing.io, "empty");
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
            try testing.expect(std.mem.find(u8, run.stdout, needle) != null or std.mem.find(u8, run.stderr, needle) != null);
        }
        if (case.absent) |needle| {
            try testing.expect(std.mem.find(u8, run.stdout, needle) == null and std.mem.find(u8, run.stderr, needle) == null);
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
        .{ .args = &.{ "lsp", "--tcp" }, .code = 1, .contains = "Unknown option '--tcp'" },
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
        .{ .args = &.{ "pkg", "prune", "--forse" }, .code = 1, .contains = "Unexpected argument '--forse' for kupcad pkg prune" },
        .{ .args = &.{"watch"}, .code = 1, .contains = "Missing input file path" },
        .{ .args = &.{"dev"}, .code = 1 },
        .{ .args = &.{ "dev", "frobnicate" }, .code = 1, .contains = "Unknown dev subcommand" },
        .{ .args = &.{ "build", "valid.kup", "--bogus" }, .code = 1, .contains = "Unknown option '--bogus'" },
        .{ .args = &.{ "build", "valid.kup", "-o" }, .code = 1, .contains = "Missing output path after -o" },
        // An option a command doesn't take is an error with its usage, not a file path.
        .{ .args = &.{ "check", "valid.kup", "--bogus" }, .code = 1, .contains = "Unknown option '--bogus'\n\nUsage: kupcad check", .absent = "Could not read" },
        .{ .args = &.{ "fmt", "--bogus", "valid.kup" }, .code = 1, .contains = "Unknown option '--bogus'" },
        .{ .args = &.{ "fmt", "--check", "--write", "valid.kup" }, .code = 1, .contains = "--check and --write can't be used together" },
        .{ .args = &.{ "fmt", "--check", "syntax_error.kup" }, .code = 1, .contains = "has syntax errors" },
        .{ .args = &.{ "fmt", "--stdin", "valid.kup" }, .code = 1, .contains = "--stdin formats what is piped in: it takes no files and no --write" },
        .{ .args = &.{ "fmt", "--stdin", "--write" }, .code = 1, .contains = "--stdin formats what is piped in" },
        .{ .args = &.{"check"}, .code = 1, .contains = "Missing file path\n\nUsage: kupcad check" },
    });
}

test "kupcad: errors found in a file fail the command and are counted" {
    // check printed a resolver error but summarised "0 errors" and exited 0, and fmt
    // exited 0 on a file it could not format: each command's walk overwrote the count
    // its per-file callback had kept. build printed "Build failed: 0 syntax errors".
    try expectRuns(&.{
        .{ .args = &.{ "check", "semantic_error.kup" }, .code = 1, .contains = "1 file inspected, 1 error, 1 warning, 0 info detected." },
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
        .{ .args = &.{ "fmt", "--check", "valid.kup" }, .code = 0 },
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
        try testing.expect(std.mem.findScalar(u8, plain.stdout, 0x1b) == null);
        try testing.expect(std.mem.findScalar(u8, plain.stderr, 0x1b) == null);
    }

    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("CLICOLOR_FORCE", "1");
    const forced = try kupcadIn(sb.path, &.{ "check", "semantic_error.kup" }, &env);
    defer forced.deinit();
    try testing.expect(std.mem.find(u8, forced.stderr, "\x1b[31m1 error") != null);
}

test "kupcad: check names each finding's rule, at the level .kupcad.json gives it" {
    try expectRuns(&.{
        .{ .args = &.{ "check", "unused.kup" }, .code = 0, .contains = "Unused variable 'x'. Prefix with '_' if intentional. [unused-variable]" },
        .{ .args = &.{ "check", "--config", "strict.json", "unused.kup" }, .code = 1, .contains = "unused.kup:1:1: E: Unused variable 'x'" },
        .{ .args = &.{ "check", "--config", "quiet.json", "unused.kup" }, .code = 0, .contains = "Success" },
        // A mistyped rule used to be ignored, leaving it on.
        .{ .args = &.{ "check", "--config", "typo.json", "unused.kup" }, .code = 1, .contains = "Error: typo.json:3:" },
        .{ .args = &.{ "check", "--help" }, .code = 0, .contains = "  unused-variable    A variable assigned and never read" },
    });
}

test "kupcad: check --fix doesn't print what the script prints" {
    // Telling whether a fix changes the model runs the script, and its `puts` reached the
    // terminal (and, in the test suite, corrupted the test runner's protocol).
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.tmp.dir.writeFile(testing.io, .{ .sub_path = "chatty.kup", .data = "spare = 1\nputs(\"from the script\")\ninspect(cube(1))\ncube(1)\n" });
    const run = try kupcad(sb.path, &.{ "check", "--fix", "chatty.kup" });
    defer run.deinit();
    errdefer std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ run.stdout, run.stderr });
    try testing.expectEqual(@as(u8, 0), run.code);
    try testing.expect(std.mem.find(u8, run.stderr, "Fixed 1 problem") != null);
    try testing.expect(std.mem.find(u8, run.stdout, "from the script") == null and std.mem.find(u8, run.stderr, "from the script") == null);
    try testing.expect(std.mem.find(u8, run.stdout, "Geometry") == null);
    const fixed = try sb.tmp.dir.readFileAlloc(testing.io, "chatty.kup", testing.allocator, .limited(1024));
    defer testing.allocator.free(fixed);
    try testing.expect(std.mem.startsWith(u8, fixed, "_spare = 1\n"));
}

test "kupcad: dev bench prints its report, not what the script prints" {
    // Each timed run (and the profiled one) printed the script's puts, inspect and
    // benchmark output into the report, once per run.
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.tmp.dir.writeFile(testing.io, .{ .sub_path = "chatty.kup", .data = "puts(\"from the script\")\ninspect(cube(1))\nbenchmark(\"inner\") { cube(2) }\ncube(1)\n" });
    inline for (.{ &[_][]const u8{ "dev", "bench", "chatty.kup", "--repeat", "2" }, &[_][]const u8{ "dev", "bench", "chatty.kup", "--json", "--no-profile" } }) |args| {
        const run = try kupcad(sb.path, args);
        defer run.deinit();
        errdefer std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ run.stdout, run.stderr });
        try testing.expectEqual(@as(u8, 0), run.code);
        for ([_][]const u8{ "from the script", "Geometry", "inner" }) |noise| {
            try testing.expect(std.mem.find(u8, run.stdout, noise) == null and std.mem.find(u8, run.stderr, noise) == null);
        }
    }
    // The JSON report is the whole of stdout, so it parses.
    const json_run = try kupcad(sb.path, &.{ "dev", "bench", "chatty.kup", "--json", "--no-profile" });
    defer json_run.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_run.stdout, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("evaluated").?.bool);
}

test "kupcad: check run in a subfolder uses the project's .kupcad.json above it" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.tmp.dir.createDirPath(testing.io, "parts");
    try sb.tmp.dir.writeFile(testing.io, .{ .sub_path = "parts/unused.kup", .data = "x = 1\ncube(1)\n" });
    try sb.tmp.dir.writeFile(testing.io, .{ .sub_path = ".kupcad.json", .data = "{ \"lint\": { \"unused-variable\": \"error\" } }" });
    const parts = try std.fs.path.join(testing.allocator, &.{ sb.path, "parts" });
    defer testing.allocator.free(parts);

    // It used to read .kupcad.json from the current directory only.
    const run = try kupcad(parts, &.{ "check", "unused.kup" });
    defer run.deinit();
    try testing.expectEqual(@as(u8, 1), run.code);
    const report = try std.mem.concat(testing.allocator, u8, &.{ run.stdout, run.stderr });
    defer testing.allocator.free(report);
    try testing.expect(std.mem.find(u8, report, "unused.kup:1:1: E: Unused variable 'x'") != null);
}

test "kupcad: pkg add that fails to install leaves kupcad.json as it was" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const home = try std.fs.path.join(testing.allocator, &.{ sb.path, "kupcad-home" });
    defer testing.allocator.free(home);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("KUPCAD_HOME", home);

    const created = try kupcadIn(sb.path, &.{ "pkg", "init" }, &env);
    defer created.deinit();
    try testing.expectEqual(@as(u8, 0), created.code);
    const before = try sb.tmp.dir.readFileAlloc(testing.io, "kupcad.json", testing.allocator, .limited(4096));
    defer testing.allocator.free(before);

    // It used to save the dependency first, so every later install failed on it too.
    const added = try kupcadIn(sb.path, &.{ "pkg", "add", "missing=file:/nonexistent-kupcad-test/pkg.tar.gz" }, &env);
    defer added.deinit();
    try testing.expectEqual(@as(u8, 1), added.code);
    const after = try sb.tmp.dir.readFileAlloc(testing.io, "kupcad.json", testing.allocator, .limited(4096));
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);

    // A self-hosted server must say which API it speaks; it used to be taken for Gitea.
    const unknown = try kupcadIn(sb.path, &.{ "pkg", "add", "parts=git.example.com/team/parts" }, &env);
    defer unknown.deinit();
    try testing.expectEqual(@as(u8, 1), unknown.code);
    try testing.expect(std.mem.find(u8, unknown.stderr, "write gitlab:<host>/<user>/<repo> or gitea:") != null);
}

test "kupcad: pkg install needs kupcad.json; install, prune and doctor run on a fresh store" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const home = try std.fs.path.join(testing.allocator, &.{ sb.path, "kupcad-home" });
    defer testing.allocator.free(home);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("KUPCAD_HOME", home);

    const without = try kupcadIn(sb.path, &.{ "pkg", "install" }, &env);
    defer without.deinit();
    try testing.expectEqual(@as(u8, 1), without.code);
    try testing.expect(std.mem.find(u8, without.stderr, "could not read kupcad.json") != null);
    try testing.expect(std.mem.find(u8, without.stderr, "run `kupcad pkg init` to create one") != null);

    const created = try kupcadIn(sb.path, &.{ "pkg", "init" }, &env);
    defer created.deinit();
    try testing.expectEqual(@as(u8, 0), created.code);
    const steps = [_]struct { args: []const []const u8, says: []const u8 }{
        .{ .args = &.{ "pkg", "install" }, .says = "Workspace linked successfully." },
        .{ .args = &.{ "pkg", "prune" }, .says = "Pruned 0 files" },
        .{ .args = &.{ "pkg", "prune", "--force" }, .says = "Pruned 0 files" },
        .{ .args = &.{ "pkg", "doctor" }, .says = "System health check complete." },
    };
    for (steps) |step| {
        errdefer std.debug.print("kupcad {any}\n", .{step.args});
        const run = try kupcadIn(sb.path, step.args, &env);
        defer run.deinit();
        try testing.expectEqual(@as(u8, 0), run.code);
        const said = try std.mem.concat(testing.allocator, u8, &.{ run.stdout, run.stderr });
        defer testing.allocator.free(said);
        try testing.expect(std.mem.find(u8, said, step.says) != null);
    }
}

test "kupcad: dev ast-dump, disasm and lex-dump write their file beside the script" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.tmp.dir.writeFile(testing.io, .{ .sub_path = "heredoc.kup", .data = "x = <<~EOS\n  hi\nEOS\ncube(1)\n" });
    const dumps = [_]struct { name: []const u8, script: []const u8, file: []const u8, starts: []const u8 }{
        .{ .name = "ast-dump", .script = "valid.kup", .file = "valid.kup.dump", .starts = "└── block" },
        .{ .name = "disasm", .script = "valid.kup", .file = "valid.kup.disasm", .starts = "== main ==" },
        .{ .name = "lex-dump", .script = "valid.kup", .file = "valid.kup.lex", .starts = "== Lexer Token Dump ==" },
        // A heredoc's tokens: their bodies were leaked
        .{ .name = "lex-dump", .script = "heredoc.kup", .file = "heredoc.kup.lex", .starts = "== Lexer Token Dump ==" },
    };
    for (dumps) |dump| {
        errdefer std.debug.print("kupcad dev {s} {s}\n", .{ dump.name, dump.script });
        const run = try kupcad(sb.path, &.{ "dev", dump.name, dump.script });
        defer run.deinit();
        try testing.expectEqual(@as(u8, 0), run.code);
        try testing.expect(std.mem.find(u8, run.stderr, "leaked") == null);
        const written = try sb.tmp.dir.readFileAlloc(testing.io, dump.file, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(written);
        try testing.expect(std.mem.startsWith(u8, written, dump.starts));
    }
    const missing = try kupcad(sb.path, &.{ "dev", "disasm" });
    defer missing.deinit();
    try testing.expectEqual(@as(u8, 1), missing.code);
    try testing.expect(std.mem.find(u8, missing.stderr, "Missing file path for 'disasm'. Usage: kupcad dev disasm <file.kup>") != null);
}

test "kupcad: build of a script in a subfolder imports its neighbours" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.tmp.dir.createDirPath(testing.io, "parts");
    try sb.tmp.dir.writeFile(testing.io, .{ .sub_path = "parts/hw.kup", .data = "def bolt(l)\n  cylinder(r: 1, h: l)\nend\nexport bolt\n" });
    try sb.tmp.dir.writeFile(testing.io, .{ .sub_path = "parts/main.kup", .data = "import { bolt } from \"./hw.kup\"\nbolt(5)\n" });
    // "./hw.kup" used to be read from the current directory.
    const run = try kupcad(sb.path, &.{ "build", "parts/main.kup", "-o", "out.stl" });
    defer run.deinit();
    errdefer std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ run.stdout, run.stderr });
    try testing.expectEqual(@as(u8, 0), run.code);
}

test "kupcad: check --fix rewrites what it can fix and reports the rest" {
    try expectRuns(&.{
        .{ .args = &.{ "check", "--fix", "fixme.kup" }, .code = 0, .contains = "Fixed 1 problem in fixme.kup" },
        // The file now says the variable is unused on purpose.
        .{ .args = &.{ "check", "fixme.kup" }, .code = 0, .contains = "Success" },
        .{ .args = &.{ "check", "--fix", "fixme.kup" }, .code = 0, .absent = "Fixed" },
        .{ .args = &.{ "check", "--help" }, .code = 0, .contains = "--fix" },
    });
}

test "kupcad: check --format json and sarif write one document to stdout" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    inline for (.{ "json", "sarif" }) |format| {
        const run = try kupcad(sb.path, &.{ "check", "--format", format, "unused.kup" });
        defer run.deinit();
        try testing.expectEqual(@as(u8, 0), run.code);
        // stdout is the document alone: it parses, and names the finding's rule.
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, run.stdout, .{});
        defer parsed.deinit();
        try testing.expect(std.mem.find(u8, run.stdout, "\"unused-variable\"") != null);
    }
}

test "kupcad: check --max-warnings fails a run with more warnings than that" {
    try expectRuns(&.{
        .{ .args = &.{ "check", "--max-warnings", "0", "unused.kup" }, .code = 1, .contains = "Failed: 1 warning, more than --max-warnings 0." },
        .{ .args = &.{ "check", "--max-warnings", "many", "unused.kup" }, .code = 1, .contains = "Error: --max-warnings takes a whole number, not 'many'" },
        .{ .args = &.{ "check", "--format", "yaml", "unused.kup" }, .code = 1, .contains = "Error: --format is text, json or sarif, not 'yaml'" },
        // A folder with no script has nothing wrong in it
        .{ .args = &.{ "check", "empty" }, .code = 0, .contains = "across 0 files" },
        .{ .args = &.{ "check", "--max-warnings", "1", "unused.kup" }, .code = 0 },
        .{ .args = &.{ "check", "--format", "json", "--max-warnings", "0", "unused.kup" }, .code = 1, .contains = "1 warning, more than --max-warnings 0" },
        .{ .args = &.{ "check", "--format", "xml", "unused.kup" }, .code = 1, .contains = "--format is text, json or sarif, not 'xml'" },
        .{ .args = &.{ "check", "--max-warnings", "many", "unused.kup" }, .code = 1, .contains = "--max-warnings takes a whole number" },
        .{ .args = &.{ "check", "unused.kup", "--format" }, .code = 1, .contains = "Missing value after '--format'" },
    });
}

/// The crash reports `dir` holds, read and concatenated (caller frees), and how many.
fn crashReports(dir: std.Io.Dir) !struct { text: []u8, count: usize } {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "kupcad-crash-")) continue;
        count += 1;
        const text = try dir.readFileAlloc(testing.io, entry.name, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(text);
        try out.writer.writeAll(text);
    }
    return .{ .text = try out.toOwnedSlice(), .count = count };
}

test "kupcad: KUPCAD_CRASH_DIR captures a panic and an abort, and nothing is written without it" {
    if (!@import("builtin").os.tag.isDarwin() and @import("builtin").os.tag != .linux) return error.SkipZigTest;
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.tmp.dir.createDirPath(testing.io, "crashes");
    const crash_dir = try std.fs.path.join(testing.allocator, &.{ sb.path, "crashes" });
    defer testing.allocator.free(crash_dir);

    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    for ([_][]const u8{ "CLICOLOR_FORCE", "NO_COLOR", "FORCE_COLOR", "KUPCAD_CRASH_DIR" }) |name| _ = env.swapRemove(name);

    // Off by default: a crash leaves nothing behind.
    const unreported = try kupcadIn(sb.path, &.{ "dev", "crash", "abort" }, &env);
    defer unreported.deinit();
    var dir = try sb.tmp.dir.openDir(testing.io, "crashes", .{ .iterate = true });
    defer dir.close(testing.io);
    const none = try crashReports(dir);
    defer testing.allocator.free(none.text);
    try testing.expectEqual(@as(usize, 0), none.count);

    try env.put("KUPCAD_CRASH_DIR", crash_dir);
    for ([_][]const u8{ "panic", "abort" }) |how| {
        const run = try kupcadIn(sb.path, &.{ "dev", "crash", how }, &env);
        defer run.deinit();
        try testing.expect(run.code != 0);
        try testing.expect(std.mem.find(u8, run.stderr, "kupcad: writing a crash report to ") != null);
    }
    const reports = try crashReports(dir);
    defer testing.allocator.free(reports.text);
    try testing.expectEqual(@as(usize, 2), reports.count);
    try testing.expect(std.mem.find(u8, reports.text, "\ncommand: dev\n") != null);
    try testing.expect(std.mem.find(u8, reports.text, "panic: kupcad dev crash: a deliberate panic\nstack:\n") != null);
    try testing.expect(std.mem.find(u8, reports.text, "signal: SIGABRT\n") != null);
}

/// A `kupcad` process the test talks to on its stdin and stdout, its stderr discarded.
const Conversation = struct {
    child: std.process.Child,
    in_buf: [64 * 1024]u8 = undefined,
    out_buf: [4096]u8 = undefined,
    reader: std.Io.File.Reader = undefined,
    writer: std.Io.File.Writer = undefined,

    /// In place: the reader and writer point into it.
    fn start(self: *Conversation, cwd: []const u8, args: []const []const u8) !void {
        const exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, options.kupcad_exe, testing.allocator);
        defer testing.allocator.free(exe);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.append(testing.allocator, exe);
        try argv.appendSlice(testing.allocator, args);
        self.* = .{ .child = try std.process.spawn(testing.io, .{ .argv = argv.items, .cwd = .{ .path = cwd }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore }) };
        self.reader = self.child.stdout.?.readerStreaming(testing.io, &self.in_buf);
        self.writer = self.child.stdin.?.writerStreaming(testing.io, &self.out_buf);
    }

    /// Closes its stdin and waits for it to end.
    fn finish(self: *Conversation) !std.process.Child.Term {
        self.child.stdin.?.close(testing.io);
        self.child.stdin = null;
        return self.child.wait(testing.io);
    }

    // The preview worker's frames (cli/lsp_worker.zig): kind, u32 length, payload.

    fn sendFrame(self: *Conversation, kind: u8, parts: []const []const u8) !void {
        var len: u32 = 0;
        for (parts) |p| len += @intCast(p.len);
        var header: [5]u8 = undefined;
        header[0] = kind;
        std.mem.writeInt(u32, header[1..5], len, .little);
        try self.writer.interface.writeAll(&header);
        for (parts) |p| try self.writer.interface.writeAll(p);
        try self.writer.interface.flush();
    }

    /// The next frame's payload (caller frees).
    fn receiveFrame(self: *Conversation) ![]u8 {
        var header: [5]u8 = undefined;
        try self.reader.interface.readSliceAll(&header);
        const payload = try testing.allocator.alloc(u8, std.mem.readInt(u32, header[1..5], .little));
        errdefer testing.allocator.free(payload);
        try self.reader.interface.readSliceAll(payload);
        return payload;
    }

    // The language server's messages: a Content-Length header, then JSON.

    fn sendJson(self: *Conversation, json: []const u8) !void {
        try self.writer.interface.print("Content-Length: {d}\r\n\r\n{s}", .{ json.len, json });
        try self.writer.interface.flush();
    }

    /// The next message from the server (caller frees).
    fn receiveJson(self: *Conversation) ![]u8 {
        var len: usize = 0;
        while (true) {
            const line = try self.reader.interface.takeDelimiterInclusive('\n');
            const trimmed = std.mem.trimEnd(u8, line, "\r\n");
            if (trimmed.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) len = try std.fmt.parseInt(usize, std.mem.trim(u8, trimmed["content-length:".len..], " "), 10);
        }
        const body = try testing.allocator.alloc(u8, len);
        errdefer testing.allocator.free(body);
        try self.reader.interface.readSliceAll(body);
        return body;
    }

    /// Kills the processes it started (the language server's preview worker), as a crash
    /// would end them.
    fn killChildren(self: *Conversation) !void {
        var pid_buf: [16]u8 = undefined;
        const pkill = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "pkill", "-KILL", "-P", try std.mem.print(&pid_buf, "{d}", .{self.child.id.?}) } });
        testing.allocator.free(pkill.stdout);
        testing.allocator.free(pkill.stderr);
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, pkill.term);
    }

    /// The server's answer to request `id`; the notifications before it go to `seen`.
    fn answer(self: *Conversation, id: u32, seen: *std.ArrayList(u8)) ![]u8 {
        var needle_buf: [32]u8 = undefined;
        const needle = try std.mem.print(&needle_buf, "\"id\":{d},", .{id});
        while (true) {
            const msg = try self.receiveJson();
            if (std.mem.find(u8, msg, needle) != null) return msg;
            defer testing.allocator.free(msg);
            try seen.appendSlice(testing.allocator, msg);
        }
    }
};

test "kupcad: fmt --stdin formats what is piped in, and --check fails when it isn't formatted" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const cases = [_]struct { args: []const []const u8, code: u8, out: []const u8 }{
        .{ .args = &.{ "fmt", "--stdin" }, .code = 0, .out = "x = 1 + 2\n" },
        .{ .args = &.{ "fmt", "--stdin", "--check" }, .code = 1, .out = "<stdin>\n" },
    };
    for (cases) |case| {
        var talk: Conversation = undefined;
        try talk.start(sb.path, case.args);
        try talk.writer.interface.writeAll("x=1+  2");
        try talk.writer.interface.flush();
        // Its output to the end before it is waited for, which closes the pipes
        talk.child.stdin.?.close(testing.io);
        talk.child.stdin = null;
        const out = try talk.reader.interface.allocRemaining(testing.allocator, .limited(1 << 16));
        defer testing.allocator.free(out);
        const term = try talk.child.wait(testing.io);
        try testing.expectEqual(std.process.Child.Term{ .exited = case.code }, term);
        try testing.expectEqualStrings(case.out, out);
    }
}

fn u32Le(n: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, n, .little);
    return b;
}

test "kupcad: lsp --preview-worker evaluates, answers hovers, stops on a cancel and ends with its input" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    var worker: Conversation = undefined;
    try worker.start(sb.path, &.{ "lsp", "--preview-worker" });
    errdefer worker.child.kill(testing.io);
    const UPDATE = 1;
    const EVALUATE = 3;
    const CANCEL = 5;
    const FRAME = 0;
    const CANCELLED = 2;

    const path = "part.kup";
    try worker.sendFrame(UPDATE, &.{ &u32Le(path.len), path, "a = cube(2)\n" });
    const updated = try worker.receiveFrame();
    defer testing.allocator.free(updated);
    try testing.expectEqualSlices(u8, &.{0}, updated);
    try worker.sendFrame(EVALUATE, &.{ &.{1}, &u32Le(path.len), path, "file:///work/" ++ path });
    const evaluated = try worker.receiveFrame();
    defer testing.allocator.free(evaluated);
    // The preview frame: its header's length, the header, the model as GLB
    try testing.expectEqual(@as(u8, FRAME), evaluated[0]);
    const header_len = std.mem.readInt(u32, evaluated[1..5], .little);
    try testing.expect(std.mem.find(u8, evaluated[5..][0..header_len], "\"kind\":\"3d\"") != null);
    try testing.expectEqualStrings("glTF", evaluated[5 + header_len ..][0..4]);

    // A run that never ends stops when the server says so, not at the instruction limit.
    try worker.sendFrame(UPDATE, &.{ &u32Le(path.len), path, "while true\nend\n" });
    testing.allocator.free(try worker.receiveFrame());
    try worker.sendFrame(EVALUATE, &.{ &.{1}, &u32Le(path.len), path, "file:///work/" ++ path });
    // Read in order, so it stops this run whenever it lands, even before the run starts.
    try testing.io.sleep(.fromMilliseconds(10), .awake);
    try worker.sendFrame(CANCEL, &.{});
    const stopped = try worker.receiveFrame();
    defer testing.allocator.free(stopped);
    try testing.expectEqualSlices(u8, &.{CANCELLED}, stopped);

    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try worker.finish());
}

test "kupcad: lsp gives a document values with kupcad.setParams, a new worker is given them, and a closed document forgets them" {
    const builtin = @import("builtin");
    if (builtin.target.os.tag != .linux and !builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    var sb = try Sandbox.init();
    defer sb.deinit();
    var server: Conversation = undefined;
    // As VS Code's language client starts it: it ended at once, refusing --stdio
    try server.start(sb.path, &.{ "lsp", "--stdio" });
    errdefer server.child.kill(testing.io);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);

    var root_buf: [1024]u8 = undefined;
    const root = try std.mem.print(&root_buf, "file://{s}", .{sb.path});
    var msg_buf: [2048]u8 = undefined;
    try server.sendJson(try std.mem.print(&msg_buf, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"capabilities\":{{}},\"rootUri\":\"{s}\"}}}}", .{root}));
    const capabilities = try server.answer(1, &seen);
    defer testing.allocator.free(capabilities);
    try testing.expect(std.mem.find(u8, capabilities, "\"executeCommandProvider\":{\"commands\":[\"kupcad.setParams\",\"kupcad.preview\"]}") != null);
    try server.sendJson("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
    const text = "a = cube(param(:w, default: 2))\\n";
    try server.sendJson(try std.mem.print(&msg_buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}/part.kup\",\"languageId\":\"kupcad\",\"version\":1,\"text\":\"{s}\"}}}}}}", .{ root, text }));
    try server.sendJson(try std.mem.print(&msg_buf, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"workspace/executeCommand\",\"params\":{{\"command\":\"kupcad.setParams\",\"arguments\":[{{\"uri\":\"{s}/part.kup\",\"values\":{{\"w\":3}}}}]}}}}", .{root}));
    const set = try server.answer(2, &seen);
    defer testing.allocator.free(set);
    try testing.expect(std.mem.find(u8, set, "\"error\"") == null);
    const hover_fmt = "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/hover\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}/part.kup\"}},\"position\":{{\"line\":0,\"character\":0}}}}}}";
    try server.sendJson(try std.mem.print(&msg_buf, hover_fmt, .{ 3, root }));
    const first = try server.answer(3, &seen);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.find(u8, first, "**Volume:** `27.00`") != null);

    // The worker is the server's one child: kill it; the edit that finds it gone starts another
    try server.killChildren();
    try server.sendJson(try std.mem.print(&msg_buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}/part.kup\",\"version\":2}},\"contentChanges\":[{{\"text\":\"{s}\"}}]}}}}", .{ root, text }));
    try server.sendJson(try std.mem.print(&msg_buf, hover_fmt, .{ 4, root }));
    const second = try server.answer(4, &seen);
    defer testing.allocator.free(second);
    try testing.expect(std.mem.find(u8, second, "**Volume:** `27.00`") != null);

    // Arguments of another shape are refused
    try server.sendJson("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"workspace/executeCommand\",\"params\":{\"command\":\"kupcad.setParams\",\"arguments\":[]}}");
    const refused = try server.answer(5, &seen);
    defer testing.allocator.free(refused);
    try testing.expect(std.mem.find(u8, refused, "\"code\":-32602") != null);

    // Closed and opened again, it runs with its defaults, in this worker and the next
    try server.sendJson(try std.mem.print(&msg_buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}/part.kup\"}}}}}}", .{root}));
    try server.sendJson(try std.mem.print(&msg_buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}/part.kup\",\"languageId\":\"kupcad\",\"version\":3,\"text\":\"{s}\"}}}}}}", .{ root, text }));
    try server.killChildren();
    try server.sendJson(try std.mem.print(&msg_buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}/part.kup\",\"version\":4}},\"contentChanges\":[{{\"text\":\"{s}\"}}]}}}}", .{ root, text }));
    try server.sendJson(try std.mem.print(&msg_buf, hover_fmt, .{ 6, root }));
    const reopened = try server.answer(6, &seen);
    defer testing.allocator.free(reopened);
    try testing.expect(std.mem.find(u8, reopened, "**Volume:** `8.00`") != null);

    try server.sendJson("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"shutdown\"}");
    testing.allocator.free(try server.answer(7, &seen));
    try server.sendJson("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try server.finish());
}

test "kupcad: lsp runs scripts in a worker, and a worker that dies is replaced" {
    const builtin = @import("builtin");
    if (builtin.target.os.tag != .linux and !builtin.target.os.tag.isDarwin()) return error.SkipZigTest;
    var sb = try Sandbox.init();
    defer sb.deinit();
    var server: Conversation = undefined;
    try server.start(sb.path, &.{"lsp"});
    errdefer server.child.kill(testing.io);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);

    var root_buf: [1024]u8 = undefined;
    const root = try std.mem.print(&root_buf, "file://{s}", .{sb.path});
    var msg_buf: [2048]u8 = undefined;
    try server.sendJson(try std.mem.print(&msg_buf, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"capabilities\":{{}},\"rootUri\":\"{s}\"}}}}", .{root}));
    testing.allocator.free(try server.answer(1, &seen));
    try server.sendJson("{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
    try server.sendJson(try std.mem.print(&msg_buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}/part.kup\",\"languageId\":\"kupcad\",\"version\":1,\"text\":\"a = cube(2)\\n\"}}}}}}", .{root}));
    const hover_fmt = "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"textDocument/hover\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}/part.kup\"}},\"position\":{{\"line\":0,\"character\":0}}}}}}";
    try server.sendJson(try std.mem.print(&msg_buf, hover_fmt, .{ 2, root }));
    const first = try server.answer(2, &seen);
    defer testing.allocator.free(first);
    try testing.expect(std.mem.find(u8, first, "**Volume:** `8.00`") != null);

    // The worker is the server's one child: kill it, as a crash would end it.
    try server.killChildren();

    try server.sendJson(try std.mem.print(&msg_buf, "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didChange\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}/part.kup\",\"version\":2}},\"contentChanges\":[{{\"text\":\"a = cube(3)\\n\"}}]}}}}", .{root}));
    try server.sendJson(try std.mem.print(&msg_buf, hover_fmt, .{ 3, root }));
    const second = try server.answer(3, &seen);
    defer testing.allocator.free(second);
    try testing.expect(std.mem.find(u8, second, "**Volume:** `27.00`") != null);

    try server.sendJson("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"shutdown\"}");
    testing.allocator.free(try server.answer(4, &seen));
    try server.sendJson("{\"jsonrpc\":\"2.0\",\"method\":\"exit\"}");
    try testing.expect(std.mem.find(u8, seen.items, "the worker process running scripts for the preview and hovers crashed") != null);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try server.finish());
}
