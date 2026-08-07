pub const api = @import("api.zig");
pub const registry = @import("core/registry.zig");

pub const formatCode = api.formatCode;
pub const checkCode = api.checkCode;
pub const FormatterConfig = api.FormatterConfig;
pub const LinterConfig = api.LinterConfig;
pub const LinterDiagnostic = api.LinterDiagnostic;
pub const LineIndex = api.LineIndex;

test {
    _ = @import("api_test.zig");
    _ = @import("gen_grammar_test.zig");
    _ = @import("core/ast_test.zig");
    _ = @import("core/line_index_test.zig");
    _ = @import("frontend/kupcad/docstring_test.zig");
    _ = @import("frontend/kupcad/lexer_test.zig");
    _ = @import("frontend/kupcad/parser_test.zig");
    _ = @import("frontend/openscad/lexer_test.zig");
    // _ = @import("frontend/openscad/parser_test.zig");

    // CLI & Config Tests
    _ = @import("cli/config_test.zig");
    _ = @import("cli/options_test.zig");
    _ = @import("cli/walker_test.zig");

    // Formatter Tests
    _ = @import("tools/fmt/formatter_test.zig");
    _ = @import("tools/fmt/rules/sort_imports_test.zig");

    // Linter Tests
    _ = @import("tools/lint/linter_test.zig");
    _ = @import("tools/lint/rules/negative_dim_test.zig");
    _ = @import("tools/lint/rules/unused_vars_test.zig");
    _ = @import("tools/lint/rules/unreachable_code_test.zig");
    _ = @import("tools/lint/rules/self_subtraction_test.zig");
    _ = @import("tools/lint/rules/param_docs_test.zig");
}
