const std = @import("std");
const testing = std.testing;
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;
const Token = lexer_mod.Token;

// Helper function to assert token sequences
fn expectToken(lexer: *Lexer, expected_tag: Token.Tag, expected_lexeme: []const u8) !void {
    const tok = lexer.next();
    try testing.expectEqual(expected_tag, tok.tag);
    try testing.expectEqualStrings(expected_lexeme, tok.lexeme);
}

test "KupCAD Lexer: Basic assignment and method chaining" {
    const source = "box = Box.new(x: 50)\nbox.translate(z: 10)";
    var lexer = Lexer.init(source, 0);

    try expectToken(&lexer, .ident, "box");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .constant, "Box");
    try expectToken(&lexer, .dot, ".");
    try expectToken(&lexer, .ident, "new");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .ident, "x");
    try expectToken(&lexer, .colon, ":");
    try expectToken(&lexer, .number, "50");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .newline, "\\n");

    try expectToken(&lexer, .ident, "box");
    try expectToken(&lexer, .dot, ".");
    try expectToken(&lexer, .ident, "translate");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .ident, "z");
    try expectToken(&lexer, .colon, ":");
    try expectToken(&lexer, .number, "10");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .eof, "");
}

test "KupCAD Lexer: Parametric annotations and comments" {
    const source =
        \\# @param width [Length] Overall box width
        \\# Standard comment
        \\width = 80.0
    ;
    var lexer = Lexer.init(source, 0);

    try expectToken(&lexer, .param_doc, "# @param width [Length] Overall box width");
    try expectToken(&lexer, .newline, "\\n");
    try expectToken(&lexer, .comment, "# Standard comment");
    try expectToken(&lexer, .newline, "\\n");
    try expectToken(&lexer, .ident, "width");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .number, "80.0");
    try expectToken(&lexer, .eof, "");
}

test "KupCAD Lexer: Blocks, symbols, and CSG operators" {
    const source = "box.on_face(:top) do\n  c1 + c2\nend";
    var lexer = Lexer.init(source, 0);

    try expectToken(&lexer, .ident, "box");
    try expectToken(&lexer, .dot, ".");
    try expectToken(&lexer, .ident, "on_face");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .symbol, "top");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .keyword_do, "do");
    try expectToken(&lexer, .newline, "\\n");
    try expectToken(&lexer, .ident, "c1");
    try expectToken(&lexer, .plus, "+");
    try expectToken(&lexer, .ident, "c2");
    try expectToken(&lexer, .newline, "\\n");
    try expectToken(&lexer, .keyword_end, "end");
    try expectToken(&lexer, .eof, "");
}

test "KupCAD Lexer: Complex Parametric Component with Imports" {
    const source =
        \\import { ThreadedInsert } from "./hardware.kup"
        \\# @param width [Length] { range: 20..100 }
        \\width = 50.5
        \\
        \\base = Box.new(x: width).shell(2.0)
        \\base.on_face(:top) do
        \\  ThreadedInsert.new()
        \\end
    ;
    var lexer = Lexer.init(source, 0);

    // Module Import
    try expectToken(&lexer, .keyword_import, "import");
    try expectToken(&lexer, .l_brace, "{");
    try expectToken(&lexer, .constant, "ThreadedInsert");
    try expectToken(&lexer, .r_brace, "}");
    try expectToken(&lexer, .keyword_from, "from");
    try expectToken(&lexer, .string, "\"./hardware.kup\"");
    try expectToken(&lexer, .newline, "\\n");

    // Parametric Docstring & Assignment
    try expectToken(&lexer, .param_doc, "# @param width [Length] { range: 20..100 }");
    try expectToken(&lexer, .newline, "\\n");
    try expectToken(&lexer, .ident, "width");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .number, "50.5");
    try expectToken(&lexer, .newline, "\\n");
    try expectToken(&lexer, .newline, "\\n");

    // Method Chaining
    try expectToken(&lexer, .ident, "base");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .constant, "Box");
    try expectToken(&lexer, .dot, ".");
    try expectToken(&lexer, .ident, "new");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .ident, "x");
    try expectToken(&lexer, .colon, ":");
    try expectToken(&lexer, .ident, "width");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .dot, ".");
    try expectToken(&lexer, .ident, "shell");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .number, "2.0");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .newline, "\\n");

    // Workplane Block
    try expectToken(&lexer, .ident, "base");
    try expectToken(&lexer, .dot, ".");
    try expectToken(&lexer, .ident, "on_face");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .symbol, "top");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .keyword_do, "do");
    try expectToken(&lexer, .newline, "\\n");
    try expectToken(&lexer, .constant, "ThreadedInsert");
    try expectToken(&lexer, .dot, ".");
    try expectToken(&lexer, .ident, "new");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .newline, "\\n");
    try expectToken(&lexer, .keyword_end, "end");

    try expectToken(&lexer, .eof, "");
}

test "KupCAD Lexer: Parametric annotations with irregular spacing and casing" {
    const source =
        \\#@param width [Length]
        \\#    @Param height [Length]
        \\#	@PARAM depth [Length]
        \\#   @pAraM radius [Length]
        \\# not_a_param
    ;
    var lexer = Lexer.init(source, 0);

    // No space, all lowercase
    try expectToken(&lexer, .param_doc, "#@param width [Length]");
    try expectToken(&lexer, .newline, "\\n");

    // Multiple spaces, title case
    try expectToken(&lexer, .param_doc, "#    @Param height [Length]");
    try expectToken(&lexer, .newline, "\\n");

    // Tab character, all uppercase
    try expectToken(&lexer, .param_doc, "#\t@PARAM depth [Length]");
    try expectToken(&lexer, .newline, "\\n");

    // Mixed spacing, mixed casing
    try expectToken(&lexer, .param_doc, "#   @pAraM radius [Length]");
    try expectToken(&lexer, .newline, "\\n");

    // Standard comment should still be parsed as a comment
    try expectToken(&lexer, .comment, "# not_a_param");
    try expectToken(&lexer, .eof, "");
}
