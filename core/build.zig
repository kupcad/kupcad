const std = @import("std");

/// The example models in ../examples, built and fingerprinted by src/examples_test.zig
/// (which also checks that every example there is listed here).
const EXAMPLES = [_][]const u8{ "coffee_mug", "cup", "grid_organizer", "planetary_gearbox", "project_box", "screw_top_jar", "standoff", "text" };

/// Variation tuples tatfi's gvar keeps on the stack before it takes the heap (its default).
const TATFI_GVAR_STACK_TUPLES = 32;

/// Manifold's version, as its CMakeLists.txt sets it (MANIFOLD_VERSION_*): the header its
/// CMake writes from cmake/version.h.in, which manifold.cpp includes, is written from it here.
const MANIFOLD_VERSION = .{ .major = 3, .minor = 5, .patch = 1 };

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

/// The tables tatfi reads besides the required ones, its build options (vendor/tatfi/build.zig).
const TatfiFeatures = struct {
    /// avar, CFF2, fvar, gvar, HVAR, MVAR and VVAR
    variable_fonts: bool = true,
    /// GDEF, GPOS, GSUB and MATH
    opentype_layout: bool = true,
    /// ankr, feat, kerx, morx, trak and kern's format 1
    apple_layout: bool = true,
};

/// tatfi as a module of this build, reading the tables of `features`. It is made here, not
/// by its own build.zig, whose module has no target as a dependency: its tests run in this
/// build's target and mode, as the rest do.
fn tatfiModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, features: TatfiFeatures) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("vendor/tatfi/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const config = b.addOptions();
    inline for (@typeInfo(TatfiFeatures).@"struct".field_names) |name| config.addOption(bool, name, @field(features, name));
    config.addOption(usize, "gvar_max_stack_tuples_len", TATFI_GVAR_STACK_TUPLES);
    module.addOptions("config", config);
    return module;
}

/// A root's `own` imports and the core module's: a root in src/ (the CLI, the Wasm module, the
/// library) compiles the core's files itself, so it needs the modules they import.
fn withCoreImports(b: *std.Build, own: []const std.Build.Module.Import, core: []const std.Build.Module.Import) []const std.Build.Module.Import {
    return std.mem.concat(b.allocator, std.Build.Module.Import, &.{ own, core }) catch @panic("OOM");
}

/// `base` plus, outside Debug builds, -DNDEBUG, so the vendored C and C++ libraries' asserts
/// (Manifold has many, some costly) are compiled out of release binaries, as their own
/// release builds do, and -fno-sanitize=undefined: Zig compiles C and C++ with UBSan in
/// Debug and, trapping, in ReleaseSafe, so a ReleaseSafe kernel ran every arithmetic
/// check of UBSan and aborted the process on a finding. Debug builds keep both.
fn vendoredFlags(b: *std.Build, optimize: std.lang.Optimize, base: []const []const u8) []const []const u8 {
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
    const is_windows = target.result.os.tag == .windows;

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

    // The font parser (vendor/tatfi), for text: its fonts' characters, outlines and names.
    // HarfBuzz reads the layout tables (GSUB, GPOS) itself, and none of the embedded fonts is
    // variable or has Apple tables.
    const tatfi_mod = tatfiModule(b, active_target, optimize, .{ .variable_fonts = false, .opentype_layout = false, .apple_layout = false });
    // Text shaping's bindings: HarfBuzz and SheenBidi, compiled into the native library below
    const harfbuzz_mod = b.createModule(.{ .root_source_file = b.path("src/bindings/harfbuzz.zig"), .target = active_target, .optimize = optimize });
    const sheenbidi_mod = b.createModule(.{ .root_source_file = b.path("src/bindings/sheenbidi.zig"), .target = active_target, .optimize = optimize });

    // --- list all deps ---
    const module_imports: []const std.Build.Module.Import = &.{
        .{ .name = "tatfi", .module = tatfi_mod },
        .{ .name = "harfbuzz", .module = harfbuzz_mod },
        .{ .name = "sheenbidi", .module = sheenbidi_mod },
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
        vendoredFlags(b, optimize, &.{ "-std=c++17", "-fno-exceptions", "-DMANIFOLD_PAR=1" })
    else
        vendoredFlags(b, optimize, &.{ "-std=c++17", "-fno-exceptions", "-DMANIFOLD_PAR=-1" });

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
    // Whether oneTBB is built in, for the tests that check both kernels run on it.
    build_info.addOption(bool, "tbb", enable_parallel and !is_wasm);
    mod.addOptions("build_info", build_info);

    // The C and C++ libraries (Manifold, oneTBB, SQLite, Draco, HarfBuzz, SheenBidi) and KupCAD's
    // bindings to them, as one static library the module links. Outside the Zig module, a
    // fuzzing build (`zig build test --fuzz`), which instruments what the test compiles,
    // leaves them alone: clang's coverage hooks for C and C++ aren't in Zig's fuzzer.
    const native_mod = b.createModule(.{
        .target = active_target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    native_mod.addIncludePath(b.path("vendor/manifold/include"));
    native_mod.addConfigHeader(b.addConfigHeader(.{
        .style = .{ .cmake = b.path("vendor/manifold/cmake/version.h.in") },
        .include_path = "manifold/version.h",
    }, .{
        .MANIFOLD_VERSION_MAJOR = MANIFOLD_VERSION.major,
        .MANIFOLD_VERSION_MINOR = MANIFOLD_VERSION.minor,
        .MANIFOLD_VERSION_PATCH = MANIFOLD_VERSION.patch,
    }));
    native_mod.addIncludePath(b.path("vendor/manifold/bindings/c"));
    native_mod.addIncludePath(b.path("vendor/manifold/bindings/c/include"));
    native_mod.addIncludePath(b.path("vendor/draco/src"));
    native_mod.addIncludePath(b.path("vendor/eigen"));
    native_mod.addIncludePath(b.path("vendor/sqlite"));
    native_mod.addIncludePath(b.path("src/bindings"));
    native_mod.addIncludePath(b.path("src"));

    native_mod.addCSourceFiles(.{
        .files = manifold_sources,
        .flags = manifold_flags,
    });

    if (enable_parallel and !is_wasm) {
        native_mod.addIncludePath(b.path("vendor/oneTBB/include"));

        const tbb_common: []const []const u8 = &.{ "-std=c++17", "-fexceptions", "-DTBB_USE_DEBUG=0", "-D__TBB_BUILD=1" };
        const tbb_macos: []const []const u8 = if (is_macos) &.{"-D_XOPEN_SOURCE"} else &.{};
        // oneTBB pauses with tpause on x86 CPUs that have WAITPKG, which it checks at run time:
        // the feature is on for its own files only, not for Manifold's or the Zig target's, as
        // its CMake build does. Both x86_64 systems need it, so it adds to the macOS flags.
        const tbb_x86_64: []const []const u8 = if (is_x86_64) &.{ "-Xclang", "-target-feature", "-Xclang", "+waitpkg" } else &.{};
        native_mod.addCSourceFiles(.{
            .files = tbb_sources,
            .flags = std.mem.concat(b.allocator, []const u8, &.{ tbb_common, tbb_macos, tbb_x86_64 }) catch @panic("OOM"),
        });
        // oneTBB checks the signature of a DLL before it loads one (dynamic_link.cpp) and asks
        // for wintrust with `#pragma comment(lib)`, which only MSVC's linker reads
        if (is_windows) native_mod.linkSystemLibrary("wintrust", .{});
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

    const drako_flags: []const []const u8 = vendoredFlags(b, optimize, if (is_wasm)
        &.{ "-std=c++17", "-fno-exceptions", "-fvisibility=hidden" }
    else
        &.{ "-std=c++17", "-fno-exceptions" });

    native_mod.addCSourceFiles(.{
        .files = draco_sources,
        .flags = drako_flags,
    });

    // HarfBuzz, lean: without what text doesn't use (variable fonts, outlines, names, vertical
    // text, Apple's AAT shaping), harfbuzz_config.h adjusting the preset; a Wasm build without
    // threads has no mutexes. SheenBidi, its sources as one file.
    const harfbuzz_base: []const []const u8 = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-DHB_LEAN", "-DHB_NO_AAT", "-DHB_CONFIG_OVERRIDE_H=\"harfbuzz_config.h\"" };
    const harfbuzz_threads: []const []const u8 = if (is_wasm and !wasm_threads) &.{"-DHB_NO_MT"} else &.{};
    native_mod.addCSourceFile(.{
        .file = b.path("vendor/harfbuzz/src/harfbuzz.cc"),
        .flags = vendoredFlags(b, optimize, std.mem.concat(b.allocator, []const u8, &.{ harfbuzz_base, harfbuzz_threads }) catch @panic("OOM")),
    });
    native_mod.addIncludePath(b.path("vendor/sheenbidi/Headers"));
    native_mod.addIncludePath(b.path("vendor/sheenbidi/Source"));
    native_mod.addCSourceFile(.{
        .file = b.path("vendor/sheenbidi/Source/SheenBidi.c"),
        .flags = vendoredFlags(b, optimize, &.{"-DSB_CONFIG_UNITY"}),
    });

    // oneTBB is built in: KUPCAD_TBB lets kupcad_set_max_threads cap its threads, and
    // LOCUS_TBB runs Locus's parallel_for on them.
    const kupcad_flags: []const []const u8 = vendoredFlags(b, optimize, if (enable_parallel and !is_wasm)
        &.{ "-std=c++17", "-Wno-nullability-completeness", "-fno-exceptions", "-DKUPCAD_TBB=1", "-DLOCUS_TBB=1" }
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
                .imports = withCoreImports(b, &.{.{ .name = "kupcad", .module = mod }}, module_imports),
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
                .imports = withCoreImports(b, &.{.{ .name = "kupcad", .module = mod }}, module_imports),
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
        run_wasm_test.addFileArg2(wasm_test.getEmittedBin(), .{});

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
                .imports = withCoreImports(b, &.{
                    .{ .name = "kupcad", .module = mod },
                    .{ .name = "lsp", .module = lsp_kit.module("lsp") },
                    .{ .name = "sqlite", .module = sqlite_mod },
                }, module_imports),
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
                .imports = withCoreImports(b, &.{
                    .{ .name = "kupcad", .module = mod },
                    .{ .name = "sqlite", .module = sqlite_mod },
                }, module_imports),
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
        // So is the README, whose table of error codes a test keeps complete.
        mod.addAnonymousImport("docs/README.md", .{ .root_source_file = b.path("docs/README.md") });
        // And the grammars `zig build grammar` writes, which a test keeps up to date.
        mod.addAnonymousImport("grammar/kupcad.tmLanguage.json", .{ .root_source_file = b.path("../packages/kupcad-vscode/syntaxes/kupcad.tmLanguage.json") });
        mod.addAnonymousImport("grammar/vocabulary.json", .{ .root_source_file = b.path("../packages/kupcad-editor/src/vocabulary.json") });

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

        // tatfi's own tests, with every table it reads
        const tatfi_tests = b.addTest(.{
            .root_module = tatfiModule(b, target, optimize, .{}),
            .filters = test_filters,
        });
        test_step.dependOn(&b.addRunArtifact(tatfi_tests).step);

        // `zig build fuzz --fuzz=<runs>` searches from the fuzz corpus with the front end's
        // and the runtime's fuzz tests (src/frontend/fuzz_test.zig, src/vm/fuzz_test.zig),
        // each up to <runs>; -Dfuzz-target picks one, so CI fuzzes each in a job of its own,
        // with as many runs as fit (a generated program costs far more than random bytes).
        // Only those tests are built, with LLVM: Zig's own x86_64 backend, the debug
        // default on Linux, emits no coverage instrumentation, so the nightly job fuzzed
        // blind and its report failed on "pcs_len was zero".
        const FuzzTarget = enum { frontend, frontend_programs, runtime, runtime_programs, importers, json, fonts };
        const fuzz_target = b.option(FuzzTarget, "fuzz-target", "The fuzz tests `zig build fuzz` runs (all when unset): frontend or runtime on bytes, frontend_programs or runtime_programs on generated programs, importers for the file and network parsers, json for the JSON files scripts read, fonts for the font files they import");
        // The tests' full names: a filter that matched none would fuzz nothing.
        const fuzz_filter: []const u8 = if (fuzz_target) |t| switch (t) {
            .frontend => "frontend.fuzz_test.test.fuzz: the front end takes any input",
            .frontend_programs => "frontend.fuzz_test.test.fuzz: the front end takes any generated program",
            .runtime => "vm.fuzz_test.test.fuzz: a script runs without crashing the VM",
            .runtime_programs => "vm.fuzz_test.test.fuzz: a generated program runs without crashing the VM",
            // Every parser of src/importers_fuzz_test.zig: each is quick
            .importers => "importers_fuzz_test.test.fuzz:",
            .json => "stdlib.json_fuzz_test.test.fuzz: a JSON file a script reads",
            // Also among the importers, but tatfi is the largest parser of what scripts give
            .fonts => "importers_fuzz_test.test.fuzz: a font file a script imports",
        } else "fuzz:";
        const fuzz_tests = b.addTest(.{
            .root_module = mod,
            .filters = b.graph.dupeStrings(&.{fuzz_filter}),
            .use_llvm = true,
        });
        const fuzz_step = b.step("fuzz", "Fuzz the front end and the runtime (with --fuzz; without it, replay the corpus)");
        fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

        const gen_grammar_exe = b.addExecutable(.{
            .name = "gen_grammar",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gen_grammar.zig"),
                .target = target,
                .optimize = optimize,
                .imports = withCoreImports(b, &.{
                    .{ .name = "kupcad", .module = mod },
                    .{ .name = "sqlite", .module = sqlite_mod },
                }, module_imports),
            }),
        });
        // It reaches the VM through relative imports, which read the build's options.
        gen_grammar_exe.root_module.addOptions("build_info", build_info);

        const run_gen_grammar = b.addRunArtifact(gen_grammar_exe);
        run_gen_grammar.addArg("../packages/kupcad-vscode/syntaxes/kupcad.tmLanguage.json");
        run_gen_grammar.addArg("../packages/kupcad-editor/src/vocabulary.json");

        const gen_step = b.step("grammar", "Generate the VS Code TextMate grammar and the editor's vocabulary");
        gen_step.dependOn(&run_gen_grammar.step);
    }
}
