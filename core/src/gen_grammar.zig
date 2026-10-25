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
const log_helpers = @import("log.zig");

/// `for`, the loop variables (up to a comment), then the first standalone `in`.
pub const FOR_IN_MATCH = "\\b(for)\\b([^#\\n]*?)\\b(in)\\b";

/// The language's words, each kind highlighting tells apart: the lexer's keywords, the stdlib's
/// global functions and methods by their category, and the methods of its classes. The lists
/// borrow the names, which are the program's; `deinit` frees the lists.
pub const Vocabulary = struct {
    keywords: std.ArrayList([]const u8) = .empty,
    /// Every global function, whatever its category.
    functions: std.ArrayList([]const u8) = .empty,
    builtins: std.ArrayList([]const u8) = .empty,
    prim_3d: std.ArrayList([]const u8) = .empty,
    prim_2d: std.ArrayList([]const u8) = .empty,
    /// Every method of a Solid or a Sketch, whatever its category.
    mesh_methods: std.ArrayList([]const u8) = .empty,
    transforms: std.ArrayList([]const u8) = .empty,
    csg_ops: std.ArrayList([]const u8) = .empty,
    workplanes: std.ArrayList([]const u8) = .empty,
    inspections: std.ArrayList([]const u8) = .empty,
    /// The methods of the value classes (Object, Array, Map, String, ...).
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
        for (manifest.mesh_methods) |mm| {
            try words.mesh_methods.append(allocator, mm.name);
            switch (mm.category) {
                .transform => try words.transforms.append(allocator, mm.name),
                .csg_operator => try words.csg_ops.append(allocator, mm.name),
                .workplane_method => try words.workplanes.append(allocator, mm.name),
                .inspection_method => try words.inspections.append(allocator, mm.name),
                else => {},
            }
        }
        inline for (.{ object_class, array_class, map_class, string_class, number_class, symbol_class, boolean_class, math_class, gc_class }) |class| {
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
    const keywords = &words.keywords;
    const builtins = &words.builtins;
    const prim_3d = &words.prim_3d;
    const prim_2d = &words.prim_2d;
    const transforms = &words.transforms;
    const csg_ops = &words.csg_ops;
    const workplanes = &words.workplanes;
    const inspections = &words.inspections;
    const core_methods = &words.core_methods;

    // Supply dummy fallbacks if a list is empty to avoid crashing the TextMate Regex engine
    if (builtins.items.len == 0) try builtins.append(allocator, "dummy_builtin");
    if (prim_3d.items.len == 0) try prim_3d.append(allocator, "dummy_prim_3d");
    if (prim_2d.items.len == 0) try prim_2d.append(allocator, "dummy_prim_2d");
    if (csg_ops.items.len == 0) try csg_ops.append(allocator, "dummy_csg_op");
    if (workplanes.items.len == 0) try workplanes.append(allocator, "dummy_wp");
    if (inspections.items.len == 0) try inspections.append(allocator, "dummy_insp");
    if (core_methods.items.len == 0) try core_methods.append(allocator, "dummy_core");

    // Join into OR groups (e.g., "box|cylinder|sphere")
    const joined_kw = try std.mem.join(allocator, "|", keywords.items);
    const joined_p3d = try std.mem.join(allocator, "|", prim_3d.items);
    const joined_p2d = try std.mem.join(allocator, "|", prim_2d.items);
    const joined_tf = try std.mem.join(allocator, "|", transforms.items);
    const joined_csg = try std.mem.join(allocator, "|", csg_ops.items);
    const joined_wp = try std.mem.join(allocator, "|", workplanes.items);
    const joined_insp = try std.mem.join(allocator, "|", inspections.items);
    defer allocator.free(joined_kw);
    defer allocator.free(joined_p3d);
    defer allocator.free(joined_p2d);
    defer allocator.free(joined_tf);
    defer allocator.free(joined_csg);
    defer allocator.free(joined_wp);
    defer allocator.free(joined_insp);

    // Helper to safely fallback, deduplicate, join, and wrap categories into TextMate Regex format
    const buildMethodRegex = struct {
        fn apply(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8), dummy: []const u8) ![]const u8 {
            if (list.items.len == 0) try list.append(alloc, dummy);

            // Deduplicate the list using a StringHashMap as a Set
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(alloc);

            var unique_list = std.ArrayList([]const u8).empty;
            defer unique_list.deinit(alloc);

            for (list.items) |item| {
                if (!seen.contains(item)) {
                    try seen.put(alloc, item, {});
                    try unique_list.append(alloc, item);
                }
            }

            const joined = try std.mem.join(alloc, "|", unique_list.items);
            defer alloc.free(joined);
            return alloc.print("(?<![\\\\w])({s})(?![\\\\w?!])", .{joined});
        }
    }.apply;

    // Build Keyword Matcher (Keywords use a slightly different regex constraint)
    const kw_joined = try std.mem.join(allocator, "|", keywords.items);
    defer allocator.free(kw_joined);
    const kw_match = try allocator.print("(?<![\\\\w.])({s})(?![\\\\w?!])", .{kw_joined});
    defer allocator.free(kw_match);

    // Build Method Matchers using the consolidated helper
    const builtins_match = try buildMethodRegex(allocator, builtins, "dummy_builtin");
    const p3d_match = try buildMethodRegex(allocator, prim_3d, "dummy_prim_3d");
    const p2d_match = try buildMethodRegex(allocator, prim_2d, "dummy_prim_2d");
    const tf_match = try buildMethodRegex(allocator, transforms, "dummy_tf");
    const csg_match = try buildMethodRegex(allocator, csg_ops, "dummy_csg");
    const wp_match = try buildMethodRegex(allocator, workplanes, "dummy_wp");
    const insp_match = try buildMethodRegex(allocator, inspections, "dummy_insp");
    const core_match = try buildMethodRegex(allocator, core_methods, "dummy_core");

    defer allocator.free(builtins_match);
    defer allocator.free(p3d_match);
    defer allocator.free(p2d_match);
    defer allocator.free(tf_match);
    defer allocator.free(csg_match);
    defer allocator.free(wp_match);
    defer allocator.free(insp_match);
    defer allocator.free(core_match);

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
            .{ .include = "#workplanes" },
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
            .workplanes = .{
                .match = wp_match,
                .name = "support.function.workplane.kupcad",
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
