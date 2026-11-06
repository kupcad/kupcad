//! Locus as a Zig package: the `locus` module (src/root.zig), and `zig build test` over its
//! own tests, standalone. KupCAD's core/build.zig consumes it as a path dependency
//! (`b.dependency("locus", ...)`) and runs the same tests in its `test` step; extracting the
//! package to a repository of its own needs no change here (docs/architecture.md §4).

const std = @import("std");

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
    module.addOptions("test_paths", test_paths);

    const test_filters = b.option([]const []const u8, "test-filter", "Filter tests by name") orelse &.{};
    const tests = b.addTest(.{
        .root_module = module,
        .filters = test_filters,
    });
    const test_step = b.step("test", "Run Locus's tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
