const std = @import("std");
const ast = @import("../../core/ast.zig");
const Document = @import("../../core/document.zig").Document;
const visitor = @import("../../core/visitor.zig"); // <-- Add the AST Walker

pub const PresentationMeta = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    author: ?[]const u8 = null,
};

pub const ParamUi = struct {
    label: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
    group: ?[]const u8 = null,
};

pub const ParamValidate = struct {
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
};

pub const ParamMetadata = struct {
    name: []const u8,
    type: []const u8,
    default_value: ?std.json.Value,
    ui: ParamUi,
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
        params: *std.ArrayListUnmanaged(ParamMetadata),

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

    var params: std.ArrayListUnmanaged(ParamMetadata) = .empty;
    defer params.deinit(allocator);

    // FIX: Walk the entire AST deeply instead of just checking the root block
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
    var ui = ParamUi{};
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
        } else if (std.mem.eql(u8, kw_name, "ui")) {
            ui = extractUi(tree, arg.value);
        } else if (std.mem.eql(u8, kw_name, "validate")) {
            val = extractValidate(tree, arg.value);
        }
    }

    _ = allocator;

    return ParamMetadata{
        .name = p_name,
        .type = p_type,
        .default_value = def_val,
        .ui = ui,
        .validate = val,
    };
}

fn extractUi(tree: *const ast.Tree, node_idx: ast.NodeIndex) ParamUi {
    var ui = ParamUi{};
    const node = tree.getNode(node_idx) orelse return ui;
    if (node.tag != .hash_literal) return ui;

    const entries = tree.getHashEntries(tree.nodeSpan(node));
    for (entries) |entry| {
        const key = extractString(tree, entry.key) orelse continue;
        if (std.mem.eql(u8, key, "label")) {
            ui.label = extractString(tree, entry.value);
        } else if (std.mem.eql(u8, key, "tooltip")) {
            ui.tooltip = extractString(tree, entry.value);
        } else if (std.mem.eql(u8, key, "group")) {
            ui.group = extractString(tree, entry.value);
        }
    }
    return ui;
}

fn extractValidate(tree: *const ast.Tree, node_idx: ast.NodeIndex) ParamValidate {
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
        } else if (std.mem.eql(u8, key, "step")) {
            val.step = extractNumber(tree, entry.value);
        }
    }
    return val;
}

fn extractString(tree: *const ast.Tree, node_idx: ast.NodeIndex) ?[]const u8 {
    const node = tree.getNode(node_idx) orelse return null;
    switch (node.tag) {
        .string, .symbol, .identifier => return tree.getString(@as(ast.StringId, @enumFromInt(node.data))),
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
        .string, .symbol => return .{ .string = tree.getString(@as(ast.StringId, @enumFromInt(node.data))) },
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
