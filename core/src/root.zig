//! The root of the `kupcad` module (build.zig): what it exports to the CLI and other users,
//! and the test files, by the group of tests each is in (test_group.zig).

const std = @import("std");
const TestGroup = @import("test_group.zig").TestGroup;

pub const api = @import("api.zig");
pub const wasm = @import("wasm.zig");
pub const vm = @import("vm/vm.zig");
pub const chunk = @import("vm/chunk.zig");
pub const value = @import("core/value.zig");
pub const locus = @import("locus/src/root.zig");
pub const manifest = @import("stdlib/manifest.zig");
/// For the WebAssembly tests (wasm_test.zig), which run scripts through this module.
pub const test_support = @import("test_support.zig");
pub const std_options = @import("log.zig").std_options;
pub const SessionManager = @import("daemon/session_manager.zig").SessionManager;

pub const formatCode = api.formatCode;
pub const checkCode = api.checkCode;
pub const FormatterConfig = api.FormatterConfig;
pub const LinterConfig = api.LinterConfig;
pub const LinterDiagnostic = api.LinterDiagnostic;
pub const LineIndex = api.LineIndex;

/// The test files, a struct for each group of `TestGroup`: build.zig builds a test binary
/// for each, and the build runs them at once.
const test_files = struct {
    /// The standard library: its classes, methods and parameters, JSON and parts lists.
    pub const stdlib = struct {
        test {
            _ = @import("stdlib/bom_test.zig");
            _ = @import("stdlib/json_fuzz_test.zig");
            _ = @import("stdlib/json_test.zig");
            _ = @import("stdlib/params_test.zig");
            _ = @import("stdlib/stdlib_test.zig");
        }
    };
    /// The VM's machinery: the GC, the geometry graph, imports, limits it enforces at run time.
    pub const vm = struct {
        test {
            _ = @import("vm/chunk_test.zig");
            _ = @import("vm/dag_evaluator_test.zig");
            _ = @import("vm/dag_test.zig");
            _ = @import("vm/dag_verifier_test.zig");
            _ = @import("vm/fuzz_test.zig");
            _ = @import("vm/host_test.zig");
            _ = @import("vm/import_test.zig");
            _ = @import("vm/instruction_hooks_test.zig");
            _ = @import("vm/memory_test.zig");
            _ = @import("vm/profiler_test.zig");
            _ = @import("vm/validation_test.zig");
            _ = @import("vm/verifier_test.zig");
            _ = @import("vm/vm_cad_test.zig");
            _ = @import("vm/vm_runtime_test.zig");
            _ = @import("vm/vm_test.zig");
        }
    };
    /// The language from source to result: lexer, parser, compiler and its features on the VM.
    pub const language = struct {
        test {
            _ = @import("compiler/compiler_test.zig");
            _ = @import("compiler/wide_operands_test.zig");
            _ = @import("frontend/docstring_test.zig");
            _ = @import("frontend/fuzz_test.zig");
            _ = @import("frontend/lexer_test.zig");
            _ = @import("frontend/parser_test.zig");
            _ = @import("vm/language_test.zig");
            _ = @import("vm/vm_blocks_test.zig");
            _ = @import("vm/vm_classes_test.zig");
            _ = @import("vm/vm_collections_test.zig");
            _ = @import("vm/vm_exceptions_test.zig");
            _ = @import("vm/vm_strings_test.zig");
            _ = @import("vm/vm_syntax_test.zig");
        }
    };
    /// The shared core (AST, documents, values, limits) and the tools: formatter, linter, docs.
    pub const core = struct {
        test {
            _ = @import("core/ast_test.zig");
            _ = @import("core/bezier_test.zig");
            _ = @import("core/document_test.zig");
            _ = @import("core/engine_config_test.zig");
            _ = @import("core/error_codes_test.zig");
            _ = @import("core/import_kind_test.zig");
            _ = @import("core/import_path_test.zig");
            _ = @import("core/json_input_test.zig");
            _ = @import("core/limit_allocator_test.zig");
            _ = @import("core/limits_test.zig");
            _ = @import("core/line_index_test.zig");
            _ = @import("core/owned_keys_test.zig");
            _ = @import("core/param_values_test.zig");
            _ = @import("core/params/params_test.zig");
            _ = @import("core/parent_map_test.zig");
            _ = @import("core/placement_test.zig");
            _ = @import("core/resolver_test.zig");
            _ = @import("core/semver_test.zig");
            _ = @import("core/string_escape_test.zig");
            _ = @import("core/text_test.zig");
            _ = @import("core/value_test.zig");
            _ = @import("core/visitor_test.zig");
            _ = @import("core/workspace_test.zig");
            _ = @import("gen_grammar_test.zig");
            _ = @import("log_test.zig");
            _ = @import("registration_test.zig");
            _ = @import("tools/bench_test.zig");
            _ = @import("tools/dev/ast_dumper_test.zig");
            _ = @import("tools/dev/disassembler_test.zig");
            _ = @import("tools/doc/extractor_test.zig");
            _ = @import("tools/fmt/equivalence_test.zig");
            _ = @import("tools/fmt/formatter_test.zig");
            _ = @import("tools/fmt/rules/sort_imports_test.zig");
            _ = @import("tools/fmt/stability_test.zig");
            _ = @import("tools/lint/fixer_test.zig");
            _ = @import("tools/lint/linter_test.zig");
            _ = @import("tools/lint/rules/cad_rules_test.zig");
            _ = @import("tools/lint/rules/negative_dim_test.zig");
            _ = @import("tools/lint/rules/param_order_test.zig");
            _ = @import("tools/lint/rules/self_subtraction_test.zig");
            _ = @import("tools/lint/rules/unreachable_code_test.zig");
            _ = @import("tools/lint/rules/unused_vars_test.zig");
            _ = @import("tools/lint/snapshot_test.zig");
        }
    };
    /// What runs on top: kernels, exporters, the daemon, the CLI, packages, files and Locus.
    pub const app = struct {
        test {
            _ = @import("alloc_failure_test.zig");
            _ = @import("api_test.zig");
            _ = @import("cli/build_cmd_test.zig");
            _ = @import("cli/check_output_test.zig");
            _ = @import("cli/config_test.zig");
            _ = @import("cli/diagnostic_report_test.zig");
            _ = @import("cli/doc_test.zig");
            _ = @import("cli/fmt_test.zig");
            _ = @import("cli/lsp_actions_test.zig");
            _ = @import("cli/lsp_hints_test.zig");
            _ = @import("cli/options_test.zig");
            _ = @import("cli/pkg_cmd_test.zig");
            _ = @import("cli/walker_test.zig");
            _ = @import("cli/watch_test.zig");
            _ = @import("daemon/session_manager_test.zig");
            _ = @import("daemon/session_test.zig");
            _ = @import("daemon/viewport_ws_test.zig");
            _ = @import("daemon/watcher_test.zig");
            _ = @import("determinism_test.zig");
            _ = @import("examples_test.zig");
            _ = @import("exporters/3d/gltf_test.zig");
            _ = @import("exporters/3d/stl_test.zig");
            _ = @import("exporters/3d/threemf_test.zig");
            _ = @import("exporters/zip_test.zig");
            _ = @import("importers_fuzz_test.zig");
            _ = @import("kernel/engines/brep/driver_test.zig");
            _ = @import("kernel/engines/manifold/driver_test.zig");
            _ = @import("kernel/invariants_test.zig");
            _ = @import("kernel/kernel_test.zig");
            _ = @import("kernel/mesh_check_test.zig");
            _ = @import("kernel/parity_test.zig");
            _ = @import("locus/src/root.zig");
            _ = @import("pkg/cafs_test.zig");
            _ = @import("pkg/clock_test.zig");
            _ = @import("pkg/gc_test.zig");
            _ = @import("pkg/health_test.zig");
            _ = @import("pkg/http_client_test.zig");
            _ = @import("pkg/lockfile_test.zig");
            _ = @import("pkg/manifest_test.zig");
            _ = @import("pkg/paths_test.zig");
            _ = @import("pkg/providers/fetcher_test.zig");
            _ = @import("pkg/providers/git_host_test.zig");
            _ = @import("pkg/resolver_test.zig");
            _ = @import("pkg/store_test.zig");
            _ = @import("pkg/string_map_test.zig");
            _ = @import("pkg/validate_test.zig");
            _ = @import("vfs/memory_test.zig");
            _ = @import("vfs/native_test.zig");
            _ = @import("vfs/readonly_test.zig");
            _ = @import("vfs/vfs_test.zig");
        }
    };
};

test {
    // A module built without a group (`zig build fuzz`) has every test
    const selected: ?TestGroup = comptime if (@import("test_options").group) |name|
        std.meta.stringToEnum(TestGroup, name) orelse @compileError("no test group " ++ name)
    else
        null;
    inline for (comptime std.enums.values(TestGroup)) |group| {
        if (comptime (selected == null or selected == group)) _ = @field(test_files, @tagName(group));
    }
}

comptime {
    if (std.meta.declarations(test_files).len != std.enums.values(TestGroup).len) {
        @compileError("test_files has a struct that is no TestGroup: its tests would never run");
    }
}
