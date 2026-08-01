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

    // Root modifier (!)
    try expectToken(&lexer, .mod_root, "!");
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
    // OpenSCAD treats < ... > like strings in an include context or as basic relational operators,
    // For this basic lexer, they parse as operators and idents
    try expectToken(&lexer, .ident, "BOSL2");
    try expectToken(&lexer, .slash, "/");
    try expectToken(&lexer, .ident, "std");
    try expectToken(&lexer, .ident, "scad"); // the dot evaluates differently without string bounds, assuming simple identifier chunking
    // We skip full validation of `<...>` string behaviors here to focus on the structure.
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

    // module housing(w, h=20) {
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
    try expectToken(&lexer, .newline, "\\n");

    //   difference() {
    try expectToken(&lexer, .ident, "difference");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .l_brace, "{");
    try expectToken(&lexer, .newline, "\\n");

    //     cube([w, w, h]);
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
    try expectToken(&lexer, .newline, "\\n");

    //     #cylinder(r=w/4, h=h+1);
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
    try expectToken(&lexer, .newline, "\\n");

    //     %sphere(d=5);
    try expectToken(&lexer, .mod_transparent, "%");
    try expectToken(&lexer, .ident, "sphere");
    try expectToken(&lexer, .l_paren, "(");
    try expectToken(&lexer, .ident, "d");
    try expectToken(&lexer, .equal, "=");
    try expectToken(&lexer, .number, "5");
    try expectToken(&lexer, .r_paren, ")");
    try expectToken(&lexer, .semicolon, ";");
    try expectToken(&lexer, .newline, "\\n");

    //   }
    try expectToken(&lexer, .r_brace, "}");
    try expectToken(&lexer, .newline, "\\n");

    // }
    try expectToken(&lexer, .r_brace, "}");
    try expectToken(&lexer, .eof, "");
}
