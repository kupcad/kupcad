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
    /// "number", "string" (a Symbol parameter's too), "boolean" or "array": `type:`'s, else
    /// its literal default's, else its choices', else "string" (one with no default is text
    /// until a host gives it some). A default only the run computes is taken for a number.
    type: []const u8,
    /// Null when there is none (or nil), or the run computes it.
    default_value: ?std.json.Value,
    validate: ParamValidate,
    /// A number control's increment, `step:`, when written as a literal.
    step: ?f64 = null,
    /// What a number is measured in, `unit:` ("mm", "deg").
    unit: ?[]const u8 = null,
    /// The heading a control goes under, `group:`.
    group: ?[]const u8 = null,
    /// What a control is labelled, `title:`; a host shows the name where there is none.
    title: ?[]const u8 = null,
    /// What a host shows with the control, `description:`.
    description: ?[]const u8 = null,
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
    var computed_default = false;
    var named_type: ?[]const u8 = null;
    var val = ParamValidate{};
    var step: ?f64 = null;
    var unit: ?[]const u8 = null;
    var group: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var description: ?[]const u8 = null;

    for (args) |arg| {
        if (arg.name == .none) continue;
        const kw_name = tree.getString(arg.name);

        if (std.mem.eql(u8, kw_name, "default")) {
            def_val = try extractJsonValue(allocator, tree, arg.value);
            computed_default = def_val == null;
        } else if (std.mem.eql(u8, kw_name, "type")) {
            named_type = schemaType(extractText(tree, arg.value) orelse "");
        } else if (std.mem.eql(u8, kw_name, "validate")) {
            val = try extractValidate(allocator, tree, arg.value);
        } else if (std.mem.eql(u8, kw_name, "step")) {
            step = extractNumber(tree, arg.value);
        } else if (std.mem.eql(u8, kw_name, "unit")) {
            unit = extractText(tree, arg.value);
        } else if (std.mem.eql(u8, kw_name, "group")) {
            group = extractText(tree, arg.value);
        } else if (std.mem.eql(u8, kw_name, "title")) {
            title = extractText(tree, arg.value);
        } else if (std.mem.eql(u8, kw_name, "description")) {
            description = extractText(tree, arg.value);
        }
    }

    const computed: ?[]const u8 = if (computed_default) "number" else null;
    const p_type = named_type orelse
        (if (def_val) |dv| jsonType(dv) else null) orelse
        computed orelse
        sharedJsonType(val.in orelse &.{}) orelse
        "string";
    return ParamMetadata{
        .name = p_name,
        .type = p_type,
        .default_value = def_val,
        .validate = val,
        .step = step,
        .unit = unit,
        .group = group,
        .title = title,
        .description = description,
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
    for (elements, choices) |e, *c| c.* = try extractJsonValue(allocator, tree, e) orelse return null;
    return choices;
}

fn extractString(tree: *const ast.Tree, node_idx: ast.NodeIndex) ?[]const u8 {
    const node = tree.getNode(node_idx) orelse return null;
    switch (node.tag) {
        .string, .symbol, .identifier => return tree.nodeString(node),
        else => return null,
    }
}

/// A String or Symbol literal's text; null for anything only the run can compute.
fn extractText(tree: *const ast.Tree, node_idx: ast.NodeIndex) ?[]const u8 {
    const node = tree.getNode(node_idx) orelse return null;
    return switch (node.tag) {
        .string, .symbol => tree.nodeString(node),
        else => null,
    };
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

/// A literal's value as JSON: a number, a String's or a Symbol's text, true or false, nil, or
/// an Array of them; null for what only the run can compute.
fn extractJsonValue(allocator: std.mem.Allocator, tree: *const ast.Tree, node_idx: ast.NodeIndex) !?std.json.Value {
    const node = tree.getNode(node_idx) orelse return null;
    switch (node.tag) {
        .number => return .{ .float = tree.number(node) },
        .boolean => return .{ .bool = tree.boolean(node) },
        .string, .symbol => return .{ .string = tree.nodeString(node) },
        .nil => return .null,
        .array_literal => {
            const elements = tree.getNodes(tree.arrayLiteral(node).span);
            var items: std.json.Array = try .initCapacity(allocator, elements.len);
            for (elements) |e| items.appendAssumeCapacity(try extractJsonValue(allocator, tree, e) orelse return null);
            return .{ .array = items };
        },
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

/// The schema's type of a `type:` (`:symbol` is a "string" with choices); null for a name no
/// parameter type has, which the run refuses.
fn schemaType(name: []const u8) ?[]const u8 {
    for ([_][]const u8{ "number", "string", "boolean", "array" }) |known| {
        if (std.mem.eql(u8, name, known)) return known;
    }
    return if (std.mem.eql(u8, name, "symbol")) "string" else null;
}

/// The schema's type of a literal default; null for nil, which gives none.
fn jsonType(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .float, .integer => "number",
        .string => "string",
        .bool => "boolean",
        .array => "array",
        else => null,
    };
}

/// The type all of `values` share; null when there are none, or they differ.
fn sharedJsonType(values: []const std.json.Value) ?[]const u8 {
    if (values.len == 0) return null;
    const first = jsonType(values[0]) orelse return null;
    for (values[1..]) |v| {
        const other = jsonType(v) orelse return null;
        if (!std.mem.eql(u8, other, first)) return null;
    }
    return first;
}
