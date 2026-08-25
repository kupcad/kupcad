pub const api = @import("api.zig");
pub const manifest = @import("stdlib/manifest.zig");

pub const formatCode = api.formatCode;
pub const checkCode = api.checkCode;
pub const FormatterConfig = api.FormatterConfig;
pub const LinterConfig = api.LinterConfig;
pub const LinterDiagnostic = api.LinterDiagnostic;
pub const LineIndex = api.LineIndex;

test {
    _ = @import("api_test.zig");
    _ = @import("gen_grammar_test.zig");

    // Compiler
    _ = @import("compiler/compiler_test.zig");

    // Core
    _ = @import("core/ast_test.zig");
    _ = @import("core/bezier_test.zig");
    _ = @import("core/constant_folder_test.zig");
    _ = @import("core/document_test.zig");
    _ = @import("core/line_index_test.zig");
    _ = @import("core/limit_allocator_test.zig");
    _ = @import("core/resolver_test.zig");
    _ = @import("core/parent_map_test.zig");
    _ = @import("core/workspace_test.zig");
    _ = @import("core/value_test.zig");
    _ = @import("core/params/params_test.zig");
    _ = @import("core/text_test.zig");

    // Frontends
    _ = @import("frontend/kupcad/docstring_test.zig");
    _ = @import("frontend/kupcad/lexer_test.zig");
    _ = @import("frontend/kupcad/parser_test.zig");
    _ = @import("frontend/openscad/lexer_test.zig");
    _ = @import("frontend/openscad/parser_test.zig");

    // Kernels
    _ = @import("kernel/engines/manifold/driver_test.zig");

    // CLI & Config Tests
    _ = @import("cli/config_test.zig");
    _ = @import("cli/options_test.zig");
    _ = @import("cli/walker_test.zig");

    // Docs
    _ = @import("tools/doc/extractor_test.zig");

    // Dev tools
    _ = @import("tools/dev/ast_dumper_test.zig");

    // Formatter Tests
    _ = @import("tools/fmt/formatter_test.zig");
    _ = @import("tools/fmt/rules/sort_imports_test.zig");

    // Linter Tests
    _ = @import("tools/lint/linter_test.zig");
    _ = @import("tools/lint/rules/negative_dim_test.zig");
    _ = @import("tools/lint/rules/unused_vars_test.zig");
    _ = @import("tools/lint/rules/unreachable_code_test.zig");
    _ = @import("tools/lint/rules/self_subtraction_test.zig");
    _ = @import("tools/lint/rules/param_order_test.zig");

    // VM
    _ = @import("vm/chunk_test.zig");
    _ = @import("vm/dag_evaluator_test.zig");
    _ = @import("vm/memory_test.zig");
    _ = @import("vm/host_test.zig");
    _ = @import("vm/profiler_test.zig");
    _ = @import("vm/validation_test.zig");
    _ = @import("vm/verifier_test.zig");
    _ = @import("vm/vm_test.zig");

    // locus
    _ = @import("locus/src/root.zig");
}
