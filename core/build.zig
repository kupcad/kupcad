const std = @import("std");

/// The example models in ../examples, built and fingerprinted by src/examples_test.zig
/// (which also checks that every example there is listed here).
const EXAMPLES = [_][]const u8{ "brep", "drone_motor_arm", "standoff", "text" };

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

const draco_sources = &[_][]const u8{
    // --- Attributes ---
    "vendor/draco/src/draco/attributes/attribute_octahedron_transform.cc",
    "vendor/draco/src/draco/attributes/attribute_quantization_transform.cc",
    "vendor/draco/src/draco/attributes/attribute_transform.cc",
    "vendor/draco/src/draco/attributes/geometry_attribute.cc",
    "vendor/draco/src/draco/attributes/point_attribute.cc",

    // --- Compression: Attributes ---
    "vendor/draco/src/draco/compression/attributes/attributes_decoder.cc",
    "vendor/draco/src/draco/compression/attributes/attributes_encoder.cc",
    "vendor/draco/src/draco/compression/attributes/kd_tree_attributes_decoder.cc",
    "vendor/draco/src/draco/compression/attributes/kd_tree_attributes_encoder.cc",
    "vendor/draco/src/draco/compression/attributes/sequential_attribute_decoder.cc",
    "vendor/draco/src/draco/compression/attributes/sequential_attribute_decoders_controller.cc",
    "vendor/draco/src/draco/compression/attributes/sequential_attribute_encoder.cc",
    "vendor/draco/src/draco/compression/attributes/sequential_attribute_encoders_controller.cc",
    "vendor/draco/src/draco/compression/attributes/sequential_integer_attribute_decoder.cc",
    "vendor/draco/src/draco/compression/attributes/sequential_integer_attribute_encoder.cc",
    "vendor/draco/src/draco/compression/attributes/sequential_normal_attribute_decoder.cc",
    "vendor/draco/src/draco/compression/attributes/sequential_normal_attribute_encoder.cc",
    "vendor/draco/src/draco/compression/attributes/sequential_quantization_attribute_decoder.cc",
    "vendor/draco/src/draco/compression/attributes/sequential_quantization_attribute_encoder.cc",
    "vendor/draco/src/draco/compression/attributes/prediction_schemes/prediction_scheme_encoder_factory.cc",

    // --- Compression: Bit Coders ---
    "vendor/draco/src/draco/compression/bit_coders/adaptive_rans_bit_decoder.cc",
    "vendor/draco/src/draco/compression/bit_coders/adaptive_rans_bit_encoder.cc",
    "vendor/draco/src/draco/compression/bit_coders/direct_bit_decoder.cc",
    "vendor/draco/src/draco/compression/bit_coders/direct_bit_encoder.cc",
    "vendor/draco/src/draco/compression/bit_coders/rans_bit_decoder.cc",
    "vendor/draco/src/draco/compression/bit_coders/rans_bit_encoder.cc",
    "vendor/draco/src/draco/compression/bit_coders/symbol_bit_decoder.cc",
    "vendor/draco/src/draco/compression/bit_coders/symbol_bit_encoder.cc",

    // --- Compression: Core, Entropy & Mesh ---
    "vendor/draco/src/draco/compression/draco_compression_options.cc",
    "vendor/draco/src/draco/compression/decode.cc",
    "vendor/draco/src/draco/compression/encode.cc",
    "vendor/draco/src/draco/compression/expert_encode.cc",
    "vendor/draco/src/draco/compression/entropy/shannon_entropy.cc",
    "vendor/draco/src/draco/compression/entropy/symbol_decoding.cc",
    "vendor/draco/src/draco/compression/entropy/symbol_encoding.cc",
    "vendor/draco/src/draco/compression/mesh/mesh_decoder.cc",
    "vendor/draco/src/draco/compression/mesh/mesh_edgebreaker_decoder_impl.cc",
    "vendor/draco/src/draco/compression/mesh/mesh_edgebreaker_decoder.cc",
    "vendor/draco/src/draco/compression/mesh/mesh_edgebreaker_encoder_impl.cc",
    "vendor/draco/src/draco/compression/mesh/mesh_edgebreaker_encoder.cc",
    "vendor/draco/src/draco/compression/mesh/mesh_encoder.cc",
    "vendor/draco/src/draco/compression/mesh/mesh_sequential_decoder.cc",
    "vendor/draco/src/draco/compression/mesh/mesh_sequential_encoder.cc",

    // --- Compression: Point Cloud ---
    "vendor/draco/src/draco/compression/point_cloud/algorithms/dynamic_integer_points_kd_tree_decoder.cc",
    "vendor/draco/src/draco/compression/point_cloud/algorithms/dynamic_integer_points_kd_tree_encoder.cc",
    "vendor/draco/src/draco/compression/point_cloud/algorithms/float_points_tree_decoder.cc",
    "vendor/draco/src/draco/compression/point_cloud/algorithms/float_points_tree_encoder.cc",
    "vendor/draco/src/draco/compression/point_cloud/algorithms/integer_points_kd_tree_decoder.cc",
    "vendor/draco/src/draco/compression/point_cloud/algorithms/integer_points_kd_tree_encoder.cc",
    "vendor/draco/src/draco/compression/point_cloud/point_cloud_decoder.cc",
    "vendor/draco/src/draco/compression/point_cloud/point_cloud_encoder.cc",
    "vendor/draco/src/draco/compression/point_cloud/point_cloud_kd_tree_decoder.cc",
    "vendor/draco/src/draco/compression/point_cloud/point_cloud_kd_tree_encoder.cc",
    "vendor/draco/src/draco/compression/point_cloud/point_cloud_sequential_decoder.cc",
    "vendor/draco/src/draco/compression/point_cloud/point_cloud_sequential_encoder.cc",

    // --- Core ---
    "vendor/draco/src/draco/core/bit_utils.cc",
    "vendor/draco/src/draco/core/bounding_box.cc",
    "vendor/draco/src/draco/core/cycle_timer.cc",
    "vendor/draco/src/draco/core/data_buffer.cc",
    "vendor/draco/src/draco/core/decoder_buffer.cc",
    "vendor/draco/src/draco/core/divide.cc",
    "vendor/draco/src/draco/core/draco_types.cc",
    "vendor/draco/src/draco/core/encoder_buffer.cc",
    "vendor/draco/src/draco/core/hash_utils.cc",
    "vendor/draco/src/draco/core/options.cc",
    "vendor/draco/src/draco/core/quantization_utils.cc",
    "vendor/draco/src/draco/core/status.cc",

    // --- Mesh ---
    "vendor/draco/src/draco/mesh/corner_table.cc",
    "vendor/draco/src/draco/mesh/mesh_are_equivalent.cc",
    "vendor/draco/src/draco/mesh/mesh_attribute_corner_table.cc",
    "vendor/draco/src/draco/mesh/mesh_cleanup.cc",
    "vendor/draco/src/draco/mesh/mesh_features.cc",
    "vendor/draco/src/draco/mesh/mesh_misc_functions.cc",
    "vendor/draco/src/draco/mesh/mesh_splitter.cc",
    "vendor/draco/src/draco/mesh/mesh_stripifier.cc",
    "vendor/draco/src/draco/mesh/mesh_utils.cc",
    "vendor/draco/src/draco/mesh/mesh.cc",
    "vendor/draco/src/draco/mesh/triangle_soup_mesh_builder.cc",

    // --- Point Cloud ---
    "vendor/draco/src/draco/point_cloud/point_cloud.cc",
    "vendor/draco/src/draco/point_cloud/point_cloud_builder.cc",

    // --- Metadata ---
    "vendor/draco/src/draco/metadata/geometry_metadata.cc",
    "vendor/draco/src/draco/metadata/metadata.cc",
    "vendor/draco/src/draco/metadata/metadata_decoder.cc",
    "vendor/draco/src/draco/metadata/metadata_encoder.cc",
    "vendor/draco/src/draco/metadata/property_attribute.cc",
    "vendor/draco/src/draco/metadata/property_table.cc",
    "vendor/draco/src/draco/metadata/structural_metadata.cc",
    "vendor/draco/src/draco/metadata/structural_metadata_schema.cc",
};

const kupcad_bindings = &[_][]const u8{
    "src/bindings/manifold_c.cpp",
    "src/bindings/draco_c.cpp",
    "src/locus/src/bindings/eigen_c.cpp",
    "src/locus/src/bindings/parallel_c.cpp",
};

/// `base` plus, outside Debug builds, -DNDEBUG, so the vendored C++ libraries' asserts
/// (Manifold has many, some costly) are compiled out of release binaries, as their own
/// release builds do, and -fno-sanitize=undefined: Zig compiles C and C++ with UBSan in
/// Debug and, trapping, in ReleaseSafe, so a ReleaseSafe kernel ran every arithmetic
/// check of UBSan and aborted the process on a finding. Debug builds keep both.
fn cxxFlags(b: *std.Build, optimize: std.builtin.OptimizeMode, base: []const []const u8) []const []const u8 {
    if (optimize == .debug) return base;
    return std.mem.concat(b.allocator, []const u8, &.{ base, &.{ "-DNDEBUG", "-fno-sanitize=undefined" } }) catch @panic("out of memory");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Detect if target is WASM
    const is_wasm = target.result.cpu.arch == .wasm32;
    const is_x86_64 = target.result.cpu.arch == .x86_64;
    const is_macos = target.result.os.tag == .macos;

    const wasm_threads = b.option(
        bool,
        "wasm_threads",
        "Enable Wasm threads (SharedArrayBuffer, Atomics, Bulk Memory)",
    ) orelse false;

    const wasm_features = if (is_wasm and wasm_threads)
        std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory })
    else
        std.Target.wasm.featureSet(&.{});

    // Use WASI for WASM builds so Zig provides wasi-libc
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        .cpu_features_add = wasm_features,
    });

    const active_target = if (is_wasm) wasm_target else target;

    const enable_parallel = b.option(
        bool,
        "manifold_parallel",
        "Enable multi-threaded parallel backend via Intel TBB",
    ) orelse !is_wasm;

    // --- Add tatfi dependency ---
    const use_vendored_tatfi = true;

    const tatfi_mod = if (use_vendored_tatfi) blk: {
        const t_mod = b.createModule(.{
            .root_source_file = b.path("vendor/tatfi/src/lib.zig"),
            .target = active_target,
            .optimize = optimize,
        });

        // tatfi requires a "config" options module
        const tatfi_opts = b.addOptions();
        tatfi_opts.addOption(bool, "variable_fonts", true);
        tatfi_opts.addOption(bool, "opentype_layout", true);
        tatfi_opts.addOption(bool, "apple_layout", true);
        tatfi_opts.addOption(usize, "gvar_max_stack_tuples_len", 32);

        t_mod.addOptions("config", tatfi_opts);
        break :blk t_mod;
    } else b.dependency("tatfi", .{}).module("tatfi");

    // --- list all deps ---
    const module_imports: []const std.Build.Module.Import = &.{
        .{ .name = "tatfi", .module = tatfi_mod },
    };

    // ====================================================================
    // C/C++ Flags & Headers
    // ====================================================================
    const wasm_stub_header = "src/wasm_stubs.h";
    const manifold_flags: []const []const u8 = if (is_wasm)
        if (wasm_threads)
            &.{
                "-std=c++17",          "-fno-exceptions",        "-fno-rtti",                "-fno-sanitize=undefined",
                "-DNDEBUG",            "-DMANIFOLD_NO_IOSTREAM", "-DMANIFOLD_NO_FILESYSTEM", "-DMANIFOLD_PAR=-1",
                "-fvisibility=hidden", "-include",               wasm_stub_header,           "-matomics",
                "-mbulk-memory",       "-pthread",
            }
        else
            &.{
                "-std=c++17",          "-fno-exceptions",        "-fno-rtti",                "-fno-sanitize=undefined",
                "-DNDEBUG",            "-DMANIFOLD_NO_IOSTREAM", "-DMANIFOLD_NO_FILESYSTEM", "-DMANIFOLD_PAR=-1",
                "-fvisibility=hidden", "-include",               wasm_stub_header,
            }
    else if (enable_parallel)
        cxxFlags(b, optimize, &.{ "-std=c++17", "-fno-exceptions", "-DMANIFOLD_PAR=1" })
    else
        cxxFlags(b, optimize, &.{ "-std=c++17", "-fno-exceptions", "-DMANIFOLD_PAR=-1" });

    // ====================================================================
    // KupCAD Core Module
    // ====================================================================
    const mod = b.addModule("kupcad", .{
        .root_source_file = b.path("src/root.zig"),
        .target = active_target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = module_imports,
    });
    // The version, read from build.zig.zon so it has one source: `kupcad --version`, the
    // language server's serverInfo and the package client's User-Agent read it.
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", @import("build.zig.zon").version);
    // Every VM collects at every object allocation, so a value a native or the VM forgot to
    // root is swept at once wherever a test runs a script (the nightly job; slow).
    build_info.addOption(bool, "gc_stress", b.option(bool, "gc-stress", "Collect garbage at every allocation in every VM, to find unrooted values (slow)") orelse false);
    mod.addOptions("build_info", build_info);

    // The C and C++ libraries (Clipper2, Manifold, oneTBB, SQLite, Draco) and KupCAD's
    // bindings to them, as one static library the module links. Outside the Zig module, a
    // fuzzing build (`zig build test --fuzz`), which instruments what the test compiles,
    // leaves them alone: clang's coverage hooks for C and C++ aren't in Zig's fuzzer.
    const native_mod = b.createModule(.{
        .target = active_target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    native_mod.addIncludePath(b.path("vendor/Clipper2/CPP/Clipper2Lib/include"));
    native_mod.addIncludePath(b.path("vendor/manifold/include"));
    native_mod.addIncludePath(b.path("vendor/manifold/bindings/c"));
    native_mod.addIncludePath(b.path("vendor/manifold/bindings/c/include"));
    native_mod.addIncludePath(b.path("vendor/draco/src"));
    native_mod.addIncludePath(b.path("vendor/eigen"));
    native_mod.addIncludePath(b.path("vendor/sqlite"));
    native_mod.addIncludePath(b.path("src/bindings"));
    native_mod.addIncludePath(b.path("src"));

    const clipper_flags: []const []const u8 = cxxFlags(b, optimize, if (is_wasm)
        &.{ "-std=c++17", "-fno-exceptions", "-fvisibility=hidden" }
    else
        &.{ "-std=c++17", "-fno-exceptions" });

    native_mod.addCSourceFiles(.{
        .files = clipper_sources,
        .flags = clipper_flags,
    });

    native_mod.addCSourceFiles(.{
        .files = manifold_sources,
        .flags = manifold_flags,
    });

    if (enable_parallel and !is_wasm) {
        native_mod.addIncludePath(b.path("vendor/oneTBB/include"));

        const tbb_flags: []const []const u8 = if (is_macos)
            &.{ "-std=c++17", "-fexceptions", "-DTBB_USE_DEBUG=0", "-D__TBB_BUILD=1", "-D_XOPEN_SOURCE" }
        else if (is_x86_64)
            // Safely pass waitpkg exclusively to the Clang C++ frontend.
            // This satisfies oneTBB's internal macros without poisoning Manifold or the global Zig target
            &.{ "-std=c++17", "-fexceptions", "-DTBB_USE_DEBUG=0", "-D__TBB_BUILD=1", "-Xclang", "-target-feature", "-Xclang", "+waitpkg" }
        else
            // Fallback for ARM Linux, Windows on ARM, etc.
            &.{ "-std=c++17", "-fexceptions", "-DTBB_USE_DEBUG=0", "-D__TBB_BUILD=1" };
        native_mod.addCSourceFiles(.{
            .files = tbb_sources,
            .flags = tbb_flags,
        });
    }

    const sqlite_flags: []const []const u8 = if (is_wasm)
        &.{
            "-std=c99",
            "-DNDEBUG",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_OS_OTHER=1", // Tells SQLite not to use POSIX/Windows OS calls on WASM
        }
    else
        &.{ "-std=c99", "-DNDEBUG", "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION" };

    native_mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = sqlite_flags,
    });

    const drako_flags: []const []const u8 = cxxFlags(b, optimize, if (is_wasm)
        &.{ "-std=c++17", "-fno-exceptions", "-fvisibility=hidden" }
    else
        &.{ "-std=c++17", "-fno-exceptions" });

    native_mod.addCSourceFiles(.{
        .files = draco_sources,
        .flags = drako_flags,
    });

    // KUPCAD_TBB: oneTBB is built in, so kupcad_set_max_threads can cap its threads.
    const kupcad_flags: []const []const u8 = cxxFlags(b, optimize, if (enable_parallel and !is_wasm)
        &.{ "-std=c++17", "-Wno-nullability-completeness", "-fno-exceptions", "-DKUPCAD_TBB=1" }
    else
        &.{ "-std=c++17", "-Wno-nullability-completeness", "-fno-exceptions" });

    native_mod.addCSourceFiles(.{
        .files = kupcad_bindings,
        .flags = kupcad_flags,
    });

    const native = b.addLibrary(.{
        .linkage = .static,
        .name = "kupcad_native",
        .root_module = native_mod,
    });
    mod.linkLibrary(native);

    const sqlite_mod = b.createModule(.{
        .root_source_file = b.path("vendor/sqlite/sqlite_bindings.zig"),
        .target = active_target,
        .optimize = optimize,
    });
    mod.addImport("sqlite", sqlite_mod);

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
        wasm.root_module.addOptions("build_info", build_info);

        wasm.entry = .disabled;
        wasm.wasi_exec_model = .reactor;
        wasm.rdynamic = true;
        wasm.root_module.strip = true;

        // all mem must be aligned in 65536 bytes (64Kb)
        wasm.initial_memory = 134217728;
        wasm.max_memory = 4294967296;
        wasm.stack_size = 67108864;

        if (wasm_threads) {
            wasm.shared_memory = true;
            wasm.import_memory = true; // JS host will provide the WebAssembly.Memory object
        }

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
        wasm_test.root_module.addOptions("build_info", build_info);
        // all mem must be aligned in 65536 bytes (64Kb)
        wasm_test.initial_memory = 134217728;
        wasm_test.max_memory = 4294967296;
        wasm_test.stack_size = 67108864;

        if (wasm_threads) {
            wasm_test.shared_memory = true;
            wasm_test.import_memory = false;
        }

        const run_wasm_test = b.addSystemCommand(&.{ "wasmtime", "--dir=." });

        // Wasmtime requires a flag to enable thread support in testing BEFORE the '--'
        if (wasm_threads) {
            run_wasm_test.addArgs(&.{ "-W", "threads=y,shared-memory=y" });
        }

        // Now add the separator and the emitted binary
        run_wasm_test.addArg("--");
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
                    .{ .name = "sqlite", .module = sqlite_mod },
                },
            }),
        });
        exe.root_module.addOptions("build_info", build_info);
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
                    .{ .name = "sqlite", .module = sqlite_mod },
                },
            }),
        });
        lib.root_module.addOptions("build_info", build_info);
        b.installArtifact(lib);

        const run_step = b.step("run", "Run the app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());

        const test_filters = b.option([]const []const u8, "test-filter", "Filter tests by name") orelse &.{};
        // Lint snapshot tests rewrite their expected output instead of comparing with it.
        const update_snapshots = b.option(bool, "update-snapshots", "Rewrite the lint and example snapshots (src/tools/lint/snapshots, src/examples.snap) from the current output") orelse false;
        const snapshot_options = b.addOptions();
        snapshot_options.addOption(bool, "update", update_snapshots);
        mod.addOptions("lint_snapshot_options", snapshot_options);

        // The examples are outside the module, so each comes in as an import (the build
        // reruns the test when one changes).
        const examples_options = b.addOptions();
        examples_options.addOption([]const []const u8, "names", &EXAMPLES);
        examples_options.addOption(bool, "update", update_snapshots);
        mod.addOptions("examples", examples_options);
        for (EXAMPLES) |name| {
            mod.addAnonymousImport(b.fmt("example/{s}", .{name}), .{ .root_source_file = b.path(b.fmt("../examples/{s}.kup", .{name})) });
        }

        const mod_tests = b.addTest(.{
            .root_module = mod,
            .filters = test_filters,
        });
        const run_mod_tests = b.addRunArtifact(mod_tests);
        // Rewriting the snapshots must run the tests even when nothing they embed changed.
        if (update_snapshots) run_mod_tests.has_side_effects = true;

        const exe_tests = b.addTest(.{
            .root_module = exe.root_module,
            .filters = test_filters,
        });
        const run_exe_tests = b.addRunArtifact(exe_tests);

        // Black-box CLI tests: run the built `kupcad` binary and check exit codes and output.
        const cli_test_options = b.addOptions();
        cli_test_options.addOptionPath("kupcad_exe", exe.getEmittedBin());
        cli_test_options.addOption([]const u8, "version", @import("build.zig.zon").version);
        const cli_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/cli_process_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "cli_test_options", .module = cli_test_options.createModule() }},
            }),
            .filters = test_filters,
        });
        const run_cli_tests = b.addRunArtifact(cli_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
        test_step.dependOn(&run_exe_tests.step);
        test_step.dependOn(&run_cli_tests.step);

        if (use_vendored_tatfi) {
            const tatfi_tests = b.addTest(.{
                .root_module = tatfi_mod,
                .filters = test_filters,
            });
            const run_tatfi_tests = b.addRunArtifact(tatfi_tests);
            test_step.dependOn(&run_tatfi_tests.step);
        }

        const gen_grammar_exe = b.addExecutable(.{
            .name = "gen_grammar",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gen_grammar.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "kupcad", .module = mod },
                    .{ .name = "tatfi", .module = tatfi_mod },
                    .{ .name = "sqlite", .module = sqlite_mod },
                },
            }),
        });
        // It reaches the VM through relative imports, which read the build's options.
        gen_grammar_exe.root_module.addOptions("build_info", build_info);

        const run_gen_grammar = b.addRunArtifact(gen_grammar_exe);
        run_gen_grammar.addArg("../packages/kupcad-vscode/syntaxes/kupcad.tmLanguage.json");

        const gen_step = b.step("grammar", "Generate VS Code TextMate grammar JSON");
        gen_step.dependOn(&run_gen_grammar.step);
    }
}
