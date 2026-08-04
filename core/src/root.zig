test {
    _ = @import("api_test.zig");
    _ = @import("frontend/kupcad/docstring_test.zig");
    _ = @import("frontend/kupcad/lexer_test.zig");
    _ = @import("frontend/kupcad/parser_test.zig");
    _ = @import("frontend/openscad/lexer_test.zig");
    _ = @import("frontend/openscad/parser_test.zig");
    _ = @import("tools/fmt/rules/sort_imports_test.zig");
    _ = @import("tools/lint/rules/negative_dim_test.zig");
}
