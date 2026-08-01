const std = @import("std");
const testing = std.testing;
const lexer_mod = @import("lexer.zig");
const Lexer = lexer_mod.Lexer;

// Helper function to assert token sequences
fn expectToken(lexer: *Lexer, expected_tag: lexer_mod.Tag, expected_lexeme: []const u8) !void {
    const tok = lexer.next();
    try testing.expectEqual(expected_tag, tok.tag);
    try testing.expectEqualStrings(expected_lexeme, tok.lexeme);
}

test "OpenSCAD Lexer: Module definition and instantiation" {
    const source = "module enclosure(w=50) {\n  cube([w, 20, 10]);\n}";
    var lexer = Lexer.init(source, 0);

    try expectToken(&lexer, .keyword_module, "module");
    try expectToken(&lexer, .ident, "enclosure");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .ident, "w");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .number, "50");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .l_brace, "{");
    try expectToken(&lexer, .ident, "cube");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .l_bracket, "[");
    try expectToken(&lexer, .ident, "w");
    try expectToken(&lexer, .comma, ",");
    try expectToken(&lexer, .number, "20");
    try expectToken(&lexer, .comma, ",");
    try expectToken(&lexer, .number, "10");
    try expectToken(&lexer, .r_bracket, "]");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .semicolon, ";");
    try expectToken(&lexer, .r_brace, "}");
    try expectToken(&lexer, .eof, "");
}

test "OpenSCAD Lexer: Geometry modifiers and conditionals" {
    const source = "!cylinder(h=10);\n#sphere(r=5);";
    var lexer = Lexer.init(source, 0);

    // Root modifier (!) is now parsed as bang, parser will distinguish
    try expectToken(&lexer, .bang, "!");
    try expectToken(&lexer, .ident, "cylinder");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .ident, "h");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .number, "10");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .semicolon, ";");

    // Debug modifier (#)
    try expectToken(&lexer, .mod_debug, "#");
    try expectToken(&lexer, .ident, "sphere");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .ident, "r");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .number, "5");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .semicolon, ";");
    try expectToken(&lexer, .eof, "");
}

test "OpenSCAD Lexer: Includes, uses, and comments" {
    const source = "// standard library\ninclude <BOSL2/std.scad>\nuse <threads.scad>";
    var lexer = Lexer.init(source, 0);

    try expectToken(&lexer, .comment, "// standard library");
    try expectToken(&lexer, .keyword_include, "include");
    // OpenSCAD treats < ... > like strings in an include context or as basic relational operators
    try expectToken(&lexer, .less, "<");
    try expectToken(&lexer, .ident, "BOSL2");
    try expectToken(&lexer, .slash, "/");
    try expectToken(&lexer, .ident, "std");
    try expectToken(&lexer, .dot, ".");
    try expectToken(&lexer, .ident, "scad");
    try expectToken(&lexer, .greater, ">");
}

test "OpenSCAD Lexer: Nested Modules, Arrays, Math, and Modifiers" {
    const source =
        \\module housing(w, h=20) {
        \\  difference() {
        \\    cube([w, w, h]);
        \\    #cylinder(r=w/4, h=h+1);
        \\    %sphere(d=5);
        \\  }
        \\}
    ;
    var lexer = Lexer.init(source, 0);

    try expectToken(&lexer, .keyword_module, "module");
    try expectToken(&lexer, .ident, "housing");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .ident, "w");
    try expectToken(&lexer, .comma, ",");
    try expectToken(&lexer, .ident, "h");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .number, "20");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .l_brace, "{");

    try expectToken(&lexer, .ident, "difference");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .l_brace, "{");

    try expectToken(&lexer, .ident, "cube");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .l_bracket, "[");
    try expectToken(&lexer, .ident, "w");
    try expectToken(&lexer, .comma, ",");
    try expectToken(&lexer, .ident, "w");
    try expectToken(&lexer, .comma, ",");
    try expectToken(&lexer, .ident, "h");
    try expectToken(&lexer, .r_bracket, "]");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .semicolon, ";");

    try expectToken(&lexer, .mod_debug, "#");
    try expectToken(&lexer, .ident, "cylinder");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .ident, "r");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .ident, "w");
    try expectToken(&lexer, .slash, "/");
    try expectToken(&lexer, .number, "4");
    try expectToken(&lexer, .comma, ",");
    try expectToken(&lexer, .ident, "h");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .ident, "h");
    try expectToken(&lexer, .plus, "+");
    try expectToken(&lexer, .number, "1");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .semicolon, ";");

    try expectToken(&lexer, .percent, "%");
    try expectToken(&lexer, .ident, "sphere");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .ident, "d");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .number, "5");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .semicolon, ";");

    try expectToken(&lexer, .r_brace, "}");
    try expectToken(&lexer, .r_brace, "}");
    try expectToken(&lexer, .eof, "");
}

test "OpenSCAD Lexer: Block comments and booleans" {
    const source =
        \\/* Multi-line
        \\   comment block */
        \\if (w <= 10 && !false) {
        \\  cube(undef);
        \\}
    ;
    var lexer = Lexer.init(source, 0);

    try expectToken(&lexer, .block_comment, "/* Multi-line\n   comment block */");
    try expectToken(&lexer, .keyword_if, "if");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .ident, "w");
    try expectToken(&lexer, .less_equal, "<=");
    try expectToken(&lexer, .number, "10");
    try expectToken(&lexer, .and_and, "&&");
    try expectToken(&lexer, .bang, "!");
    try expectToken(&lexer, .keyword_false, "false");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .l_brace, "{");
    try expectToken(&lexer, .ident, "cube");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .keyword_undef, "undef");
    try expectToken(&lexer, .r_paren, ")");
}

test "OpenSCAD Lexer: Ternary, exponentiation, and dual-use operators" {
    const source =
        \\r = (a < 5 && b >= 2) ? 10^2 : 5%2;
        \\*cube(r * 2);
        \\%sphere(r);
    ;
    var lexer = Lexer.init(source, 0);

    try expectToken(&lexer, .ident, "r");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .ident, "a");
    try expectToken(&lexer, .less, "<");
    try expectToken(&lexer, .number, "5");
    try expectToken(&lexer, .and_and, "&&");
    try expectToken(&lexer, .ident, "b");
    try expectToken(&lexer, .greater_equal, ">=");
    try expectToken(&lexer, .number, "2");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .question, "?");
    try expectToken(&lexer, .number, "10");
    try expectToken(&lexer, .caret, "^");
    try expectToken(&lexer, .number, "2");
    try expectToken(&lexer, .colon, ":");
    try expectToken(&lexer, .number, "5");
    try expectToken(&lexer, .percent, "%");
    try expectToken(&lexer, .number, "2");
    try expectToken(&lexer, .semicolon, ";");

    try expectToken(&lexer, .star, "*");
    try expectToken(&lexer, .ident, "cube");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .ident, "r");
    try expectToken(&lexer, .star, "*");
    try expectToken(&lexer, .number, "2");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .semicolon, ";");

    try expectToken(&lexer, .percent, "%");
    try expectToken(&lexer, .ident, "sphere");
}

test "OpenSCAD Lexer: Special variables, ranges, and escaped strings" {
    const source =
        \\$fn = 50;
        \\for(i = [0 : 2 : 10]) {
        \\  echo("Test: \"escaped\" str");
        \\}
    ;
    var lexer = Lexer.init(source, 0);

    try expectToken(&lexer, .ident, "$fn");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .number, "50");
    try expectToken(&lexer, .semicolon, ";");

    try expectToken(&lexer, .keyword_for, "for");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .ident, "i");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .l_bracket, "[");
    try expectToken(&lexer, .number, "0");
    try expectToken(&lexer, .colon, ":");
    try expectToken(&lexer, .number, "2");
    try expectToken(&lexer, .colon, ":");
    try expectToken(&lexer, .number, "10");
    try expectToken(&lexer, .r_bracket, "]");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .l_brace, "{");

    try expectToken(&lexer, .ident, "echo");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .string, "Test: \\\"escaped\\\" str");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .semicolon, ";");

    try expectToken(&lexer, .r_brace, "}");
    try expectToken(&lexer, .eof, "");
}
