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

test "OpenSCAD Lexer: Module definition and instantiation" {
    try expectTokens("module enclosure(w=50) {\n  cube([w, 20, 10]);\n}", &.{
        t(.keyword_module, "module"), t(.ident, "enclosure"), t(.l_paren, "("),
        t(.ident, "w"),               t(.equal, "="),         t(.number, "50"),
        t(.r_paren, ")"),             t(.l_brace, "{"),       t(.ident, "cube"),
        t(.l_paren, "("),             t(.l_bracket, "["),     t(.ident, "w"),
        t(.comma, ","),               t(.number, "20"),       t(.comma, ","),
        t(.number, "10"),             t(.r_bracket, "]"),     t(.r_paren, ")"),
        t(.semicolon, ";"),           t(.r_brace, "}"),       t(.eof, ""),
    });
}

test "OpenSCAD Lexer: Geometry modifiers and conditionals" {
    try expectTokens("!cylinder(h=10);\n#sphere(r=5);", &.{
        t(.bang, "!"),      t(.ident, "cylinder"), t(.l_paren, "("), t(.ident, "h"),
        t(.equal, "="),     t(.number, "10"),      t(.r_paren, ")"), t(.semicolon, ";"),
        t(.mod_debug, "#"), t(.ident, "sphere"),   t(.l_paren, "("), t(.ident, "r"),
        t(.equal, "="),     t(.number, "5"),       t(.r_paren, ")"), t(.semicolon, ";"),
        t(.eof, ""),
    });
}

test "OpenSCAD Lexer: Includes, uses, and comments" {
    try expectTokens("// standard library\ninclude <BOSL2/std.scad>\nuse <threads.scad>", &.{
        t(.comment, "// standard library"), t(.keyword_include, "include"), t(.less, "<"),
        t(.ident, "BOSL2"),                 t(.slash, "/"),                 t(.ident, "std"),
        t(.dot, "."),                       t(.ident, "scad"),              t(.greater, ">"),
        t(.keyword_use, "use"),             t(.less, "<"),                  t(.ident, "threads"),
        t(.dot, "."),                       t(.ident, "scad"),              t(.greater, ">"),
        t(.eof, ""),
    });
}

test "OpenSCAD Lexer: Block comments and booleans" {
    try expectTokens("/* Multi-line\n   comment block */\nif (w <= 10 && !false) {\n  cube(undef);\n}", &.{
        t(.block_comment, "/* Multi-line\n   comment block */"), t(.keyword_if, "if"),
        t(.l_paren, "("),                                        t(.ident, "w"),
        t(.less_equal, "<="),                                    t(.number, "10"),
        t(.and_and, "&&"),                                       t(.bang, "!"),
        t(.keyword_false, "false"),                              t(.r_paren, ")"),
        t(.l_brace, "{"),                                        t(.ident, "cube"),
        t(.l_paren, "("),                                        t(.keyword_undef, "undef"),
        t(.r_paren, ")"), t(.semicolon, ";"), // Added this back!
        t(.r_brace, "}"), t(.eof, ""),
    });
}

test "OpenSCAD Lexer: Ternary, exponentiation, and dual-use operators" {
    try expectTokens("r = (a < 5 && b >= 2) ? 10^2 : 5%2;\n*cube(r * 2);\n%sphere(r);", &.{
        t(.ident, "r"),          t(.equal, "="),      t(.l_paren, "("),  t(.ident, "a"),
        t(.less, "<"),           t(.number, "5"),     t(.and_and, "&&"), t(.ident, "b"),
        t(.greater_equal, ">="), t(.number, "2"),     t(.r_paren, ")"),  t(.question, "?"),
        t(.number, "10"),        t(.caret, "^"),      t(.number, "2"),   t(.colon, ":"),
        t(.number, "5"),         t(.percent, "%"),    t(.number, "2"),   t(.semicolon, ";"),
        t(.star, "*"),           t(.ident, "cube"),   t(.l_paren, "("),  t(.ident, "r"),
        t(.star, "*"),           t(.number, "2"),     t(.r_paren, ")"),  t(.semicolon, ";"),
        t(.percent, "%"),        t(.ident, "sphere"), t(.l_paren, "("),  t(.ident, "r"),
        t(.r_paren, ")"),        t(.semicolon, ";"),  t(.eof, ""),
    });
}

test "OpenSCAD Lexer: Let, Comprehensions, Intersection For" {
    try expectTokens("pts = [ for (x = [0:5]) x * 2 ];\nlet(a=5) cube(a);\nintersection_for(i = [1:3]) {}", &.{
        t(.ident, "pts"),       t(.equal, "="),     t(.l_bracket, "["),
        t(.keyword_for, "for"), t(.l_paren, "("),   t(.ident, "x"),
        t(.equal, "="),         t(.l_bracket, "["), t(.number, "0"),
        t(.colon, ":"),         t(.number, "5"),    t(.r_bracket, "]"),
        t(.r_paren, ")"),       t(.ident, "x"),     t(.star, "*"),
        t(.number, "2"),        t(.r_bracket, "]"), t(.semicolon, ";"),
        t(.keyword_let, "let"), t(.l_paren, "("),   t(.ident, "a"),
        t(.equal, "="),         t(.number, "5"),    t(.r_paren, ")"),
        t(.ident, "cube"),      t(.l_paren, "("),   t(.ident, "a"),
        t(.r_paren, ")"),       t(.semicolon, ";"), t(.keyword_intersection_for, "intersection_for"),
        t(.l_paren, "("),       t(.ident, "i"),     t(.equal, "="),
        t(.l_bracket, "["),     t(.number, "1"),    t(.colon, ":"),
        t(.number, "3"),        t(.r_bracket, "]"), t(.r_paren, ")"),
        t(.l_brace, "{"),       t(.r_brace, "}"),   t(.eof, ""),
    });
}

test "OpenSCAD Lexer: Special variables, ranges, and escaped strings" {
    try expectTokens("$fn = 50;\nfor(i = [0 : 2 : 10]) {\n  echo(\"Test: \\\"escaped\\\" str\");\n}", &.{
        t(.ident, "$fn"),
        t(.equal, "="),
        t(.number, "50"),
        t(.semicolon, ";"),
        t(.keyword_for, "for"),
        t(.l_paren, "("),
        t(.ident, "i"),
        t(.equal, "="),
        t(.l_bracket, "["),
        t(.number, "0"),
        t(.colon, ":"),
        t(.number, "2"),
        t(.colon, ":"),
        t(.number, "10"),
        t(.r_bracket, "]"),
        t(.r_paren, ")"),
        t(.l_brace, "{"),
        t(.keyword_echo, "echo"),
        t(.l_paren, "("),
        t(.string, "Test: \\\"escaped\\\" str"),
        t(.r_paren, ")"),
        t(.semicolon, ";"),
        t(.r_brace, "}"),
        t(.eof, ""),
    });
}

test "OpenSCAD Lexer: UTF-8 Identifiers" {
    try expectTokens("π = 3.14;\nΔx = 10;", &.{
        t(.ident, "π"),
        t(.equal, "="),
        t(.number, "3.14"),
        t(.semicolon, ";"),
        t(.ident, "Δx"),
        t(.equal, "="),
        t(.number, "10"),
        t(.semicolon, ";"),
        t(.eof, ""),
    });
}
