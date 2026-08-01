const std = @import("std");
const testing = std.testing;
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;

// --- DRY TEST HELPERS ---
const ExpectedToken = struct {
    tag: lexer_mod.Tag,
    lexeme: []const u8,
};

fn t(tag: lexer_mod.Tag, lexeme: []const u8) ExpectedToken {
    return .{ .tag = tag, .lexeme = lexeme };
}

fn expectTokens(source: []const u8, expected: []const ExpectedToken) !void {
    var lexer = Lexer.init(source, 0);
    for (expected) |exp| {
        const tok = lexer.next();
        try testing.expectEqual(exp.tag, tok.tag);
        try testing.expectEqualStrings(exp.lexeme, tok.lexeme);
    }
}

// --- TESTS ---

test "KupCAD Lexer: Basic assignment and method chaining" {
    try expectTokens("box = Box.new(x: 50)\nbox.translate(z: 10)", &.{
        t(.ident, "box"), t(.equal, "="),         t(.constant, "Box"), t(.dot, "."),
        t(.ident, "new"), t(.l_paren, "("),       t(.ident, "x"),      t(.colon, ":"),
        t(.number, "50"), t(.r_paren, ")"),       t(.newline, "\n"),   t(.ident, "box"),
        t(.dot, "."),     t(.ident, "translate"), t(.l_paren, "("),    t(.ident, "z"),
        t(.colon, ":"),   t(.number, "10"),       t(.r_paren, ")"),    t(.eof, ""),
    });
}

test "KupCAD Lexer: Parametric annotations and comments" {
    try expectTokens(
        \\# @param width [Length] Overall box width
        \\# Standard comment
        \\width = 80.0
    , &.{
        t(.param_doc, "# @param width [Length] Overall box width"), t(.newline, "\n"),
        t(.comment, "# Standard comment"),                          t(.newline, "\n"),
        t(.ident, "width"),                                         t(.equal, "="),
        t(.number, "80.0"),                                         t(.eof, ""),
    });
}

test "KupCAD Lexer: Blocks, symbols, and CSG operators" {
    try expectTokens("box.on_face(:top) do\n  c1 + c2\nend", &.{
        t(.ident, "box"),       t(.dot, "."),     t(.ident, "on_face"), t(.l_paren, "("),
        t(.symbol, "top"),      t(.r_paren, ")"), t(.keyword_do, "do"), t(.newline, "\n"),
        t(.ident, "c1"),        t(.plus, "+"),    t(.ident, "c2"),      t(.newline, "\n"),
        t(.keyword_end, "end"), t(.eof, ""),
    });
}

test "KupCAD Lexer: Complex Parametric Component with Imports" {
    try expectTokens(
        \\import { ThreadedInsert } from "./hardware.kup"
        \\# @param width [Length] { range: 20..100 }
        \\width = 50.5
    , &.{
        t(.keyword_import, "import"), t(.l_brace, "{"),                                            t(.constant, "ThreadedInsert"),
        t(.r_brace, "}"),             t(.keyword_from, "from"),                                    t(.string, "./hardware.kup"),
        t(.newline, "\n"),            t(.param_doc, "# @param width [Length] { range: 20..100 }"), t(.newline, "\n"),
        t(.ident, "width"),           t(.equal, "="),                                              t(.number, "50.5"),
        t(.eof, ""),
    });
}

test "KupCAD Lexer: Parametric annotations with irregular spacing and casing" {
    const source =
        "#@param width [Length]\n" ++
        "#    @Param height [Length]\n" ++
        "#\t@PARAM depth [Length]\n" ++
        "#   @pAraM radius [Length]\n" ++
        "# not_a_param";

    try expectTokens(source, &.{
        t(.param_doc, "#@param width [Length]"),      t(.newline, "\n"),
        t(.param_doc, "#    @Param height [Length]"), t(.newline, "\n"),
        t(.param_doc, "#\t@PARAM depth [Length]"),    t(.newline, "\n"),
        t(.param_doc, "#   @pAraM radius [Length]"),  t(.newline, "\n"),
        t(.comment, "# not_a_param"),                 t(.eof, ""),
    });
}

test "KupCAD Lexer: Classes, definitions, and logical operators" {
    try expectTokens(
        \\class MyPart
        \\  def is_valid?
        \\    true && false || !nil
        \\  end
        \\end
    , &.{
        t(.keyword_class, "class"), t(.constant, "MyPart"), t(.newline, "\n"),
        t(.keyword_def, "def"),     t(.ident, "is_valid?"), t(.newline, "\n"),
        t(.keyword_true, "true"),   t(.and_and, "&&"),      t(.keyword_false, "false"),
        t(.or_or, "||"),            t(.bang, "!"),          t(.keyword_nil, "nil"),
    });
}

test "KupCAD Lexer: Blocks with pipes, math, and flow control" {
    try expectTokens(
        \\yield unless 10 % 3 * 2 / 1 == 0
        \\grid do |x, y|
    , &.{
        t(.keyword_yield, "yield"), t(.keyword_unless, "unless"), t(.number, "10"),
        t(.percent, "%"),           t(.number, "3"),              t(.star, "*"),
        t(.number, "2"),            t(.slash, "/"),               t(.number, "1"),
        t(.equal_equal, "=="),      t(.number, "0"),              t(.newline, "\n"),
        t(.ident, "grid"),          t(.keyword_do, "do"),         t(.pipe, "|"),
        t(.ident, "x"),             t(.comma, ","),               t(.ident, "y"),
        t(.pipe, "|"),
    });
}

test "KupCAD Lexer: Exponentiation and Special Identifiers" {
    try expectTokens(
        \\@radius = 10 ** 2
        \\$global_offset = 5.0
        \\part.slice!
    , &.{
        t(.ident, "@radius"), t(.equal, "="),    t(.number, "10"),            t(.star_star, "**"),
        t(.number, "2"),      t(.newline, "\n"), t(.ident, "$global_offset"), t(.equal, "="),
        t(.number, "5.0"),    t(.newline, "\n"), t(.ident, "part"),           t(.dot, "."),
        t(.ident, "slice!"),  t(.eof, ""),
    });
}

test "KupCAD Lexer: Arrays and Hashes" {
    try expectTokens("arr = [1, 2]\nmap = {x: 1}", &.{
        t(.ident, "arr"), t(.equal, "="),  t(.l_bracket, "["), t(.number, "1"),
        t(.comma, ","),   t(.number, "2"), t(.r_bracket, "]"), t(.newline, "\n"),
        t(.ident, "map"), t(.equal, "="),  t(.l_brace, "{"),   t(.ident, "x"),
        t(.colon, ":"),   t(.number, "1"), t(.r_brace, "}"),   t(.eof, ""),
    });
}

test "KupCAD Lexer: Line and column tracking" {
    const source = "a = 1\n  b = 2";
    var lexer = Lexer.init(source, 0);
    var tok = lexer.next(); // 'a'
    try testing.expectEqual(.ident, tok.tag);
    try testing.expectEqual(@as(u32, 1), tok.loc.line);
    try testing.expectEqual(@as(u32, 1), tok.loc.col);

    tok = lexer.next(); // '='
    try testing.expectEqual(.equal, tok.tag);
    try testing.expectEqual(@as(u32, 1), tok.loc.line);
    try testing.expectEqual(@as(u32, 3), tok.loc.col);

    tok = lexer.next(); // '1'
    try testing.expectEqual(.number, tok.tag);
    try testing.expectEqual(@as(u32, 1), tok.loc.line);
    try testing.expectEqual(@as(u32, 5), tok.loc.col);

    tok = lexer.next(); // '\n'
    try testing.expectEqual(.newline, tok.tag);
    try testing.expectEqual(@as(u32, 1), tok.loc.line);
    try testing.expectEqual(@as(u32, 6), tok.loc.col);

    tok = lexer.next(); // 'b'
    try testing.expectEqual(.ident, tok.tag);
    try testing.expectEqual(@as(u32, 2), tok.loc.line);
    try testing.expectEqual(@as(u32, 3), tok.loc.col); // skipped 2 spaces
}

test "KupCAD Lexer: Stabby Lambda" {
    try expectTokens("my_lambda = ->(x, y) { x + y }", &.{
        t(.ident, "my_lambda"), t(.equal, "="),   t(.minus_greater, "->"),
        t(.l_paren, "("),       t(.ident, "x"),   t(.comma, ","),
        t(.ident, "y"),         t(.r_paren, ")"), t(.l_brace, "{"),
        t(.ident, "x"),         t(.plus, "+"),    t(.ident, "y"),
        t(.r_brace, "}"),       t(.eof, ""),
    });
}
