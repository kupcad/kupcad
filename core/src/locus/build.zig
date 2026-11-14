//! Locus as a Zig package: the `locus` module (src/root.zig), and `zig build test` over its
//! own tests, standalone. KupCAD's core/build.zig consumes it as a path dependency
//! (`b.dependency("locus", ...)`) and runs the same tests in its `test` step; extracting the
//! package to a repository of its own needs no change here (docs/architecture.md §4).

const std = @import("std");

/// The most a `-Dfuzz-replay` file may hold: replay lines of a few thousand draws each.
const MAX_REPLAY_BYTES = 16 << 20;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("locus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Where the package's sources are, for the tests that read files beside them (the
    // snapshot fixtures): a path relative to the working directory was another file
    // wherever the tests ran. Imported by tests alone, so no built library holds the path.
    const locus_dir = b.root.root_dir.handle.realPathFileAlloc(b.graph.io, if (b.root.sub_path.len > 0) b.root.sub_path else ".", b.allocator) catch @panic("the build root has no real path");
    const test_paths = b.addOptions();
    test_paths.addOption([]const u8, "locus_dir", locus_dir);
    // The fixtures (src/fixtures/*.json, the primitives' bodies as JSON) are rewritten from
    // the current output instead of compared with it; the diff is reviewed like code.
    test_paths.addOption(bool, "update_snapshots", b.option(bool, "update-snapshots", "Rewrite the body JSON fixtures from the current output") orelse false);
    // The fuzz finds a plain run replays (src/fuzz_test.zig): a file of the `replay:` lines
    // a failing chain or arrangement prints, read here so the tests touch no file system
    // (they run under wasmtime too). Empty without the option, and the replay test skips.
    const replay_path = b.option([]const u8, "fuzz-replay", "A file of fuzz finds' `replay:` lines for the replay test to run");
    const replay_text: []const u8 = if (replay_path) |path| std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(MAX_REPLAY_BYTES)) catch |err| std.debug.panic("-Dfuzz-replay={s}: {t}", .{ path, err }) else "";
    test_paths.addOption([]const u8, "fuzz_replay", replay_text);
    // Where a fuzz worker writes each run's draws as it draws them (src/fuzz_test.zig's
    // `DrawLog`): a panic ends the worker before the run's `replay:` line is printed, and
    // `zig build fuzz-run` (core) prints the file instead. Core passes its cache's `f/`;
    // empty, nothing is written. Fuzzing alone writes it, never a plain or wasm test run.
    if (b.option(std.Build.LazyPath, "fuzz-draws", "The directory a fuzz worker writes each run's draws in (core's `zig build fuzz-run` reads them after a crash)")) |dir| {
        test_paths.addOptionPathUntracked("fuzz_draws", dir);
    } else test_paths.addOption([]const u8, "fuzz_draws", "");
    // Where the tests write the boolean results they check as STEP, for OpenCascade to
    // read back (src/boolean/step_corpus.zig; `pnpm check:locus-step`); empty, none are.
    if (b.option(std.Build.LazyPath, "step-corpus", "The directory the tests write their boolean results to as STEP files, with a manifest")) |dir| {
        test_paths.addOptionPathUntracked("step_corpus", dir);
    } else test_paths.addOption([]const u8, "step_corpus", "");
    module.addOptions("test_paths", test_paths);

    const test_filters = b.option([]const []const u8, "test-filter", "Filter tests by name") orelse &.{};
    const tests = b.addTest(.{
        .root_module = module,
        .filters = test_filters,
    });
    // `zig build check` compiles a library that references every public declaration, for a
    // target the tests can't run on (wasm32-freestanding, which has no test runner).
    const check = b.addLibrary(.{
        .linkage = .static,
        .name = "locus_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "locus", .module = module }},
        }),
    });
    const check_step = b.step("check", "Compile every public declaration for the target (wasm32-freestanding has no test runner)");
    check_step.dependOn(&check.step);

    const test_step = b.step("test", "Run Locus's tests (through wasmtime on wasm32)");
    test_step.dependOn(&runTests(b, tests, target).step);

    // `zig build bench`: the timed cases of test/bench/main.zig against their budgets,
    // always ReleaseFast (a Debug timing says nothing about a budget)
    const bench = b.addExecutable(.{
        .name = "locus_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "locus", .module = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = .ReleaseFast }) }},
        }),
    });
    const bench_step = b.step("bench", "Time the benchmark cases (ReleaseFast) and fail on one past its budget");
    bench_step.dependOn(&b.addRunArtifact(bench).step);
}

/// The tests run: natively as they are, on wasm32 through wasmtime (KupCAD's wasm job runs
/// them so too).
pub fn runTests(b: *std.Build, tests: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) *std.Build.Step.Run {
    if (target.result.cpu.arch != .wasm32) return b.addRunArtifact(tests);
    const run = b.addSystemCommand(&.{ "wasmtime", "--" });
    run.addFileArg2(tests.getEmittedBin(), .{});
    return run;
}
