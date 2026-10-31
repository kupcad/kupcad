//! Fonts a script imports (`import label from "./Inter.ttf"`): a Font named as the font names
//! itself, which `text(font:)` draws with, kerned; files that aren't fonts text can draw with
//! are ImportErrors naming them.

const support = @import("../test_support.zig");
const rescued = support.rescued;

/// The fonts scripts/make-test-fonts.py makes: units of 1000 to the em, so a glyph's advance
/// of 600 is 6 mm at text's default size of 10. A V follows an A 100 units closer in both.
const FILES = [_]support.ScriptFile{
    .{ .path = "fonts/Test.otf", .data = @embedFile("../core/test_fonts/gpos-kerning.otf") },
    .{ .path = "fonts/Test.ttf", .data = @embedFile("../core/test_fonts/kern-table.ttf") },
    .{ .path = "fonts/unnamed.ttf", .data = @embedFile("../core/test_fonts/unnamed.ttf") },
    .{ .path = "fonts/no-cmap.ttf", .data = @embedFile("../core/test_fonts/no-cmap.ttf") },
    .{ .path = "fonts/no-outlines.ttf", .data = @embedFile("../core/test_fonts/no-outlines.ttf") },
    .{ .path = "fonts/scan.bin", .data = @embedFile("../core/test_fonts/gpos-kerning.otf") },
    .{ .path = "fonts/broken.ttf", .data = "not a font" },
    // A font made a module's export, as a project's shared label font would be
    .{ .path = "labels.kup", .data = "import brand from \"./fonts/Test.otf\"\nexport brand\n" },
};

fn withFiles(src: []const u8, expected: support.Expected) support.ScriptCase {
    return .{ .src = src, .expected = expected, .files = &FILES };
}

test "Font: an imported font is named as it names itself, in puts, interpolation and inspect" {
    try support.expectScripts(&.{
        withFiles("import f from \"./fonts/Test.otf\"\nr = [f.name, \"#{f}\", f.inspect, \"#{f.class}\"].inspect", .{ .str = "[\"KupCAD Test CFF Regular\", \"KupCAD Test CFF Regular\", \"#<Font KupCAD Test CFF Regular>\", \"Font\"]" }),
        // A font that names itself nowhere is named after its file
        withFiles("import f from \"./fonts/unnamed.ttf\"\nr = f.name", .{ .str = "unnamed.ttf" }),
        // `with { type: "font" }` for a file whose name doesn't say it is one
        withFiles("import f from \"./fonts/scan.bin\" with { type: \"font\" }\nr = f.name", .{ .str = "KupCAD Test CFF Regular" }),
        withFiles("import { brand } from \"./labels.kup\"\nr = brand.name", .{ .str = "KupCAD Test CFF Regular" }),
        withFiles("import f from \"./fonts/Test.ttf\"\nr = case f\nwhen Font then \"a Font\"\nelse \"other\"\nend", .{ .str = "a Font" }),
        // Its name and its bytes are allocated apart, each kept while the other is
        .{ .src = "import f from \"./fonts/Test.otf\"\nr = text(\"AV\", font: f).bbox.size[0]", .expected = .{ .num = 11 }, .files = &FILES, .gc_stress = true },
    });
}

test "Font: text draws with an imported font, kerned by GPOS or by its kern table" {
    // "AV" is A's advance, less the pair's 100 units, then V's 600-unit width: 11 mm, not 12
    try support.expectScripts(&.{
        withFiles("import f from \"./fonts/Test.otf\"\nr = text(\"AV\", font: f).bbox.size[0]", .{ .num = 11 }),
        withFiles("import f from \"./fonts/Test.ttf\"\nr = text(\"AV\", font: f).bbox.size[0]", .{ .num = 11 }),
        // The o's counter is a hole: a solid of the outer square less the inner
        withFiles("import f from \"./fonts/Test.otf\"\nr = text(\"o\", font: f).extrude(1).volume", .{ .num = 4 * 5 - 2 * 3 }),
    });
}

test "Font: a symbol an imported font lacks comes from the symbol font" {
    try support.expectScripts(&.{
        withFiles("import f from \"./fonts/Test.otf\"\nr = text(\"A⌀\", font: f).extrude(1).volume > text(\"A\", font: f).extrude(1).volume", .{ .boolean = true }),
    });
}

test "Font: a file text can't draw with, a missing glyph and a wrong font are errors naming them" {
    try support.expectScripts(&.{
        withFiles(rescued("import f from \"./fonts/broken.ttf\""), .{ .str = "ImportError: 'fonts/broken.ttf' isn't a font text can draw with: it isn't a TrueType or OpenType font" }),
        withFiles(rescued("import f from \"./fonts/missing.ttf\""), .{ .str = "ImportError: could not read font file 'fonts/missing.ttf': FileNotFound" }),
        // A font, but not one text can draw: nothing to draw, or no character to find
        withFiles(rescued("import f from \"./fonts/no-outlines.ttf\""), .{ .str = "ImportError: 'fonts/no-outlines.ttf' isn't a font text can draw with: it has no outlines (TrueType or CFF ones; a variable CFF2 font's and a bitmap font's aren't read)" }),
        withFiles(rescued("import f from \"./fonts/no-cmap.ttf\""), .{ .str = "ImportError: 'fonts/no-cmap.ttf' isn't a font text can draw with: it maps no characters to glyphs (it has no cmap table)" }),
        withFiles(rescued("import f from \"./fonts/Test.otf\"\ntext(\"x\", font: f)"), .{ .str = "ValueError: text: neither the font 'KupCAD Test CFF Regular' nor the symbol font has a glyph for 'x' (U+0078)" }),
        withFiles(rescued("text(\"A\", font: 5)"), .{ .str = "TypeError: text: font is the name of a font (\"sans\", \"sans-bold\", \"mono\", \"serif\" and \"stencil\") or a Font imported from a font file, got Number" }),
    });
}
