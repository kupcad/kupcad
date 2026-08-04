const std = @import("std");
const ast = @import("../../core/ast.zig");
const token = @import("../../core/token.zig");
const Config = @import("config.zig").Config;
const FormatRule = @import("rules/rule.zig").FormatRule;
const SortImportsRule = @import("rules/sort_imports.zig").SortImportsRule;

pub const Formatter = struct {
    pub const Error = error{ OutOfMemory, NoSpaceLeft };

    allocator: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8) = .empty,
    comments: []const token.Comment,
    config: Config,
    rules: std.ArrayListUnmanaged(FormatRule) = .empty,

    comment_idx: usize = 0,
    indent_level: usize = 0,

    sort_imports_rule: SortImportsRule = .{},

    pub fn init(allocator: std.mem.Allocator, comments: []const token.Comment, config: Config) Formatter {
        return Formatter{
            .allocator = allocator,
            .comments = comments,
            .config = config,
        };
    }

    pub fn registerDefaultRules(self: *Formatter) !void {
        if (self.config.sort_imports) {
            try self.rules.append(self.allocator, self.sort_imports_rule.rule());
        }
    }

    pub fn deinit(self: *Formatter) void {
        self.rules.deinit(self.allocator);
        self.out.deinit(self.allocator);
    }

    pub fn format(self: *Formatter, root: *ast.Node) ![]const u8 {
        // Phase 1: AST Normalizer (Config Application)
        for (self.rules.items) |rule| {
            rule.normalize(root);
        }

        // Phase 2: Canonical Layout Printer
        try self.formatNode(root);
        try self.flushComments(std.math.maxInt(u32));

        if (self.out.items.len > 0 and self.out.items[self.out.items.len - 1] != '\n') {
            try self.out.append(self.allocator, '\n');
        }
        return try self.out.toOwnedSlice(self.allocator);
    }

    fn writeIndent(self: *Formatter) !void {
        // Apply Config-driven indentation
        try self.out.appendNTimes(self.allocator, ' ', self.indent_level * self.config.indent_width);
    }

    fn flushComments(self: *Formatter, up_to_line: u32) !void {
        while (self.comment_idx < self.comments.len) {
            const c = self.comments[self.comment_idx];
            if (c.loc.line <= up_to_line) {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, c.lexeme);
                try self.out.append(self.allocator, '\n');
                self.comment_idx += 1;
            } else {
                break;
            }
        }
    }

    fn formatNode(self: *Formatter, node: *ast.Node) Error!void {
        try self.flushComments(node.loc.line);
        switch (node.kind) {
            .block => |b| {
                for (b.stmts, 0..) |stmt, idx| {
                    try self.writeIndent();
                    try self.formatNode(stmt);
                    if (idx < b.stmts.len - 1 or b.stmts.len == 1) {
                        try self.out.append(self.allocator, '\n');
                    }
                }
            },
            .assignment => |a| {
                try self.out.appendSlice(self.allocator, a.name);
                try self.out.append(self.allocator, ' ');
                if (a.op) |op| {
                    try self.formatBinaryOpStr(op);
                }
                try self.out.appendSlice(self.allocator, "= ");
                try self.formatNode(a.value);
            },
            .multiple_assignment => |ma| {
                for (ma.lhs, 0..) |item, idx| {
                    if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                    if (item.modifier) |mod| {
                        if (mod == .splat) try self.out.append(self.allocator, '*');
                    }
                    try self.out.appendSlice(self.allocator, item.name);
                }
                try self.out.appendSlice(self.allocator, " = ");
                try self.formatNode(ma.value);
            },
            .property_assignment => |pa| {
                try self.formatNode(pa.target);
                try self.out.append(self.allocator, '.');
                try self.out.appendSlice(self.allocator, pa.property);
                try self.out.appendSlice(self.allocator, " = ");
                try self.formatNode(pa.value);
            },
            .index_assignment => |ia| {
                try self.formatNode(ia.target);
                try self.out.append(self.allocator, '[');
                try self.formatNode(ia.index);
                try self.out.appendSlice(self.allocator, "] = ");
                try self.formatNode(ia.value);
            },
            .binary_op => |b| {
                try self.formatNode(b.left);
                try self.out.append(self.allocator, ' ');
                try self.formatBinaryOpStr(b.op);
                try self.out.append(self.allocator, ' ');
                try self.formatNode(b.right);
            },
            .unary_op => |u| {
                const op_str = switch (u.op) {
                    .negate => "-",
                    .positive => "+",
                    .not => "!",
                    .bitwise_not => "~",
                };
                try self.out.appendSlice(self.allocator, op_str);
                try self.formatNode(u.operand);
            },
            .method_call => |mc| {
                if (mc.receiver) |r| {
                    try self.formatNode(r);
                    if (r.kind == .method_call) {
                        try self.out.append(self.allocator, '\n');
                        self.indent_level += 1;
                        try self.writeIndent();
                        self.indent_level -= 1;
                    }
                    if (mc.is_safe) {
                        try self.out.appendSlice(self.allocator, "&.");
                    } else {
                        try self.out.append(self.allocator, '.');
                    }
                }
                try self.out.appendSlice(self.allocator, mc.method_name);
                if (mc.args.len > 0) {
                    try self.out.append(self.allocator, '(');
                    for (mc.args, 0..) |arg, idx| {
                        if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                        if (arg.name.len > 0) {
                            try self.out.appendSlice(self.allocator, arg.name);
                            try self.out.appendSlice(self.allocator, ": ");
                        }
                        try self.formatNode(arg.value);
                    }
                    try self.out.append(self.allocator, ')');
                }
                if (mc.block) |block_node| {
                    try self.out.append(self.allocator, ' ');
                    try self.formatBlockClosure(block_node);
                }
            },
            .if_stmt => |ifs| {
                const kw = if (ifs.is_unless) "unless " else "if ";
                try self.out.appendSlice(self.allocator, kw);
                try self.formatNode(ifs.condition);
                try self.out.append(self.allocator, '\n');
                self.indent_level += 1;
                try self.formatNode(ifs.then_branch);
                self.indent_level -= 1;
                if (ifs.else_branch) |eb| {
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "else\n");
                    self.indent_level += 1;
                    try self.formatNode(eb);
                    self.indent_level -= 1;
                }
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "end");
            },
            .def_stmt => |def| {
                try self.out.appendSlice(self.allocator, "def ");
                if (def.is_class_method) try self.out.appendSlice(self.allocator, "self.");
                try self.out.appendSlice(self.allocator, def.name);
                if (def.params.len > 0) {
                    try self.out.append(self.allocator, '(');
                    for (def.params, 0..) |p, idx| {
                        if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                        try self.out.appendSlice(self.allocator, p.name);
                        if (p.is_keyword) try self.out.append(self.allocator, ':');
                        if (p.default_value) |dv| {
                            if (p.is_keyword) {
                                try self.out.append(self.allocator, ' ');
                            } else {
                                try self.out.appendSlice(self.allocator, " = ");
                            }
                            try self.formatNode(dv);
                        }
                    }
                    try self.out.append(self.allocator, ')');
                }
                try self.out.append(self.allocator, '\n');
                self.indent_level += 1;
                try self.formatNode(def.body);
                self.indent_level -= 1;
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "end");
            },
            .class_stmt => |cls| {
                try self.out.appendSlice(self.allocator, "class ");
                try self.formatNode(cls.name);
                if (cls.super_class) |sc| {
                    try self.out.appendSlice(self.allocator, " < ");
                    try self.formatNode(sc);
                }
                try self.out.append(self.allocator, '\n');
                self.indent_level += 1;
                try self.formatNode(cls.body);
                self.indent_level -= 1;
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "end");
            },
            .module_stmt => |m| {
                try self.out.appendSlice(self.allocator, "module ");
                try self.out.appendSlice(self.allocator, m.name);
                try self.out.append(self.allocator, '\n');
                self.indent_level += 1;
                try self.formatNode(m.body);
                self.indent_level -= 1;
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "end");
            },
            .array_literal => |arr| {
                try self.out.append(self.allocator, '[');
                for (arr, 0..) |elem, idx| {
                    if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.formatNode(elem);
                }
                try self.out.append(self.allocator, ']');
            },
            .hash_literal => |entries| {
                try self.out.appendSlice(self.allocator, "{ ");
                for (entries, 0..) |entry, idx| {
                    if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.formatNode(entry.key);
                    try self.out.appendSlice(self.allocator, ": ");
                    try self.formatNode(entry.value);
                }
                try self.out.appendSlice(self.allocator, " }");
            },
            .param_doc => |doc| {
                try self.out.appendSlice(self.allocator, "# @");
                try self.out.appendSlice(self.allocator, doc.tag_name);
                var current_line_len: usize = self.indent_level * 2 + 3 + doc.tag_name.len;
                if (doc.target_name) |tn| {
                    try self.out.append(self.allocator, ' ');
                    try self.out.appendSlice(self.allocator, tn);
                    current_line_len += 1 + tn.len;
                }
                if (doc.type_name) |tn| {
                    try self.out.appendSlice(self.allocator, " [");
                    try self.out.appendSlice(self.allocator, tn);
                    try self.out.append(self.allocator, ']');
                    current_line_len += 3 + tn.len;
                }
                if (doc.description.len > 0) {
                    const max_len: usize = 80;
                    var line_iter = std.mem.splitScalar(u8, doc.description, '\n');
                    var first_line = true;
                    while (line_iter.next()) |line| {
                        if (!first_line) {
                            try self.out.append(self.allocator, '\n');
                            try self.writeIndent();
                            try self.out.appendSlice(self.allocator, "#   ");
                            current_line_len = self.indent_level * 2 + 4;
                        } else {
                            try self.out.append(self.allocator, ' ');
                            current_line_len += 1;
                        }
                        first_line = false;
                        var word_iter = std.mem.tokenizeAny(u8, line, " \t\r");
                        var first_word = true;
                        while (word_iter.next()) |word| {
                            if (!first_word) {
                                if (current_line_len + 1 + word.len > max_len) {
                                    try self.out.append(self.allocator, '\n');
                                    try self.writeIndent();
                                    try self.out.appendSlice(self.allocator, "#   ");
                                    current_line_len = self.indent_level * 2 + 4;
                                } else {
                                    try self.out.append(self.allocator, ' ');
                                    current_line_len += 1;
                                }
                            }
                            try self.out.appendSlice(self.allocator, word);
                            current_line_len += word.len;
                            first_word = false;
                        }
                    }
                }
                if (doc.options_expr) |opts| {
                    try self.out.appendSlice(self.allocator, " ");
                    try self.formatNode(opts);
                }
            },
            .number => |n| {
                var buf: [64]u8 = undefined;
                const str = try std.fmt.bufPrint(&buf, "{d}", .{n});
                try self.out.appendSlice(self.allocator, str);
            },
            .string => |s| {
                try self.out.append(self.allocator, '"');
                try self.out.appendSlice(self.allocator, s);
                try self.out.append(self.allocator, '"');
            },
            .symbol => |s| {
                try self.out.append(self.allocator, ':');
                try self.out.appendSlice(self.allocator, s);
            },
            .boolean => |b| {
                try self.out.appendSlice(self.allocator, if (b) "true" else "false");
            },
            .nil => try self.out.appendSlice(self.allocator, "nil"),
            .identifier => |i| try self.out.appendSlice(self.allocator, i),
            else => {
                try self.out.appendSlice(self.allocator, "/* unformatted node */");
            },
        }
    }

    fn formatBlockClosure(self: *Formatter, block_node: *ast.Node) Error!void {
        if (block_node.kind != .block) return;
        const b = block_node.kind.block;
        try self.out.appendSlice(self.allocator, "do");
        if (b.params.len > 0) {
            try self.out.appendSlice(self.allocator, " |");
            for (b.params, 0..) |p, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.formatNode(p);
            }
            try self.out.append(self.allocator, '|');
        }
        try self.out.append(self.allocator, '\n');
        self.indent_level += 1;
        try self.formatNode(block_node);
        self.indent_level -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "end");
    }

    fn formatBinaryOpStr(self: *Formatter, op: ast.BinaryOp) !void {
        const op_str = switch (op) {
            .add => "+",
            .subtract => "-",
            .multiply => "*",
            .divide => "/",
            .modulo => "%",
            .exponent => "**",
            .equal => "==",
            .not_equal => "!=",
            .less => "<",
            .less_equal => "<=",
            .greater => ">",
            .greater_equal => ">=",
            .logical_and => "&&",
            .logical_or => "||",
            .shift_left => "<<",
            .shift_right => ">>",
            .bitwise_and => "&",
            .bitwise_or => "|",
            .bitwise_xor => "^",
        };
        try self.out.appendSlice(self.allocator, op_str);
    }
};
