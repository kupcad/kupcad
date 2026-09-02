const std = @import("std");
const kupcad_lexer = @import("frontend/kupcad/lexer.zig");
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

/// Core generation logic separated for testing
pub fn generateTextMateJson(allocator: std.mem.Allocator) ![]const u8 {
    var keywords: std.ArrayListUnmanaged([]const u8) = .empty;
    var builtins: std.ArrayListUnmanaged([]const u8) = .empty;
    var prim_3d: std.ArrayListUnmanaged([]const u8) = .empty;
    var prim_2d: std.ArrayListUnmanaged([]const u8) = .empty;
    var transforms: std.ArrayListUnmanaged([]const u8) = .empty;
    var csg_ops: std.ArrayListUnmanaged([]const u8) = .empty;
    var workplanes: std.ArrayListUnmanaged([]const u8) = .empty;
    var inspections: std.ArrayListUnmanaged([]const u8) = .empty;
    var core_methods: std.ArrayListUnmanaged([]const u8) = .empty;

    defer {
        keywords.deinit(allocator);
        builtins.deinit(allocator);
        prim_3d.deinit(allocator);
        prim_2d.deinit(allocator);
        transforms.deinit(allocator);
        csg_ops.deinit(allocator);
        workplanes.deinit(allocator);
        inspections.deinit(allocator);
        core_methods.deinit(allocator);
    }

    // Extract Keywords directly from the actual frontend Lexer
    for (kupcad_lexer.keywords.keys()) |key| {
        try keywords.append(allocator, key);
    }

    // Extract Native Functions from the actual Stdlib Manifest
    for (manifest.global_functions) |gf| {
        switch (gf.category) {
            .primitive_3d => try prim_3d.append(allocator, gf.name),
            .primitive_2d => try prim_2d.append(allocator, gf.name),
            .io, .file_io => try builtins.append(allocator, gf.name),
            else => {},
        }
    }

    // Extract Methods from the actual Stdlib Manifest
    for (manifest.mesh_methods) |mm| {
        switch (mm.category) {
            .transform => try transforms.append(allocator, mm.name),
            .csg_operator => try csg_ops.append(allocator, mm.name),
            .workplane_method => try workplanes.append(allocator, mm.name),
            .inspection_method => try inspections.append(allocator, mm.name),
            else => {},
        }
    }

    // Dynamically extract all Primitive Class methods
    for (object_class.methods) |m| try core_methods.append(allocator, m.name);
    for (array_class.methods) |m| try core_methods.append(allocator, m.name);
    for (map_class.methods) |m| try core_methods.append(allocator, m.name);
    for (string_class.methods) |m| try core_methods.append(allocator, m.name);
    for (number_class.methods) |m| try core_methods.append(allocator, m.name);
    for (symbol_class.methods) |m| try core_methods.append(allocator, m.name);
    for (boolean_class.methods) |m| try core_methods.append(allocator, m.name);
    for (math_class.methods) |m| try core_methods.append(allocator, m.name);
    for (gc_class.methods) |m| try core_methods.append(allocator, m.name);

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

    // Helper to safely fallback, join, and wrap categories into TextMate Regex format
    // Helper to safely fallback, deduplicate, join, and wrap categories into TextMate Regex format
    const buildMethodRegex = struct {
        fn apply(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), dummy: []const u8) ![]const u8 {
            if (list.items.len == 0) try list.append(alloc, dummy);

            // Deduplicate the list using a StringHashMap as a Set
            var seen = std.StringHashMap(void).init(alloc);
            defer seen.deinit();

            var unique_list = std.ArrayListUnmanaged([]const u8).empty;
            defer unique_list.deinit(alloc);

            for (list.items) |item| {
                if (!seen.contains(item)) {
                    try seen.put(item, {});
                    try unique_list.append(alloc, item);
                }
            }

            const joined = try std.mem.join(alloc, "|", unique_list.items);
            defer alloc.free(joined);
            return std.fmt.allocPrint(alloc, "(?<![\\\\w])({s})(?![\\\\w?!])", .{joined});
        }
    }.apply;

    // Build Keyword Matcher (Keywords use a slightly different regex constraint)
    const kw_joined = try std.mem.join(allocator, "|", keywords.items);
    defer allocator.free(kw_joined);
    const kw_match = try std.fmt.allocPrint(allocator, "(?<![\\\\w.])({s})(?![\\\\w?!])", .{kw_joined});
    defer allocator.free(kw_match);

    // Build Method Matchers using the consolidated helper
    const builtins_match = try buildMethodRegex(allocator, &builtins, "dummy_builtin");
    const p3d_match = try buildMethodRegex(allocator, &prim_3d, "dummy_prim_3d");
    const p2d_match = try buildMethodRegex(allocator, &prim_2d, "dummy_prim_2d");
    const tf_match = try buildMethodRegex(allocator, &transforms, "dummy_tf");
    const csg_match = try buildMethodRegex(allocator, &csg_ops, "dummy_csg");
    const wp_match = try buildMethodRegex(allocator, &workplanes, "dummy_wp");
    const insp_match = try buildMethodRegex(allocator, &inspections, "dummy_insp");
    const core_match = try buildMethodRegex(allocator, &core_methods, "dummy_core");

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
            .{ .include = "#method_declarations" },
            .{ .include = "#hash_keys" },
            .{ .include = "#block_parameters" },
            .{ .include = "#symbols" },
            .{ .include = "#instance_vars" },
            .{ .include = "#global_vars" },
            .{ .include = "#constants" },
            .{ .include = "#method_calls" },
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
                    .{ .match = "\\\\.", .name = "constant.character.escape.kupcad" },
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

/// CLI Entry Point
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.skip(); // skip executable name

    const output_path = args_iter.next() orelse {
        std.debug.print("Error: Missing output file path argument.\n", .{});
        std.process.exit(1);
    };

    // Automatically parse our live system
    const json_content = try generateTextMateJson(allocator);
    defer allocator.free(json_content);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{
        .sub_path = output_path,
        .data = json_content,
    });

    std.debug.print("Successfully generated TextMate grammar at: {s}\n", .{output_path});
}
