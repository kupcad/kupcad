const std = @import("std");
const testing = std.testing;
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;

const test_utils = @import("../test_utils.zig");
const t = test_utils.t;

fn expectTokens(source: []const u8, expected: anytype) !void {
    return test_utils.expectTokens(Lexer, source, expected);
}

// --- TESTS ---

test "KupCAD Lexer: Basic assignment and method chaining" {
    try expectTokens("box = Box.new(x: 50)\nbox.translate(z: 10)", &.{
        t(.ident, "box"),    t(.equal, "="),
        t(.constant, "Box"), t(.dot, "."),
        t(.ident, "new"),    t(.l_paren, "("),
        t(.ident, "x"),      t(.colon, ":"),
        t(.number, "50"),    t(.r_paren, ")"),
        t(.newline, "\n"),   t(.ident, "box"),
        t(.dot, "."),        t(.ident, "translate"),
        t(.l_paren, "("),    t(.ident, "z"),
        t(.colon, ":"),      t(.number, "10"),
        t(.r_paren, ")"),    t(.eof, ""),
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

test "KupCAD Lexer: Bitwise Assignment Operators" {
    try expectTokens("a &= b\nc |= d\ne ^= f\ng <<= 1\nh >>= 2", &.{
        t(.ident, "a"), t(.ampersand_equal, "&="),        t(.ident, "b"),  t(.newline, "\n"),
        t(.ident, "c"), t(.pipe_equal, "|="),             t(.ident, "d"),  t(.newline, "\n"),
        t(.ident, "e"), t(.caret_equal, "^="),            t(.ident, "f"),  t(.newline, "\n"),
        t(.ident, "g"), t(.less_less_equal, "<<="),       t(.number, "1"), t(.newline, "\n"),
        t(.ident, "h"), t(.greater_greater_equal, ">>="), t(.number, "2"), t(.eof, ""),
    });
}

test "KupCAD Lexer: Nested String Interpolation" {
    try expectTokens("\"Outer #{ \"Inner #{1 + 2}\" } end\"", &.{
        t(.string_start, "Outer "),
        t(.string_start, "Inner "),
        t(.number, "1"),
        t(.plus, "+"),
        t(.number, "2"),
        t(.string_end, ""),
        t(.string_end, " end"),
        t(.eof, ""),
    });
}

test "KupCAD Lexer: Generalized Docstring Annotations (@return, @type, @deprecated)" {
    try expectTokens(
        \\# @return [Mesh] Outer enclosure shell
        \\# @deprecated Use Box.new instead
        \\# @type [Length] Depth offset
    , &.{
        t(.param_doc, "# @return [Mesh] Outer enclosure shell"), t(.newline, "\n"),
        t(.param_doc, "# @deprecated Use Box.new instead"),      t(.newline, "\n"),
        t(.param_doc, "# @type [Length] Depth offset"),          t(.eof, ""),
    });
}

test "KupCAD Lexer: Multi-line Indented Docstring Tag" {
    const source =
        \\# @deprecated Use {#my_new_method} instead of this method because
        \\#   it uses a library that is no longer supported.
        \\#   The new method accepts the same parameters.
        \\def mymethod
        \\end
    ;

    try expectTokens(source, &.{
        t(.param_doc,
            \\# @deprecated Use {#my_new_method} instead of this method because
            \\#   it uses a library that is no longer supported.
            \\#   The new method accepts the same parameters.
        ),
        t(.newline, "\n"),
        t(.keyword_def, "def"),
        t(.ident, "mymethod"),
        t(.newline, "\n"),
        t(.keyword_end, "end"),
        t(.eof, ""),
    });
}

test "KupCAD Lexer: Token offset and endOffset tracking for LSP" {
    // String indices:
    // 01234567890123456789012
    // let x = 100 + 50
    const source = "let x = 100 + 50";
    var lexer = Lexer.init(source, 0);

    // 'let' (length: 3)
    var tok = lexer.next();
    try testing.expectEqualStrings("let", tok.lexeme);
    try testing.expectEqual(@as(u32, 0), tok.loc.offset);
    try testing.expectEqual(@as(u32, 3), tok.endOffset());

    // 'x' (length: 1, skips 1 space)
    tok = lexer.next();
    try testing.expectEqualStrings("x", tok.lexeme);
    try testing.expectEqual(@as(u32, 4), tok.loc.offset);
    try testing.expectEqual(@as(u32, 5), tok.endOffset());

    // '=' (length: 1, skips 1 space)
    tok = lexer.next();
    try testing.expectEqualStrings("=", tok.lexeme);
    try testing.expectEqual(@as(u32, 6), tok.loc.offset);
    try testing.expectEqual(@as(u32, 7), tok.endOffset());

    // '100' (length: 3, skips 1 space)
    tok = lexer.next();
    try testing.expectEqualStrings("100", tok.lexeme);
    try testing.expectEqual(@as(u32, 8), tok.loc.offset);
    try testing.expectEqual(@as(u32, 11), tok.endOffset());

    // '+' (length: 1, skips 1 space)
    tok = lexer.next();
    try testing.expectEqualStrings("+", tok.lexeme);
    try testing.expectEqual(@as(u32, 12), tok.loc.offset);
    try testing.expectEqual(@as(u32, 13), tok.endOffset());

    // '50' (length: 2, skips 1 space)
    tok = lexer.next();
    try testing.expectEqualStrings("50", tok.lexeme);
    try testing.expectEqual(@as(u32, 14), tok.loc.offset);
    try testing.expectEqual(@as(u32, 16), tok.endOffset());

    // EOF
    tok = lexer.next();
    try testing.expectEqual(.eof, tok.tag);
    try testing.expectEqual(@as(u32, 16), tok.loc.offset);
    try testing.expectEqual(@as(u32, 16), tok.endOffset());
}

test "KupCAD Lexer: Exhaustive Location tracking (line, col, offset, length, file_id)" {
    // String indices mapped out for clarity:
    // 01234 5 6789012
    // a = 1 \n   b = 2
    const source = "a = 1\n  b = 2";

    // We pass a unique file_id (e.g., 42) to verify it propagates to every token
    var lexer = Lexer.init(source, 42);

    // 1. 'a'
    var tok = lexer.next();
    try testing.expectEqual(.ident, tok.tag);
    try testing.expectEqualStrings("a", tok.lexeme);
    try testing.expectEqual(@as(u32, 1), tok.loc.line);
    try testing.expectEqual(@as(u32, 1), tok.loc.col);
    try testing.expectEqual(@as(u32, 0), tok.loc.offset);
    try testing.expectEqual(@as(u32, 0), tok.loc.length); // Unpopulated by Lexer (expected)
    try testing.expectEqual(@as(u32, 42), tok.loc.file_id); // File ID propagates perfectly
    try testing.expectEqual(@as(u32, 1), tok.endOffset()); // offset(0) + len(1)

    // 2. '='
    tok = lexer.next();
    try testing.expectEqual(.equal, tok.tag);
    try testing.expectEqualStrings("=", tok.lexeme);
    try testing.expectEqual(@as(u32, 1), tok.loc.line);
    try testing.expectEqual(@as(u32, 3), tok.loc.col);
    try testing.expectEqual(@as(u32, 2), tok.loc.offset);
    try testing.expectEqual(@as(u32, 3), tok.endOffset());

    // 3. '1'
    tok = lexer.next();
    try testing.expectEqual(.number, tok.tag);
    try testing.expectEqualStrings("1", tok.lexeme);
    try testing.expectEqual(@as(u32, 1), tok.loc.line);
    try testing.expectEqual(@as(u32, 5), tok.loc.col);
    try testing.expectEqual(@as(u32, 4), tok.loc.offset);
    try testing.expectEqual(@as(u32, 5), tok.endOffset());

    // 4. '\n' (Newline triggers line/col resets for the NEXT token)
    tok = lexer.next();
    try testing.expectEqual(.newline, tok.tag);
    try testing.expectEqualStrings("\n", tok.lexeme);
    try testing.expectEqual(@as(u32, 1), tok.loc.line); // Belongs to the end of line 1
    try testing.expectEqual(@as(u32, 6), tok.loc.col);
    try testing.expectEqual(@as(u32, 5), tok.loc.offset);
    try testing.expectEqual(@as(u32, 6), tok.endOffset());

    // 5. 'b' (Skips 2 spaces of indentation on line 2)
    tok = lexer.next();
    try testing.expectEqual(.ident, tok.tag);
    try testing.expectEqualStrings("b", tok.lexeme);
    try testing.expectEqual(@as(u32, 2), tok.loc.line); // Successfully jumped to Line 2
    try testing.expectEqual(@as(u32, 3), tok.loc.col); // Col 3 (after 2 spaces)
    try testing.expectEqual(@as(u32, 8), tok.loc.offset); // Byte 8 overall
    try testing.expectEqual(@as(u32, 9), tok.endOffset());

    // 6. '='
    tok = lexer.next();
    try testing.expectEqual(.equal, tok.tag);
    try testing.expectEqualStrings("=", tok.lexeme);
    try testing.expectEqual(@as(u32, 2), tok.loc.line);
    try testing.expectEqual(@as(u32, 5), tok.loc.col);
    try testing.expectEqual(@as(u32, 10), tok.loc.offset);
    try testing.expectEqual(@as(u32, 11), tok.endOffset());

    // 7. '2'
    tok = lexer.next();
    try testing.expectEqual(.number, tok.tag);
    try testing.expectEqualStrings("2", tok.lexeme);
    try testing.expectEqual(@as(u32, 2), tok.loc.line);
    try testing.expectEqual(@as(u32, 7), tok.loc.col);
    try testing.expectEqual(@as(u32, 12), tok.loc.offset);
    try testing.expectEqual(@as(u32, 13), tok.endOffset());

    // 8. EOF
    tok = lexer.next();
    try testing.expectEqual(.eof, tok.tag);
    try testing.expectEqual(@as(u32, 2), tok.loc.line);
    try testing.expectEqual(@as(u32, 8), tok.loc.col);
    try testing.expectEqual(@as(u32, 13), tok.loc.offset);
}

test "KupCAD Lexer: Hash label vs Symbol ambiguity without spaces" {
    try expectTokens("opts = {a: 1, b: b, c:c, d: :sym}", &.{
        t(.ident, "opts"), t(.equal, "="), t(.l_brace, "{"),
        t(.ident, "a"),    t(.colon, ":"), t(.number, "1"),
        t(.comma, ","),    t(.ident, "b"), t(.colon, ":"),
        t(.ident, "b"),    t(.comma, ","), t(.ident, "c"),
        t(.colon, ":"),    t(.ident, "c"), t(.comma, ","),
        t(.ident, "d"),    t(.colon, ":"), t(.symbol, "sym"),
        t(.r_brace, "}"),  t(.eof, ""),
    });
}

test "KupCAD Lexer: Deeply Nested String Interpolation gracefully fails" {
    // 9 levels deep (exceeds the [8]u32 stack size)
    const source = "\"#{ \"#{ \"#{ \"#{ \"#{ \"#{ \"#{ \"#{ \"#{ \"deep\" }\" }\" }\" }\" }\" }\" }\" }\" }\"";
    var lexer = Lexer.init(source, 0);

    var has_invalid = false;
    while (true) {
        const tok = lexer.next();
        if (tok.tag == .eof) break;
        if (tok.tag == .invalid) {
            has_invalid = true;
            try testing.expectEqualStrings("Interpolation depth exceeded", tok.lexeme);
            break;
        }
    }

    try testing.expect(has_invalid);
}

test "KupCAD Lexer: EOF handling for unclosed strings and interpolations" {
    // Unclosed standard string
    var lexer1 = Lexer.init("\"unclosed string...", 0);
    // Because it never finds the closing quote, consumeStringBody safely hits
    // the end of the buffer and returns .eof
    try testing.expectEqual(.eof, lexer1.next().tag);

    // Unclosed string interpolation
    var lexer2 = Lexer.init("\"start #{ 1 + ", 0);
    const tok1 = lexer2.next();
    try testing.expectEqual(.string_start, tok1.tag);
    try testing.expectEqualStrings("start ", tok1.lexeme);

    try testing.expectEqual(.number, lexer2.next().tag);
    try testing.expectEqual(.plus, lexer2.next().tag);

    // The interpolation was never closed with `}` and hits EOF safely
    try testing.expectEqual(.eof, lexer2.next().tag);
}

test "KupCAD Lexer: Hexadecimal, Octal, Binary, and Underscore Floats" {
    try expectTokens("a = 0xFF + 0b1010 + 0o77\nb = 1_000_000.5e-3", &.{
        t(.ident, "a"),       t(.equal, "="), t(.number, "0xFF"),           t(.plus, "+"),
        t(.number, "0b1010"), t(.plus, "+"),  t(.number, "0o77"),           t(.newline, "\n"),
        t(.ident, "b"),       t(.equal, "="), t(.number, "1_000_000.5e-3"), t(.eof, ""),
    });
}

test "KupCAD Lexer: Whitespace between method names and parentheses" {
    try expectTokens("foo ()", &.{
        t(.ident, "foo"), t(.l_paren, "("), t(.r_paren, ")"), t(.eof, ""),
    });
}

test "KupCAD Lexer: UTF-8 Identifiers (Math Variables)" {
    try expectTokens("π = 3.14159\nΔx = 10\nθ_angle = 90", &.{
        t(.ident, "π"),
        t(.equal, "="),
        t(.number, "3.14159"),
        t(.newline, "\n"),
        t(.ident, "Δx"),
        t(.equal, "="),
        t(.number, "10"),
        t(.newline, "\n"),
        t(.ident, "θ_angle"),
        t(.equal, "="),
        t(.number, "90"),
        t(.eof, ""),
    });
}

test "KupCAD Lexer: UTF-8 Identifier Column Tracking" {
    // String indices:
    // 01 2 34 5 67 8 9
    // Δx = 10 \n π = 5
    const source = "Δx = 10\nπ = 5";
    var lexer = Lexer.init(source, 0);

    // 'Δx' (length: 2 characters, 3 bytes)
    var tok = lexer.next();
    try testing.expectEqualStrings("Δx", tok.lexeme);
    try testing.expectEqual(@as(u32, 1), tok.loc.col);
    try testing.expectEqual(@as(u32, 0), tok.loc.offset);

    // '='
    tok = lexer.next();
    try testing.expectEqualStrings("=", tok.lexeme);
    try testing.expectEqual(@as(u32, 4), tok.loc.col); // Should be 4, as Δ (col 1) + x (col 2) + space (col 3)

    // '10'
    _ = lexer.next();
    // '\n'
    _ = lexer.next();

    // 'π'
    tok = lexer.next();
    try testing.expectEqualStrings("π", tok.lexeme);
    try testing.expectEqual(@as(u32, 2), tok.loc.line);
    try testing.expectEqual(@as(u32, 1), tok.loc.col);
}
