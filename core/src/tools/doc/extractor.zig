//! `extractSchema`: reads a script's `@title`, `@description` and `@author` comments and
//! its `param` calls into a `UiSchema` without running it (`kupcad doc`, through api.zig): each
//! parameter's rules as param_rules.zig builds them from the literals the call is written with.

const std = @import("std");
const ast = @import("../../core/ast.zig");
const Document = @import("../../frontend/document.zig").Document;
const visitor = @import("../../core/visitor.zig");
const param_rules = @import("../../core/param_rules.zig");

pub const PresentationMeta = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    author: ?[]const u8 = null,
};

/// One `param(...)` as the schema gives it: its rules (param_rules.zig's, read from the
/// script's literals as the run reads them), its default, and where a host's control goes.
pub const ParamMetadata = struct {
    name: []const u8,
    rule: param_rules.Rule,
    /// Its default as its rules read it; nil (null) when there is none, or the run computes it.
    default_value: param_rules.Literal = .nil,
    /// The heading a control goes under, `group:`.
    group: ?[]const u8 = null,
    /// What a host shows with the control, `description:`.
    description: ?[]const u8 = null,

    /// As the protocol's `ParamSpec`: its name, its rule's fields, its default, its group and
    /// description.
    pub fn jsonStringify(self: ParamMetadata, jw: *std.json.Stringify) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.name);
        try self.rule.writeFields(jw);
        try jw.objectField("default_value");
        try self.default_value.jsonStringify(jw);
        try jw.objectField("group");
        try jw.write(self.group);
        try jw.objectField("description");
        try jw.write(self.description);
        try jw.endObject();
    }
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

    var declaration: param_rules.Declaration = .{ .name = extractString(tree, args[0].value) orelse "unknown" };
    var group: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    for (args) |arg| {
        if (arg.name == .none) continue;
        const kw_name = tree.getString(arg.name);
        if (std.mem.eql(u8, kw_name, "default")) {
            // One only the run computes is taken for a number's, as most are
            if (try literalOf(allocator, tree, arg.value, .whole, param_rules.MAX_LITERAL_DEPTH)) |default| declaration.default = default else declaration.fallback = .number;
        } else if (std.mem.eql(u8, kw_name, "type")) {
            declaration.type = try literalOf(allocator, tree, arg.value, .whole, param_rules.MAX_LITERAL_DEPTH);
        } else if (std.mem.eql(u8, kw_name, "validate")) {
            declaration.validate = try literalOf(allocator, tree, arg.value, .known, param_rules.MAX_LITERAL_DEPTH);
        } else if (std.mem.eql(u8, kw_name, "step")) {
            declaration.step = extractNumber(tree, arg.value);
        } else if (std.mem.eql(u8, kw_name, "unit")) {
            declaration.unit = extractText(tree, arg.value);
        } else if (std.mem.eql(u8, kw_name, "title")) {
            declaration.title = extractText(tree, arg.value);
        } else if (std.mem.eql(u8, kw_name, "group")) {
            group = extractText(tree, arg.value);
        } else if (std.mem.eql(u8, kw_name, "description")) {
            description = extractText(tree, arg.value);
        }
    }
    const built = try rulesOf(allocator, declaration);
    return .{
        .name = declaration.name,
        .rule = built.rule,
        .default_value = built.default,
        .group = group,
        .description = description,
    };
}

/// The rules `declaration` gives. Where the run would refuse them, those its type and default
/// give without its `validate:`, else its type alone, else its fallback's: the schema lists the
/// parameter either way.
fn rulesOf(allocator: std.mem.Allocator, declaration: param_rules.Declaration) !param_rules.Built {
    var why: []const u8 = undefined;
    var tried = declaration;
    for (0..3) |attempt| {
        if (param_rules.build(allocator, tried, &why)) |built| return built else |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.InvalidRule => {},
        }
        if (attempt == 0) tried.validate = null else tried.default = .nil;
    }
    return .{ .rule = .{ .kind = declaration.fallback, .title = declaration.title }, .default = .nil };
}

/// How much of a literal the schema takes: all of it (a default, a `type:`), or (of
/// `validate:`) the rules written as literals, one the run computes left out.
const Reading = enum { whole, known };

/// A literal's value: a number, a String's or a Symbol's text, true or false, nil, or an Array
/// or a Map of them; null for what only the run computes.
fn literalOf(allocator: std.mem.Allocator, tree: *const ast.Tree, node_idx: ast.NodeIndex, reading: Reading, depth: usize) !?param_rules.Literal {
    const node = tree.getNode(node_idx) orelse return null;
    switch (node.tag) {
        .number => return .{ .number = tree.number(node) },
        .boolean => return .{ .boolean = tree.boolean(node) },
        .string => return .{ .string = tree.nodeString(node) },
        .symbol => return .{ .symbol = tree.nodeString(node) },
        .nil => return .nil,
        .unary_op => {
            const un = tree.unaryExpr(node);
            if (un.op != .negate) return null;
            const inner = tree.getNode(un.operand) orelse return null;
            return if (inner.tag == .number) .{ .number = -tree.number(inner) } else null;
        },
        .array_literal => {
            if (depth == 0) return null;
            const elements = tree.getNodes(tree.arrayLiteral(node).span);
            const items = try allocator.alloc(param_rules.Literal, elements.len);
            // A list or a tuple with a part computed is all the run's: its places would shift
            for (elements, items) |element, *item| item.* = try literalOf(allocator, tree, element, reading, depth - 1) orelse return null;
            return .{ .array = items };
        },
        .hash_literal => {
            if (depth == 0) return null;
            const entries = tree.getHashEntries(tree.nodeSpan(node));
            var read: std.ArrayList(param_rules.Literal.Entry) = .empty;
            for (entries) |entry| {
                const key = extractString(tree, entry.key);
                const item = try literalOf(allocator, tree, entry.value, reading, depth - 1);
                if (key == null or item == null) {
                    if (reading == .whole) return null;
                    continue;
                }
                try read.append(allocator, .{ .key = key.?, .value = item.? });
            }
            return .{ .map = try read.toOwnedSlice(allocator) };
        },
        else => return null,
    }
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
