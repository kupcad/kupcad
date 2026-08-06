const std = @import("std");
const registry = @import("core/registry.zig");

/// Core generation logic separated for testing
pub fn generateTextMateJson(allocator: std.mem.Allocator, tokens: []const registry.TokenMeta) ![]const u8 {
    var keywords: std.ArrayListUnmanaged([]const u8) = .empty;
    var prim_3d: std.ArrayListUnmanaged([]const u8) = .empty;
    var prim_2d: std.ArrayListUnmanaged([]const u8) = .empty;
    var transforms: std.ArrayListUnmanaged([]const u8) = .empty;
    var csg_ops: std.ArrayListUnmanaged([]const u8) = .empty;
    var workplanes: std.ArrayListUnmanaged([]const u8) = .empty;
    var inspections: std.ArrayListUnmanaged([]const u8) = .empty;

    defer {
        keywords.deinit(allocator);
        prim_3d.deinit(allocator);
        prim_2d.deinit(allocator);
        transforms.deinit(allocator);
        csg_ops.deinit(allocator);
        workplanes.deinit(allocator);
        inspections.deinit(allocator);
    }

    // Group tokens by category
    for (tokens) |token| {
        switch (token.category) {
            .keyword => try keywords.append(allocator, token.name),
            .primitive_3d => try prim_3d.append(allocator, token.name),
            .primitive_2d => try prim_2d.append(allocator, token.name),
            .transform => try transforms.append(allocator, token.name),
            .csg_operator => try csg_ops.append(allocator, token.name),
            .workplane_method => try workplanes.append(allocator, token.name),
            .inspection_method => try inspections.append(allocator, token.name),
        }
    }

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

    // Helper function to create the \b(word|word)\b regex
    const makeKeywordMatch = struct {
        fn apply(alloc: std.mem.Allocator, joined: []const u8) ![]const u8 {
            return std.fmt.allocPrint(alloc, "(?<![\\\\w.])({s})(?![\\\\w?!])", .{joined});
        }
    }.apply;

    // For methods/primitives: DO match after a dot, but not after a word char
    const makeMethodMatch = struct {
        fn apply(alloc: std.mem.Allocator, joined: []const u8) ![]const u8 {
            return std.fmt.allocPrint(alloc, "(?<![\\\\w])({s})(?![\\\\w?!])", .{joined});
        }
    }.apply;

    const kw_match = try makeKeywordMatch(allocator, joined_kw);

    // Primitives and methods use the method matcher
    const p3d_match = try makeMethodMatch(allocator, joined_p3d);
    const p2d_match = try makeMethodMatch(allocator, joined_p2d);
    const tf_match = try makeMethodMatch(allocator, joined_tf);
    const csg_match = try makeMethodMatch(allocator, joined_csg);
    const wp_match = try makeMethodMatch(allocator, joined_wp);
    const insp_match = try makeMethodMatch(allocator, joined_insp);

    defer allocator.free(kw_match);
    defer allocator.free(p3d_match);
    defer allocator.free(p2d_match);
    defer allocator.free(tf_match);
    defer allocator.free(csg_match);
    defer allocator.free(wp_match);
    defer allocator.free(insp_match);

    // Define the grammar using anonymous list literals (tuples) for arrays
    const grammar = .{
        .name = "KupCAD",
        .scopeName = "source.kupcad",
        .patterns = .{
            .{ .include = "#param_docs" },
            .{ .include = "#comments" },
            .{ .include = "#strings" },
            .{ .include = "#symbols" },
            .{ .include = "#instance_vars" },
            .{ .include = "#global_vars" },
            .{ .include = "#constants" },
            .{ .include = "#method_calls" },
            .{ .include = "#keywords" },
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
            .param_docs = .{
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
            // Handles hex (0x), binary (0b), octal (0o), floats (1.5e3), and underscores (100_000)
            .numbers = .{
                .match = "\\b(0[xX][a-fA-F0-9_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*(\\.[0-9_]+)?([eE][-+]?[0-9_]+)?)\\b",
                .name = "constant.numeric.kupcad",
            },
            // Instance Variables (@var)
            .instance_vars = .{
                .match = "(@)[a-zA-Z_]\\w*",
                .name = "variable.other.readwrite.instance.kupcad",
            },
            // Global Variables ($var)
            .global_vars = .{
                .match = "(\\$)[a-zA-Z_]\\w*",
                .name = "variable.other.readwrite.global.kupcad",
            },
            // Constants and Classes (Starts with Capital Letter)
            .constants = .{
                .match = "\\b[A-Z]\\w*\\b",
                .name = "entity.name.type.class.kupcad",
            },
            // Operators and Safe Navigation
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
            // Generic Method Calls (e.g. `my_method(x)`)
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
        },
    };

    // Serialize to JSON with pretty formatting
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print("{f}", .{std.json.fmt(grammar, .{ .whitespace = .indent_2 })});

    // Duplicate the written slice so the caller owns the memory
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

    const json_content = try generateTextMateJson(allocator, &registry.LANGUAGE_TOKENS);
    defer allocator.free(json_content);

    const cwd = std.Io.Dir.cwd();

    try cwd.writeFile(io, .{
        .sub_path = output_path,
        .data = json_content,
    });

    std.debug.print("Successfully generated TextMate grammar at: {s}\n", .{output_path});
}
