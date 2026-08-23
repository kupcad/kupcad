const std = @import("std");

const clipper_sources = &[_][]const u8{
    "vendor/Clipper2/CPP/Clipper2Lib/src/clipper.engine.cpp",
    "vendor/Clipper2/CPP/Clipper2Lib/src/clipper.offset.cpp",
    "vendor/Clipper2/CPP/Clipper2Lib/src/clipper.rectclip.cpp",
};

const manifold_sources = &[_][]const u8{
    "vendor/manifold/bindings/c/box.cpp",
    "vendor/manifold/bindings/c/conv.cpp",
    "vendor/manifold/bindings/c/cross.cpp",
    "vendor/manifold/bindings/c/manifoldc.cpp",
    "vendor/manifold/bindings/c/rect.cpp",
    "vendor/manifold/src/boolean_result.cpp",
    "vendor/manifold/src/boolean2.cpp",
    "vendor/manifold/src/boolean2_diagnostics.cpp",
    "vendor/manifold/src/boolean2_offset.cpp",
    "vendor/manifold/src/boolean2_predicates.cpp",
    "vendor/manifold/src/boolean2_sweep.cpp",
    "vendor/manifold/src/boolean3.cpp",
    "vendor/manifold/src/constructors.cpp",
    "vendor/manifold/src/cross_section.cpp",
    "vendor/manifold/src/csg_tree.cpp",
    "vendor/manifold/src/edge_op.cpp",
    "vendor/manifold/src/execution_impl.cpp",
    "vendor/manifold/src/face_op.cpp",
    "vendor/manifold/src/impl.cpp",
    "vendor/manifold/src/manifold.cpp",
    "vendor/manifold/src/minkowski.cpp",
    "vendor/manifold/src/polygon.cpp",
    "vendor/manifold/src/properties.cpp",
    "vendor/manifold/src/quickhull.cpp",
    "vendor/manifold/src/sdf.cpp",
    "vendor/manifold/src/smoothing.cpp",
    "vendor/manifold/src/sort.cpp",
    "vendor/manifold/src/subdivision.cpp",
    "vendor/manifold/src/tree2d.cpp",
};

const tbb_sources = &[_][]const u8{
    "vendor/oneTBB/src/tbb/address_waiter.cpp",
    "vendor/oneTBB/src/tbb/allocator.cpp",
    "vendor/oneTBB/src/tbb/arena.cpp",
    "vendor/oneTBB/src/tbb/arena_slot.cpp",
    "vendor/oneTBB/src/tbb/concurrent_bounded_queue.cpp",
    "vendor/oneTBB/src/tbb/dynamic_link.cpp",
    "vendor/oneTBB/src/tbb/exception.cpp",
    "vendor/oneTBB/src/tbb/global_control.cpp",
    "vendor/oneTBB/src/tbb/governor.cpp",
    "vendor/oneTBB/src/tbb/itt_notify.cpp",
    "vendor/oneTBB/src/tbb/main.cpp",
    "vendor/oneTBB/src/tbb/market.cpp",
    "vendor/oneTBB/src/tbb/misc.cpp",
    "vendor/oneTBB/src/tbb/misc_ex.cpp",
    "vendor/oneTBB/src/tbb/observer_proxy.cpp",
    "vendor/oneTBB/src/tbb/parallel_pipeline.cpp",
    "vendor/oneTBB/src/tbb/private_server.cpp",
    "vendor/oneTBB/src/tbb/profiling.cpp",
    "vendor/oneTBB/src/tbb/queuing_rw_mutex.cpp",
    "vendor/oneTBB/src/tbb/rml_tbb.cpp",
    "vendor/oneTBB/src/tbb/rtm_mutex.cpp",
    "vendor/oneTBB/src/tbb/rtm_rw_mutex.cpp",
    "vendor/oneTBB/src/tbb/semaphore.cpp",
    "vendor/oneTBB/src/tbb/small_object_pool.cpp",
    "vendor/oneTBB/src/tbb/task.cpp",
    "vendor/oneTBB/src/tbb/task_dispatcher.cpp",
    "vendor/oneTBB/src/tbb/task_group_context.cpp",
    "vendor/oneTBB/src/tbb/tcm_adaptor.cpp",
    "vendor/oneTBB/src/tbb/thread_dispatcher.cpp",
    "vendor/oneTBB/src/tbb/thread_request_serializer.cpp",
    "vendor/oneTBB/src/tbb/threading_control.cpp",
    "vendor/oneTBB/src/tbb/version.cpp",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Add tatfi dependency ---
    const tatfi_dep = b.dependency("tatfi", .{});
    const tatfi_mod = tatfi_dep.module("tatfi");

    // Detect if target is WASM
    const is_wasm = target.result.cpu.arch == .wasm32;
    const is_macos = target.result.os.tag == .macos;

    // Use WASI for WASM builds so Zig provides wasi-libc
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    const active_target = if (is_wasm) wasm_target else target;

    const enable_parallel = b.option(
        bool,
        "manifold_parallel",
        "Enable multi-threaded parallel backend via Intel TBB",
    ) orelse !is_wasm;

    // ====================================================================
    // C/C++ Flags & Headers
    // ====================================================================
    const wasm_stub_header = b.path("src/wasm_stubs.h").getPath(b);
    const manifold_flags: []const []const u8 = if (is_wasm)
        &.{
            "-std=c++17",
            "-fno-exceptions",
            "-fno-rtti", // Removes RTTI overhead
            "-fno-sanitize=undefined", // Prevents UBSan helper generation
            "-DNDEBUG", // Disables debug/assert machinery
            "-DMANIFOLD_NO_IOSTREAM",
            "-DMANIFOLD_NO_FILESYSTEM",
            "-DMANIFOLD_PAR=-1",
            "-include",
            wasm_stub_header,
        }
    else if (enable_parallel)
        &.{ "-std=c++17", "-fno-exceptions", "-DMANIFOLD_PAR=1" }
    else
        &.{ "-std=c++17", "-fno-exceptions", "-DMANIFOLD_PAR=-1" };

    // ====================================================================
    // KupCAD Core Module
    // ====================================================================
    const mod = b.addModule("kupcad", .{
        .root_source_file = b.path("src/root.zig"),
        .target = active_target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "tatfi", .module = tatfi_mod },
        },
    });

    mod.addIncludePath(b.path("vendor/Clipper2/CPP/Clipper2Lib/include"));
    mod.addIncludePath(b.path("vendor/manifold/include"));
    mod.addIncludePath(b.path("vendor/manifold/bindings/c"));
    mod.addIncludePath(b.path("vendor/manifold/bindings/c/include"));
    mod.addIncludePath(b.path("src"));

    mod.addCSourceFiles(.{
        .files = clipper_sources,
        .flags = &.{ "-std=c++17", "-fno-exceptions" },
    });

    mod.addCSourceFiles(.{
        .files = manifold_sources,
        .flags = manifold_flags,
    });

    if (enable_parallel and !is_wasm) {
        mod.addIncludePath(b.path("vendor/oneTBB/include"));
        const tbb_flags: []const []const u8 = if (is_macos)
            &.{ "-std=c++17", "-fexceptions", "-DTBB_USE_DEBUG=0", "-D__TBB_BUILD=1", "-D_XOPEN_SOURCE" }
        else
            &.{ "-std=c++17", "-fexceptions", "-DTBB_USE_DEBUG=0", "-D__TBB_BUILD=1" };

        mod.addCSourceFiles(.{
            .files = tbb_sources,
            .flags = tbb_flags,
        });
    }

    // ====================================================================
    // Targets
    // ====================================================================
    if (is_wasm) {
        const wasm = b.addExecutable(.{
            .name = "kupcad",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/wasm.zig"),
                .target = wasm_target,
                .optimize = optimize,
                .link_libc = true,
                .link_libcpp = true,
                .imports = &.{
                    .{ .name = "kupcad", .module = mod },
                    .{ .name = "tatfi", .module = tatfi_mod },
                },
            }),
        });

        wasm.entry = .disabled;
        wasm.wasi_exec_model = .reactor;
        wasm.rdynamic = true;

        // all mem must be aligned in 65536 bytes (64Kb)
        wasm.initial_memory = 134217728;
        wasm.max_memory = 4294967296;
        wasm.stack_size = 67108864;

        b.installArtifact(wasm);

        // tests
        const wasm_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/wasm_test.zig"),
                .target = wasm_target,
                .optimize = optimize,
                .link_libc = true,
                .link_libcpp = true,
                .imports = &.{
                    .{ .name = "kupcad", .module = mod },
                    .{ .name = "tatfi", .module = tatfi_mod },
                },
            }),
        });
        // all mem must be aligned in 65536 bytes (64Kb)
        wasm_test.initial_memory = 134217728;
        wasm_test.max_memory = 4294967296;
        wasm_test.stack_size = 67108864;

        const run_wasm_test = b.addSystemCommand(&.{ "wasmtime", "--dir=.", "--" });
        run_wasm_test.addFileArg(wasm_test.getEmittedBin());

        const test_wasm_step = b.step("test-wasm", "Run WASM tests");
        test_wasm_step.dependOn(&run_wasm_test.step);
    } else {
        const lsp_kit = b.dependency("lsp_kit", .{
            .target = target,
            .optimize = optimize,
        });

        const exe = b.addExecutable(.{
            .name = "kupcad",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "kupcad", .module = mod },
                    .{ .name = "lsp", .module = lsp_kit.module("lsp") },
                    .{ .name = "tatfi", .module = tatfi_mod },
                },
            }),
        });
        b.installArtifact(exe);

        const lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "kupcad_lib",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/api.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "kupcad", .module = mod },
                    .{ .name = "tatfi", .module = tatfi_mod },
                },
            }),
        });
        b.installArtifact(lib);

        const run_step = b.step("run", "Run the app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const mod_tests = b.addTest(.{
            .root_module = mod,
        });
        const run_mod_tests = b.addRunArtifact(mod_tests);

        const exe_tests = b.addTest(.{
            .root_module = exe.root_module,
        });
        const run_exe_tests = b.addRunArtifact(exe_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
        test_step.dependOn(&run_exe_tests.step);

        const gen_grammar_exe = b.addExecutable(.{
            .name = "gen_grammar",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gen_grammar.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "kupcad", .module = mod },
                    .{ .name = "tatfi", .module = tatfi_mod },
                },
            }),
        });

        const run_gen_grammar = b.addRunArtifact(gen_grammar_exe);
        run_gen_grammar.addArg("../packages/vscode/syntaxes/kupcad.tmLanguage.json");

        const gen_step = b.step("grammar", "Generate VS Code TextMate grammar JSON");
        gen_step.dependOn(&run_gen_grammar.step);
    }
}
