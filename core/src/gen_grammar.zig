//! Generates the grammars highlighting follows the language by (`zig build grammar`): the VS
//! Code TextMate grammar (`generateTextMateJson`) and the words of `@kupcad/editor`'s CodeMirror
//! highlighting (`generateVocabularyJson`). Both take the keywords from the lexer and the
//! function and method names from the stdlib manifest and classes (`Vocabulary`); `main` writes
//! them to the paths given.

const std = @import("std");
const kupcad_lexer = @import("frontend/lexer.zig");
const manifest = @import("stdlib/manifest.zig");
const array_class = @import("stdlib/classes/array.zig");
const map_class = @import("stdlib/classes/map.zig");
const string_class = @import("stdlib/classes/string.zig");
const number_class = @import("stdlib/classes/number.zig");
const symbol_class = @import("stdlib/classes/symbol.zig");
const boolean_class = @import("stdlib/classes/boolean.zig");
const math_class = @import("stdlib/classes/math.zig");
const object_class = @import("stdlib/classes/object.zig");
const gc_class = @import("stdlib/classes/gc.zig");
const cad_class = @import("stdlib/classes/cad.zig");
const bbox_class = @import("stdlib/classes/bbox.zig");
const font_class = @import("stdlib/classes/font.zig");
const json_object_class = @import("stdlib/classes/json_object.zig");
const range_class = @import("stdlib/classes/range.zig");
const random_class = @import("stdlib/classes/random.zig");
const log_helpers = @import("log.zig");

/// `for`, the loop variables (up to a comment), then the first standalone `in`.
pub const FOR_IN_MATCH = "\\b(for)\\b([^#\\n]*?)\\b(in)\\b";
/// The characters a regex reads as more than themselves: a name's `?` (`empty?`) among them.
const REGEX_SPECIALS = "\\^$.|?*+()[]{}";

/// The language's words, each kind highlighting tells apart: the lexer's keywords, the stdlib's
/// global functions and methods by their category, and the methods of its classes. The lists
/// borrow the names, which are the program's; `deinit` frees the lists.
pub const Vocabulary = struct {
    keywords: std.ArrayList([]const u8) = .empty,
    /// Every global function, whatever its category, and the language's intrinsics (`raise`).
    functions: std.ArrayList([]const u8) = .empty,
    builtins: std.ArrayList([]const u8) = .empty,
    prim_3d: std.ArrayList([]const u8) = .empty,
    prim_2d: std.ArrayList([]const u8) = .empty,
    /// Every method of a Solid, a Sketch, a Path or an Assembly, whatever its category.
    mesh_methods: std.ArrayList([]const u8) = .empty,
    transforms: std.ArrayList([]const u8) = .empty,
    csg_ops: std.ArrayList([]const u8) = .empty,
    inspections: std.ArrayList([]const u8) = .empty,
    /// The methods of the classes (Object, Array, Map, String, CAD, Math, ...).
    core_methods: std.ArrayList([]const u8) = .empty,

    pub fn collect(allocator: std.mem.Allocator) !Vocabulary {
        var words: Vocabulary = .{};
        errdefer words.deinit(allocator);
        for (kupcad_lexer.keywords.keys()) |key| try words.keywords.append(allocator, key);
        for (manifest.global_functions) |gf| {
            try words.functions.append(allocator, gf.name);
            switch (gf.category) {
                .primitive_3d => try words.prim_3d.append(allocator, gf.name),
                .primitive_2d => try words.prim_2d.append(allocator, gf.name),
                .io, .file_io => try words.builtins.append(allocator, gf.name),
                else => {},
            }
        }
        for (manifest.language_intrinsics) |intrinsic| {
            const name = intrinsic[0];
            // `yield` is a keyword; `params` the parameters' map, not a call
            if (kupcad_lexer.keywords.has(name) or intrinsic[1] == .protected_symbol) continue;
            try words.functions.append(allocator, name);
        }
        for (manifest.mesh_methods) |mm| {
            try words.mesh_methods.append(allocator, mm.name);
            switch (mm.category) {
                .transform => try words.transforms.append(allocator, mm.name),
                .csg_operator => try words.csg_ops.append(allocator, mm.name),
                .inspection_method => try words.inspections.append(allocator, mm.name),
                else => {},
            }
        }
        for (manifest.path_methods ++ manifest.assembly_methods) |mm| try words.mesh_methods.append(allocator, mm.name);
        inline for (.{ object_class, array_class, map_class, string_class, number_class, symbol_class, boolean_class, math_class, gc_class, cad_class, bbox_class, font_class, json_object_class, range_class, random_class }) |class| {
            for (class.methods) |m| try words.core_methods.append(allocator, m.name);
        }
        return words;
    }

    pub fn deinit(self: *Vocabulary, allocator: std.mem.Allocator) void {
        inline for (comptime @typeInfo(Vocabulary).@"struct".field_names) |name| @field(self, name).deinit(allocator);
    }
};

/// The words `@kupcad/editor` highlights by (its `src/vocabulary.json`): the keywords, the global
/// functions, and the methods (a Solid's or a value's), each list sorted, each word once.
pub fn generateVocabularyJson(allocator: std.mem.Allocator) ![]const u8 {
    var words = try Vocabulary.collect(allocator);
    defer words.deinit(allocator);
    var methods: std.ArrayList([]const u8) = .empty;
    defer methods.deinit(allocator);
    try methods.appendSlice(allocator, words.mesh_methods.items);
    try methods.appendSlice(allocator, words.core_methods.items);
    const vocabulary = .{
        .keywords = sortedOnce(&words.keywords),
        .functions = sortedOnce(&words.functions),
        .methods = sortedOnce(&methods),
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{f}\n", .{std.json.fmt(vocabulary, .{ .whitespace = .indent_2 })});
    return try allocator.dupe(u8, out.written());
}

/// `list`'s words sorted, each once (in place: the slice is the list's).
fn sortedOnce(list: *std.ArrayList([]const u8)) []const []const u8 {
    std.mem.sortUnstable([]const u8, list.items, {}, lessThan);
    var kept: usize = 0;
    for (list.items) |word| {
        if (kept > 0 and std.mem.eql(u8, list.items[kept - 1], word)) continue;
        list.items[kept] = word;
        kept += 1;
    }
    list.shrinkRetainingCapacity(kept);
    return list.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The TextMate grammar of the VS Code extension (`syntaxes/kupcad.tmLanguage.json`).
pub fn generateTextMateJson(allocator: std.mem.Allocator) ![]const u8 {
    var words = try Vocabulary.collect(allocator);
    defer words.deinit(allocator);
    // The matches live as long as the grammar is written
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const matches = arena.allocator();
    // A keyword after a `.` is a method's name
    const kw_match = try wordsMatch(matches, &words.keywords, ".");
    const builtins_match = try wordsMatch(matches, &words.builtins, "");
    const p3d_match = try wordsMatch(matches, &words.prim_3d, "");
    const p2d_match = try wordsMatch(matches, &words.prim_2d, "");
    const tf_match = try wordsMatch(matches, &words.transforms, "");
    const csg_match = try wordsMatch(matches, &words.csg_ops, "");
    const insp_match = try wordsMatch(matches, &words.inspections, "");
    const core_match = try wordsMatch(matches, &words.core_methods, "");

    // Define the grammar using anonymous list literals (tuples) for arrays
    const grammar = .{
        .name = "KupCAD",
        .scopeName = "source.kupcad",
        .patterns = .{
            .{ .include = "#docstring" },
            .{ .include = "#comments" },
            .{ .include = "#strings" },
            .{ .include = "#single_quoted_strings" },
            .{ .include = "#method_declarations" },
            .{ .include = "#hash_keys" },
            .{ .include = "#block_parameters" },
            .{ .include = "#symbols" },
            .{ .include = "#instance_vars" },
            .{ .include = "#global_vars" },
            .{ .include = "#constants" },
            .{ .include = "#method_calls" },
            .{ .include = "#for_in" },
            .{ .include = "#keywords" },
            .{ .include = "#builtins" },
            .{ .include = "#core_methods" },
            .{ .include = "#primitives_3d" },
            .{ .include = "#primitives_2d" },
            .{ .include = "#transforms" },
            .{ .include = "#csg_operators" },
            .{ .include = "#inspections" },
            .{ .include = "#numbers" },
            .{ .include = "#operators" },
        },
        .repository = .{
            .docstring = .{
                .match = "^\\s*(#\\s*@[a-zA-Z_]+)(.*)$",
                .captures = .{
                    .@"1" = .{ .name = "keyword.control.directive.kupcad" },
                    .@"2" = .{ .name = "comment.block.documentation.kupcad" },
                },
            },
            .comments = .{
                .match = "#.*$",
                .name = "comment.line.number-sign.kupcad",
            },
            .strings = .{
                .begin = "\"",
                .end = "\"",
                .name = "string.quoted.double.kupcad",
                .patterns = .{
                    // A whole \u{1F600} or \u00e9, or a backslash and the character after it
                    .{ .match = "\\\\(?:u\\{[0-9A-Fa-f]{1,6}\\}|u[0-9A-Fa-f]{4}|.)", .name = "constant.character.escape.kupcad" },
                    .{
                        .begin = "#\\{",
                        .end = "\\}",
                        .name = "meta.embedded.line.kupcad",
                        .patterns = .{
                            .{ .include = "$self" },
                        },
                    },
                },
            },
            // Only \\ and \' are escapes in single quotes, and nothing is interpolated.
            .single_quoted_strings = .{
                .begin = "'",
                .end = "'",
                .name = "string.quoted.single.kupcad",
                .patterns = .{
                    .{ .match = "\\\\['\\\\]", .name = "constant.character.escape.kupcad" },
                },
            },
            .symbols = .{
                .match = "(?<!:):[a-zA-Z_]\\w*[!?]?",
                .name = "constant.language.symbol.kupcad",
            },
            .numbers = .{
                .match = "\\b(0[xX][a-fA-F0-9_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*(\\.[0-9_]+)?([eE][-+]?[0-9_]+)?)\\b",
                .name = "constant.numeric.kupcad",
            },
            .instance_vars = .{
                .match = "(@)[a-zA-Z_]\\w*",
                .name = "variable.other.readwrite.instance.kupcad",
            },
            .global_vars = .{
                .match = "(\\$)[a-zA-Z_]\\w*",
                .name = "variable.other.readwrite.global.kupcad",
            },
            .constants = .{
                .match = "\\b[A-Z]\\w*\\b",
                .name = "entity.name.type.class.kupcad",
            },
            .operators = .{
                .patterns = .{
                    .{ .match = "(&\\.)", .name = "keyword.operator.safe-navigation.kupcad" },
                    .{ .match = "(<<=|>>=|\\*\\*=|\\+=|-=|\\*=|/=|%=|&=|\\|=|\\^=|&&=\\|\\|=)", .name = "keyword.operator.assignment.augmented.kupcad" },
                    .{ .match = "(==|!=|<=|>=|<|>|<=>|===)", .name = "keyword.operator.comparison.kupcad" },
                    .{ .match = "(&&|\\|\\||!)", .name = "keyword.operator.logical.kupcad" },
                    .{ .match = "(\\+|-|\\*|/|%|\\*\\*|&|\\||\\^|<<|>>)", .name = "keyword.operator.arithmetic.kupcad" },
                    .{ .match = "=", .name = "keyword.operator.assignment.kupcad" },
                },
            },
            .method_calls = .{
                .match = "([a-zA-Z_]\\w*[!?]?)(\\()",
                .captures = .{
                    .@"1" = .{ .name = "entity.name.function.kupcad" },
                },
            },
            // `in` is a keyword only in `for x in xs` (the lexer reads it as a name, so `in:`
            // stays a label), so it is highlighted there and nowhere else.
            .for_in = .{
                .match = FOR_IN_MATCH,
                .captures = .{
                    .@"1" = .{ .name = "keyword.control.kupcad" },
                    .@"3" = .{ .name = "keyword.control.kupcad" },
                },
            },
            .keywords = .{
                .match = kw_match,
                .name = "keyword.control.kupcad",
            },
            .builtins = .{
                .match = builtins_match,
                .name = "support.function.builtin.kupcad",
            },
            .core_methods = .{
                .match = core_match,
                .name = "support.function.core.kupcad",
            },
            .primitives_3d = .{
                .match = p3d_match,
                .name = "support.class.primitive.3d.kupcad",
            },
            .primitives_2d = .{
                .match = p2d_match,
                .name = "support.class.primitive.2d.kupcad",
            },
            .transforms = .{
                .match = tf_match,
                .name = "support.function.transform.kupcad",
            },
            .csg_operators = .{
                .match = csg_match,
                .name = "support.function.csg.kupcad",
            },
            .inspections = .{
                .match = insp_match,
                .name = "support.function.inspection.kupcad",
            },
            .hash_keys = .{
                .match = "\\b([a-zA-Z_]\\w*[!?]?)(:)(?!:)",
                .captures = .{
                    .@"1" = .{ .name = "constant.language.symbol.hashkey.kupcad" },
                    .@"2" = .{ .name = "punctuation.separator.key-value.kupcad" },
                },
            },
            .method_declarations = .{
                .match = "(?:^|\\s)(def)\\s+([a-zA-Z_]\\w*[!?]?)",
                .captures = .{
                    .@"1" = .{ .name = "keyword.control.def.kupcad" },
                    .@"2" = .{ .name = "entity.name.function.kupcad" },
                },
            },
            .block_parameters = .{
                .begin = "(?<=\\bdo\\b|\\{)\\s*(\\|)",
                .beginCaptures = .{
                    .@"1" = .{ .name = "punctuation.separator.variable.kupcad" },
                },
                .end = "(\\|)",
                .endCaptures = .{
                    .@"1" = .{ .name = "punctuation.separator.variable.kupcad" },
                },
                .name = "meta.block.parameters.kupcad",
                .patterns = .{
                    .{ .match = "[a-zA-Z_]\\w*", .name = "variable.parameter.block.kupcad" },
                    .{ .match = ",", .name = "punctuation.separator.object.kupcad" },
                },
            },
        },
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{std.json.fmt(grammar, .{ .whitespace = .indent_2 })});
    return try allocator.dupe(u8, out.written());
}

/// A TextMate match for any of `list`'s words (sorted, each once), whole: no word character,
/// `?` or `!` follows it, and none of `not_after`'s characters nor a word character comes
/// before it. Each word is matched as written: `empty?`'s `?` is the character, not "optional".
/// error.EmptyWordList for no words: an empty group would match everywhere.
fn wordsMatch(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), comptime not_after: []const u8) ![]const u8 {
    if (list.items.len == 0) return error.EmptyWordList;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    // `\w` once: escaped again (`\\w`), the class was a backslash and a `w`, so `for` was
    // matched in `platform` and `do` in `standoff`
    try out.writer.writeAll("(?<![\\w" ++ not_after ++ "])(");
    for (sortedOnce(list), 0..) |word, i| {
        if (i > 0) try out.writer.writeByte('|');
        for (word) |c| {
            if (std.mem.findScalar(u8, REGEX_SPECIALS, c) != null) try out.writer.writeByte('\\');
            try out.writer.writeByte(c);
        }
    }
    try out.writer.writeAll(")(?![\\w?!])");
    return out.toOwnedSlice();
}

/// Writes the TextMate grammar to the first path given, and the editor's vocabulary to the second.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.skip(); // skip executable name
    const grammar_path = args_iter.next();
    const vocabulary_path = args_iter.next();
    if (grammar_path == null or vocabulary_path == null) {
        log_helpers.printStderr(io, "Usage: gen_grammar <tmLanguage.json> <vocabulary.json>\n", .{});
        std.process.exit(1);
    }

    const grammar = try generateTextMateJson(allocator);
    defer allocator.free(grammar);
    const vocabulary = try generateVocabularyJson(allocator);
    defer allocator.free(vocabulary);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = grammar_path.?, .data = grammar });
    try cwd.writeFile(io, .{ .sub_path = vocabulary_path.?, .data = vocabulary });
    log_helpers.printStdout(io, "Wrote the TextMate grammar to {s} and the editor's vocabulary to {s}\n", .{ grammar_path.?, vocabulary_path.? });
}
