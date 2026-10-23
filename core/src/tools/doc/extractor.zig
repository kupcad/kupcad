//! `extractSchema`: reads a script's `@title`, `@description` and `@author` comments and
//! its `param` calls into a `UiSchema` without running it (`kupcad doc`, through api.zig).

const std = @import("std");
const ast = @import("../../core/ast.zig");
const Document = @import("../../frontend/document.zig").Document;
const visitor = @import("../../core/visitor.zig");

pub const PresentationMeta = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    author: ?[]const u8 = null,
};

/// What `param` accepts under `validate:` (stdlib/params.zig), and nothing else: the
/// schema used to carry `ui` and `validate.step`, which param refuses as unknown keywords.
pub const ParamValidate = struct {
    min: ?f64 = null,
    max: ?f64 = null,
    /// The allowed values, when the script lists them as literals; null when there is no
    /// list or it holds something only the run can compute (shown short, it would mislead).
    in: ?[]const std.json.Value = null,
};

pub const ParamMetadata = struct {
    name: []const u8,
    type: []const u8,
    default_value: ?std.json.Value,
    validate: ParamValidate,
};

pub const UiSchema = struct {
    meta: PresentationMeta,
    parameters: []ParamMetadata,
};

pub fn extractSchema(allocator: std.mem.Allocator, doc: *const Document, source: []const u8) !UiSchema {
    var schema = UiSchema{
        .meta = .{},
        .parameters = &.{},
    };

    // Extract Presentation Metadata from Source Comments
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (!std.mem.startsWith(u8, trimmed, "#")) continue;
        const content = std.mem.trim(u8, trimmed[1..], " \r\t");

        if (std.mem.startsWith(u8, content, "@title")) {
            schema.meta.title = std.mem.trim(u8, content[6..], " \t");
        } else if (std.mem.startsWith(u8, content, "@description")) {
            schema.meta.description = std.mem.trim(u8, content[12..], " \t");
        } else if (std.mem.startsWith(u8, content, "@author")) {
            schema.meta.author = std.mem.trim(u8, content[7..], " \t");
        }
    }

    const ParamVisitor = struct {
        allocator: std.mem.Allocator,
        params: *std.ArrayList(ParamMetadata),

        pub fn enterNode(self: *@This(), tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
            const node = tree.getNode(node_idx) orelse return;
            if (node.tag == .method_call) {
                const mc = tree.methodCall(node);
                const method_name = tree.getString(mc.method_name);
                if (std.mem.eql(u8, method_name, "param")) {
                    if (try extractParam(self.allocator, tree, mc)) |p| {
                        try self.params.append(self.allocator, p);
                    }
                }
            }
        }
    };

    var params: std.ArrayList(ParamMetadata) = .empty;
    defer params.deinit(allocator);

    // Walk the entire AST deeply instead of just checking the root block
    var vis = ParamVisitor{
        .allocator = allocator,
        .params = &params,
    };
    try visitor.walk(ParamVisitor, &vis, &doc.tree, doc.tree.root);

    schema.parameters = try params.toOwnedSlice(allocator);
    return schema;
}

fn extractParam(allocator: std.mem.Allocator, tree: *const ast.Tree, mc: ast.MethodCall) !?ParamMetadata {
    const args = tree.getNamedArgs(mc.args);
    if (args.len == 0) return null;

    const is_setter = args.len > 1 or (args.len > 0 and args[0].name != .none);
    if (!is_setter) return null;

    const p_name = extractString(tree, args[0].value) orelse "unknown";

    var def_val: ?std.json.Value = null;
    var p_type: []const u8 = "number";
    var val = ParamValidate{};

    for (args) |arg| {
        if (arg.name == .none) continue;
        const kw_name = tree.getString(arg.name);

        if (std.mem.eql(u8, kw_name, "default")) {
            def_val = extractJsonValue(tree, arg.value);
            if (def_val) |dv| {
                switch (dv) {
                    .float, .integer => p_type = "number",
                    .string => p_type = "string",
                    .bool => p_type = "boolean",
                    else => {},
                }
            }
        } else if (std.mem.eql(u8, kw_name, "validate")) {
            val = try extractValidate(allocator, tree, arg.value);
        }
    }

    return ParamMetadata{
        .name = p_name,
        .type = p_type,
        .default_value = def_val,
        .validate = val,
    };
}

fn extractValidate(allocator: std.mem.Allocator, tree: *const ast.Tree, node_idx: ast.NodeIndex) !ParamValidate {
    var val = ParamValidate{};
    const node = tree.getNode(node_idx) orelse return val;
    if (node.tag != .hash_literal) return val;

    const entries = tree.getHashEntries(tree.nodeSpan(node));
    for (entries) |entry| {
        const key = extractString(tree, entry.key) orelse continue;
        if (std.mem.eql(u8, key, "min")) {
            val.min = extractNumber(tree, entry.value);
        } else if (std.mem.eql(u8, key, "max")) {
            val.max = extractNumber(tree, entry.value);
        } else if (std.mem.eql(u8, key, "in")) {
            val.in = try extractChoices(allocator, tree, entry.value);
        }
    }
    return val;
}

/// The literal values of an `in:` list; null for anything else, or for a list with an
/// element that isn't a literal.
fn extractChoices(allocator: std.mem.Allocator, tree: *const ast.Tree, node_idx: ast.NodeIndex) !?[]const std.json.Value {
    const node = tree.getNode(node_idx) orelse return null;
    if (node.tag != .array_literal) return null;
    const elements = tree.getNodes(tree.arrayLiteral(node).span);
    const choices = try allocator.alloc(std.json.Value, elements.len);
    for (elements, choices) |e, *c| c.* = extractJsonValue(tree, e) orelse return null;
    return choices;
}

fn extractString(tree: *const ast.Tree, node_idx: ast.NodeIndex) ?[]const u8 {
    const node = tree.getNode(node_idx) orelse return null;
    switch (node.tag) {
        .string, .symbol, .identifier => return tree.nodeString(node),
        else => return null,
    }
}

fn extractNumber(tree: *const ast.Tree, node_idx: ast.NodeIndex) ?f64 {
    const node = tree.getNode(node_idx) orelse return null;
    if (node.tag == .number) return tree.number(node);

    if (node.tag == .unary_op) {
        const un = tree.unaryExpr(node);
        if (un.op == .negate) {
            const inner = tree.getNode(un.operand) orelse return null;
            if (inner.tag == .number) return -tree.number(inner);
        }
    }
    return null;
}

fn extractJsonValue(tree: *const ast.Tree, node_idx: ast.NodeIndex) ?std.json.Value {
    const node = tree.getNode(node_idx) orelse return null;
    switch (node.tag) {
        .number => return .{ .float = tree.number(node) },
        .boolean => return .{ .bool = tree.boolean(node) },
        .string, .symbol => return .{ .string = tree.nodeString(node) },
        .unary_op => {
            const un = tree.unaryExpr(node);
            if (un.op == .negate) {
                const inner = tree.getNode(un.operand) orelse return null;
                if (inner.tag == .number) return .{ .float = -tree.number(inner) };
            }
            return null;
        },
        else => return null,
    }
}
