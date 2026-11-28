//! `extractSchema`: reads a script's `@title`, `@description` and `@author` comments, its
//! `param` calls and the `# @doc` blocks above its `def`s (`functionDocs`) into a `UiSchema`
//! without running it (`kupcad doc`, through api.zig): each parameter's rules as
//! param_rules.zig builds them from the literals the call is written with.

const std = @import("std");
const ast = @import("../../core/ast.zig");
const Document = @import("../../frontend/document.zig").Document;
const visitor = @import("../../core/visitor.zig");
const param_rules = @import("../../core/param_rules.zig");
const token_span = @import("../../core/token_span.zig");
const docstring = @import("docstring.zig");

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

/// A parameter a `# @param name text` line describes.
pub const ParamDoc = struct { name: []const u8, description: []const u8 };

/// A `def` at a file's top level with a doc block above it: the comment lines right above
/// the `def`, tagged `# @doc` (what it does; the lines indented past its `#` continue it),
/// `# @param name text`, `# @return text` (or `@returns`) and `# @example` (the lines under
/// it). The hover in the editor and `kupcad doc` show it.
pub const FunctionDoc = struct {
    name: []const u8,
    /// The line its `def` is on, from 1.
    line: u32,
    /// How it is called: `bolt(len, thread:)`.
    signature: []const u8,
    doc: ?[]const u8 = null,
    params: []const ParamDoc = &.{},
    returns: ?[]const u8 = null,
    example: ?[]const u8 = null,
};

pub const UiSchema = struct {
    meta: PresentationMeta,
    parameters: []ParamMetadata,
    functions: []FunctionDoc = &.{},
};

/// The schema of `doc`'s script; its strings are the Document's, or `allocator`'s.
pub fn extractSchema(allocator: std.mem.Allocator, doc: *const Document) !UiSchema {
    var schema = UiSchema{
        .meta = try headerOf(allocator, doc),
        .parameters = &.{},
    };

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
    schema.functions = try functionDocs(allocator, doc);
    return schema;
}

/// The documented `def`s of the file's top level and of its classes and modules (a method
/// as `Nut#solid`, a class method as `Nut.sizes`), in order (FunctionDoc); its strings are
/// the Document's, or `allocator`'s.
pub fn functionDocs(allocator: std.mem.Allocator, doc: *const Document) ![]FunctionDoc {
    var found: std.ArrayList(FunctionDoc) = .empty;
    errdefer found.deinit(allocator);
    const root = doc.tree.getNode(doc.tree.root) orelse return found.toOwnedSlice(allocator);
    for (doc.tree.getNodes(doc.tree.block(root).stmts)) |stmt_idx| {
        const node = doc.tree.getNode(stmt_idx) orelse continue;
        switch (node.tag) {
            .def_stmt => try addFunctionDoc(allocator, doc, node, null, &found),
            .class_stmt => {
                const cs = doc.tree.classStmt(node);
                try addMethodDocs(allocator, doc, doc.tree.getString(doc.tree.className(cs)), cs.body, &found);
            },
            .module_stmt => {
                const ms = doc.tree.moduleStmt(node);
                try addMethodDocs(allocator, doc, doc.tree.getString(ms.name), ms.body, &found);
            },
            else => {},
        }
    }
    return found.toOwnedSlice(allocator);
}

/// The documented `def`s of a class or module body, named `Owner#method` (or
/// `Owner.method` for a class method).
fn addMethodDocs(allocator: std.mem.Allocator, doc: *const Document, owner: []const u8, body: ast.NodeIndex, found: *std.ArrayList(FunctionDoc)) !void {
    const body_node = doc.tree.getNode(body) orelse return;
    if (body_node.tag != .block) return;
    for (doc.tree.getNodes(doc.tree.block(body_node).stmts)) |stmt_idx| {
        const node = doc.tree.getNode(stmt_idx) orelse continue;
        if (node.tag == .def_stmt) try addFunctionDoc(allocator, doc, node, owner, found);
    }
}

/// Adds the `def` at `node` to `found` when a doc block stands above it, named after
/// `owner` when it is a class's or module's.
fn addFunctionDoc(allocator: std.mem.Allocator, doc: *const Document, node: *const ast.Node, owner: ?[]const u8, found: *std.ArrayList(FunctionDoc)) !void {
    {
        const start = doc.tokens.starts[node.main_token];
        const block = commentBlockAbove(doc.source, start);
        const ds = doc.tree.defStmt(node);
        const bare = doc.tree.getString(ds.name);
        const method_name = if (std.mem.startsWith(u8, bare, "self.")) bare[5..] else bare;
        const name = if (owner) |o|
            try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ o, if (ds.is_class_method or std.mem.startsWith(u8, bare, "self.")) "." else "#", method_name })
        else
            bare;
        var function: FunctionDoc = .{
            .name = name,
            .line = doc.line_index.humanPosition(start).line,
            .signature = "",
        };
        var params: std.ArrayList(ParamDoc) = .empty;
        defer params.deinit(allocator);
        var lines = std.mem.splitScalar(u8, block, '\n');
        var at: usize = 0;
        while (lines.next()) |line| : (at += line.len + 1) {
            // A continuation line starts no tag, so each tag is read once, from its own line
            const tag = try docstring.parse(allocator, block[at..]) orelse continue;
            const content = try withoutLeadingBreaks(allocator, tag.content);
            if (std.mem.eql(u8, tag.tag, "doc")) {
                function.doc = content;
            } else if (std.mem.eql(u8, tag.tag, "param")) {
                const name_end = std.mem.findAny(u8, content, " \t\n") orelse content.len;
                try params.append(allocator, .{ .name = content[0..name_end], .description = std.mem.trimStart(u8, content[name_end..], " \t\n") });
            } else if (std.mem.eql(u8, tag.tag, "return") or std.mem.eql(u8, tag.tag, "returns")) {
                function.returns = content;
            } else if (std.mem.eql(u8, tag.tag, "example")) {
                function.example = content;
            } else {
                allocator.free(content);
            }
        }
        if (function.doc == null and params.items.len == 0 and function.returns == null and function.example == null) return;
        function.signature = try signatureOf(allocator, &doc.tree, node, name);
        function.params = try params.toOwnedSlice(allocator);
        try found.append(allocator, function);
    }
}

/// `content` (owned) without the line breaks it starts with: a tag whose text is all on the
/// lines under it (`# @example`, then the code) began with one.
fn withoutLeadingBreaks(allocator: std.mem.Allocator, content: []u8) ![]u8 {
    const trimmed = std.mem.trimStart(u8, content, "\n");
    if (trimmed.len == content.len) return content;
    defer allocator.free(content);
    return allocator.dupe(u8, trimmed);
}

/// The comment lines right above the statement at `start`, with nothing but blank space
/// between them and it: the block, or empty.
fn commentBlockAbove(source: []const u8, start: usize) []const u8 {
    // Back to the start of the statement's line, then up while each line is a comment
    var line_start = std.mem.lastIndexOfScalar(u8, source[0..start], '\n') orelse return "";
    const end = line_start;
    var block_start: usize = end;
    while (true) {
        const prev_line_start = if (line_start == 0) 0 else (std.mem.lastIndexOfScalar(u8, source[0..line_start], '\n') orelse 0);
        const line = std.mem.trim(u8, source[prev_line_start..line_start], " \t\r\n");
        if (line.len == 0 or line[0] != '#') break;
        block_start = if (prev_line_start == 0) 0 else prev_line_start + 1;
        if (prev_line_start == 0) break;
        line_start = prev_line_start;
    }
    return source[block_start..end];
}

/// How the `def` at `node` is called, as `name`: `name(a, b = …, key:, *rest, **opts, &blk)`.
fn signatureOf(allocator: std.mem.Allocator, tree: *const ast.Tree, node: *const ast.Node, name: []const u8) ![]const u8 {
    const ds = tree.defStmt(node);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(name);
    try out.writer.writeByte('(');
    for (tree.getParams(ds.params), 0..) |param, i| {
        if (i > 0) try out.writer.writeAll(", ");
        if (param.modifier) |modifier| try out.writer.writeAll(switch (modifier) {
            .splat => "*",
            .double_splat => "**",
            .block => "&",
        });
        try out.writer.writeAll(tree.getString(param.name));
        if (param.is_keyword) try out.writer.writeByte(':');
        if (param.default_value != .none) try out.writer.writeAll(if (param.is_keyword) " …" else " = …");
    }
    try out.writer.writeByte(')');
    return out.toOwnedSlice();
}

/// The script's `@title`, `@description` and `@author`: the tags of the comments above its
/// first statement (docstring.zig), the first of each, with the indented lines that continue
/// one joined by newlines, as YARD keeps them (a renderer folds them: the panel shows a space).
/// The source was read again line by line, which dropped a continuation, took a `# @title`
/// anywhere (the last one), and `# @titles` for a title.
fn headerOf(allocator: std.mem.Allocator, doc: *const Document) !PresentationMeta {
    var meta: PresentationMeta = .{};
    const header = doc.source[0..firstStatementOffset(doc)];
    for (doc.comments) |comment| {
        if (comment.loc.offset >= header.len) break;
        const found = try docstring.parse(allocator, header[comment.loc.offset..]) orelse continue;
        const field = headerField(&meta, found.tag) orelse {
            allocator.free(found.content);
            continue;
        };
        if (field.* == null) field.* = found.content else allocator.free(found.content);
    }
    return meta;
}

/// The field of `meta` a header's tag fills, if it names one.
fn headerField(meta: *PresentationMeta, tag: []const u8) ?*?[]const u8 {
    if (std.mem.eql(u8, tag, "title")) return &meta.title;
    if (std.mem.eql(u8, tag, "description")) return &meta.description;
    if (std.mem.eql(u8, tag, "author")) return &meta.author;
    return null;
}

/// Where the script's first statement starts: the end of its header.
fn firstStatementOffset(doc: *const Document) usize {
    const root = doc.tree.getNode(doc.tree.root) orelse return doc.source.len;
    const stmts = doc.tree.getNodes(doc.tree.block(root).stmts);
    if (stmts.len == 0) return doc.source.len;
    return doc.tokens.starts[token_span.first(&doc.tree, stmts[0])];
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
