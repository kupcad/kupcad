const std = @import("std");
const ast = @import("../../core/ast.zig");
const token = @import("../../core/token.zig");
const LineIndex = @import("../../core/line_index.zig").LineIndex;
const Config = @import("config.zig").Config;
const FormatRule = @import("rules/rule.zig").FormatRule;
const SortImportsRule = @import("rules/sort_imports.zig").SortImportsRule;

pub const Formatter = struct {
    pub const Error = error{ OutOfMemory, NoSpaceLeft, SyntaxError };

    allocator: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8) = .empty,
    token_starts: []const u32,
    line_index: *const LineIndex,
    comments: []const token.Comment,
    config: Config,
    rules: std.ArrayListUnmanaged(FormatRule) = .empty,

    comment_idx: usize = 0,
    indent_level: usize = 0,

    sort_imports_rule: SortImportsRule = .{},

    pub fn init(allocator: std.mem.Allocator, token_starts: []const u32, line_index: *const LineIndex, comments: []const token.Comment, config: Config) Formatter {
        return .{
            .allocator = allocator,
            .token_starts = token_starts,
            .line_index = line_index,
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

    pub fn format(self: *Formatter, tree: *const ast.Tree, root: ast.NodeIndex) ![]const u8 {
        try self.formatNode(tree, root);
        try self.flushLeadingComments(std.math.maxInt(u32)); // Flush EOF comments
        try self.ensureNewline();
        return try self.out.toOwnedSlice(self.allocator);
    }

    // --- State & Spacing Helpers ---

    inline fn getNodeLine(self: *Formatter, node: *const ast.Node) u32 {
        if (node.main_token >= self.token_starts.len) return 0;
        return self.line_index.getLine(self.token_starts[node.main_token]);
    }

    inline fn getCommentLine(self: *Formatter, comment: token.Comment) u32 {
        return self.line_index.getLine(comment.loc.offset);
    }

    fn isAtLineStartOrEmpty(self: *Formatter) bool {
        return self.out.items.len == 0 or self.out.items[self.out.items.len - 1] == '\n';
    }

    fn ensureNewline(self: *Formatter) Error!void {
        if (!self.isAtLineStartOrEmpty()) {
            try self.out.append(self.allocator, '\n');
        }
    }

    // Determines if a node is a definition that requires visual separation
    fn requiresBlankLineSeparation(node: *const ast.Node) bool {
        return switch (node.tag) {
            .def_stmt, .class_stmt, .module_stmt, .singleton_class => true,
            else => false,
        };
    }

    // Safely ensures exactly one empty line exists
    fn ensureBlankLine(self: *Formatter) Error!void {
        try self.ensureNewline();
        if (self.out.items.len >= 2) {
            if (self.out.items[self.out.items.len - 2] != '\n') {
                try self.out.append(self.allocator, '\n');
            }
        } else if (self.out.items.len == 1) {
            try self.out.append(self.allocator, '\n');
        }
    }

    fn writeIndent(self: *Formatter) Error!void {
        try self.out.appendNTimes(self.allocator, ' ', self.indent_level * self.config.indent_width);
    }

    fn formatBodyWithEnd(self: *Formatter, tree: *const ast.Tree, body: ast.NodeIndex) Error!void {
        try self.ensureNewline();
        self.indent_level += 1;
        try self.formatNode(tree, body);
        self.indent_level -= 1;
        try self.ensureNewline(); // Force a newline before 'end'
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "end");
    }

    fn flushLeadingComments(self: *Formatter, up_to_line: u32) Error!void {
        while (self.comment_idx < self.comments.len) {
            const c = self.comments[self.comment_idx];
            const c_line = self.getCommentLine(c);
            if (c_line < up_to_line) {
                if (self.isAtLineStartOrEmpty()) try self.writeIndent();
                try self.out.appendSlice(self.allocator, c.lexeme);
                try self.out.append(self.allocator, '\n');
                self.comment_idx += 1;
            } else break;
        }
    }

    fn flushInlineComments(self: *Formatter, exact_line: u32) Error!void {
        while (self.comment_idx < self.comments.len) {
            const c = self.comments[self.comment_idx];
            const c_line = self.getCommentLine(c);
            if (c_line == exact_line) {
                if (!self.isAtLineStartOrEmpty()) {
                    try self.out.append(self.allocator, ' ');
                } else {
                    try self.writeIndent();
                }
                try self.out.appendSlice(self.allocator, c.lexeme);
                try self.out.append(self.allocator, '\n');
                self.comment_idx += 1;
            } else break;
        }
    }

    // --- Core Master Traversal ---

    fn formatNode(self: *Formatter, tree: *const ast.Tree, node_idx: ast.NodeIndex) Error!void {
        if (node_idx == .none) return;
        const node = tree.getNode(node_idx) orelse return;
        const node_line = self.getNodeLine(node);

        try self.flushLeadingComments(node_line);

        switch (node.tag) {
            .invalid => return error.SyntaxError,
            .block => {
                const b = tree.block(node);
                try self.formatBlockStmts(tree, tree.getNodes(b.stmts));
            },
            .number => {
                const n = tree.number(node);
                var buf: [64]u8 = undefined;
                try self.out.appendSlice(self.allocator, try std.fmt.bufPrint(&buf, "{d}", .{n}));
            },
            .string => try self.formatWrappedString(tree.getString(@enumFromInt(node.data)), '"'),
            .interpolated_string => {
                const parts = tree.nodeSpan(node);
                try self.formatInterpolatedString(tree, tree.getNodes(parts));
            },
            .symbol => try self.formatWrappedString(tree.getString(@enumFromInt(node.data)), ':'),
            .boolean => {
                const b = tree.boolean(node);
                try self.out.appendSlice(self.allocator, if (b) "true" else "false");
            },
            .nil => try self.out.appendSlice(self.allocator, "nil"),
            .undef => try self.out.appendSlice(self.allocator, "undef"),
            .self_expr => try self.out.appendSlice(self.allocator, "self"),
            .identifier => try self.out.appendSlice(self.allocator, tree.getString(@enumFromInt(node.data))),
            .array_literal => {
                const arr = tree.nodeSpan(node);
                try self.formatArray(tree, tree.getNodes(arr));
            },
            .hash_literal => {
                const entries = tree.nodeSpan(node);
                try self.formatHash(tree, tree.getHashEntries(entries));
            },
            .if_stmt => try self.formatIfStmt(tree, tree.ifStmt(node), node_line),
            .while_stmt => try self.formatWhileStmt(tree, tree.whileStmt(node), node_line),
            .for_stmt => try self.formatForStmt(tree, tree.forStmt(node), node_line),
            .case_stmt => try self.formatCaseStmt(tree, tree.caseStmt(node), node_line),
            .begin_stmt => try self.formatBeginStmt(tree, tree.beginStmt(node), node_line),
            .def_stmt => try self.formatDefStmt(tree, tree.defStmt(node), node_line),
            .class_stmt => try self.formatClassStmt(tree, tree.classStmt(node), node_line),
            .singleton_class => try self.formatSingletonClass(tree, tree.singletonClassPayload(node), node_line),
            .module_stmt => try self.formatModuleStmt(tree, tree.moduleStmt(node), node_line),
            .lambda_expr => try self.formatLambda(tree, tree.lambdaExpr(node), node_line),
            .namespace_access => {
                const ns = tree.nodeSpan(node);
                try self.formatNamespace(tree, tree.getStringLists(ns));
            },
            .range => try self.formatRange(tree, tree.range(node)),
            .assignment => try self.formatAssignment(tree, tree.assignment(node)),
            .multiple_assignment => try self.formatMultipleAssignment(tree, tree.multipleAssignment(node)),
            .property_assignment => try self.formatPropertyAssignment(tree, tree.propertyAssignment(node)),
            .index_assignment => try self.formatIndexAssignment(tree, tree.indexAssignment(node)),
            .index_access => try self.formatIndexAccess(tree, tree.indexAccess(node)),
            .binary_op => try self.formatBinaryOp(tree, tree.binaryExpr(node)),
            .unary_op => try self.formatUnaryOp(tree, tree.unaryExpr(node)),
            .ternary_op => try self.formatTernaryOp(tree, tree.ternaryExpr(node)),
            .splat_expr => try self.formatSplat(tree, tree.nodeIndex(node), "*"),
            .double_splat_expr => try self.formatSplat(tree, tree.nodeIndex(node), "**"),
            .each_expr => try self.formatSplat(tree, tree.nodeIndex(node), "each "),
            .rescue_modifier => try self.formatRescueModifier(tree, tree.rescueModifier(node)),
            .method_call => {
                const mc = tree.methodCall(node);
                const method_name = tree.getString(mc.method_name);

                // Route `yield` back to its dedicated formatter
                if (std.mem.eql(u8, method_name, "yield") and mc.receiver == .none) {
                    try self.formatYield(tree, mc);
                } else {
                    try self.formatMethodCall(tree, mc, node_line);
                }
            },
            .super_call => try self.formatSuperCall(tree, tree.superCall(node), node_line),
            .return_stmt => try self.formatFlowControl(tree, "return", tree.nodeIndex(node)),
            .break_stmt => try self.formatFlowControl(tree, "break", tree.nodeIndex(node)),
            .next_stmt => try self.formatFlowControl(tree, "next", tree.nodeIndex(node)),
            .import_stmt => {
                const is_stmt = tree.importStmt(node);
                try self.formatImportExport(tree, "import", tree.getStringLists(is_stmt.symbols), tree.getString(is_stmt.path), is_stmt.attributes);
            },
            .export_stmt => {
                const es_stmt = tree.exportStmt(node);
                try self.formatImportExport(tree, "export", tree.getStringLists(es_stmt.symbols), tree.getString(es_stmt.path), es_stmt.attributes);
            },
            .defined_expr => {
                try self.out.appendSlice(self.allocator, "defined?(");
                if (node.data != @intFromEnum(ast.StringId.none)) {
                    const name_id = @as(ast.StringId, @enumFromInt(node.data));
                    try self.out.appendSlice(self.allocator, tree.getString(name_id));
                }
                try self.out.append(self.allocator, ')');
            },
            .docstring => try self.formatDocString(tree, tree.docString(node)),
            .yield_stmt => unreachable,
        }
    }

    // --- Isolated Node Formatters ---

    fn formatBlockStmts(self: *Formatter, tree: *const ast.Tree, stmts: []const ast.NodeIndex) Error!void {
        var temp_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer temp_arena.deinit();

        var print_stmts = stmts;
        for (self.rules.items) |rule| {
            print_stmts = rule.processBlockStmts(temp_arena.allocator(), tree, print_stmts);
        }

        for (print_stmts, 0..) |stmt_idx, idx| {
            const stmt = tree.getNode(stmt_idx).?;
            const stmt_line = self.getNodeLine(stmt);

            if (idx > 0) {
                const prev_stmt = tree.getNode(print_stmts[idx - 1]).?;
                const prev_line = self.getNodeLine(prev_stmt);

                if (stmt_line == prev_line) {
                    // Same line in original source! Emit a single semicolon.
                    try self.out.appendSlice(self.allocator, "; ");
                } else {
                    // Different lines, proceed with normal vertical formatting
                    if (requiresBlankLineSeparation(prev_stmt) or requiresBlankLineSeparation(stmt)) {
                        try self.ensureBlankLine();
                    } else {
                        try self.ensureNewline();
                    }
                    try self.flushLeadingComments(stmt_line);
                    if (self.isAtLineStartOrEmpty()) try self.writeIndent();
                }
            } else {
                try self.flushLeadingComments(stmt_line);
                if (self.isAtLineStartOrEmpty()) try self.writeIndent();
            }

            try self.formatNode(tree, stmt_idx);

            // Inline comments inherently force a newline, which is correct
            // because a comment goes to the end of the line.
            try self.flushInlineComments(stmt_line);
        }
    }

    fn formatWrappedString(self: *Formatter, s: []const u8, wrapper: u8) Error!void {
        if (wrapper == '"') try self.out.append(self.allocator, '"');
        if (wrapper == ':') try self.out.append(self.allocator, ':');
        try self.out.appendSlice(self.allocator, s);
        if (wrapper == '"') try self.out.append(self.allocator, '"');
    }

    fn formatInterpolatedString(self: *Formatter, tree: *const ast.Tree, parts: []const ast.NodeIndex) Error!void {
        try self.out.append(self.allocator, '"');
        for (parts) |part_idx| {
            const part = tree.getNode(part_idx).?;
            if (part.tag == .string) {
                try self.out.appendSlice(self.allocator, tree.getString(@enumFromInt(part.data)));
            } else {
                try self.out.appendSlice(self.allocator, "#{");
                try self.formatNode(tree, part_idx);
                try self.out.append(self.allocator, '}');
            }
        }
        try self.out.append(self.allocator, '"');
    }

    fn formatArray(self: *Formatter, tree: *const ast.Tree, arr: []const ast.NodeIndex) Error!void {
        if (arr.len == 0) return self.out.appendSlice(self.allocator, "[]");
        try self.out.append(self.allocator, '[');
        for (arr, 0..) |elem, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.formatNode(tree, elem);
        }
        try self.out.append(self.allocator, ']');
    }

    fn formatHash(self: *Formatter, tree: *const ast.Tree, entries: []const ast.HashEntry) Error!void {
        if (entries.len == 0) return self.out.appendSlice(self.allocator, "{}");
        try self.out.appendSlice(self.allocator, "{ ");
        for (entries, 0..) |entry, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
            const key_node = tree.getNode(entry.key).?;
            const val_node = tree.getNode(entry.value).?;

            if (key_node.tag == .double_splat_expr) {
                try self.formatNode(tree, entry.key);
            } else if (key_node.tag == .symbol and val_node.tag == .identifier and std.mem.eql(u8, tree.getString(@enumFromInt(key_node.data)), tree.getString(@enumFromInt(val_node.data)))) {
                try self.out.appendSlice(self.allocator, tree.getString(@enumFromInt(key_node.data)));
                try self.out.append(self.allocator, ':');
            } else {
                if (key_node.tag == .symbol) {
                    try self.out.appendSlice(self.allocator, tree.getString(@enumFromInt(key_node.data)));
                    try self.out.appendSlice(self.allocator, ": ");
                } else {
                    try self.formatNode(tree, entry.key);
                    try self.out.appendSlice(self.allocator, " => ");
                }
                try self.formatNode(tree, entry.value);
            }
        }
        try self.out.appendSlice(self.allocator, " }");
    }

    fn formatIfStmt(self: *Formatter, tree: *const ast.Tree, ifs: ast.IfStmt, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, if (ifs.is_unless) "unless " else "if ");
        try self.formatNode(tree, ifs.condition);
        try self.flushInlineComments(start_line);
        try self.ensureNewline();

        self.indent_level += 1;
        try self.formatNode(tree, ifs.then_branch);
        self.indent_level -= 1;
        try self.ensureNewline(); // Force a newline before 'else' or 'end'

        if (ifs.else_branch != .none) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "else\n");
            self.indent_level += 1;
            try self.formatNode(tree, ifs.else_branch);
            self.indent_level -= 1;
            try self.ensureNewline(); // Force a newline before 'end'
        }

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "end");
    }

    fn formatWhileStmt(self: *Formatter, tree: *const ast.Tree, ws: ast.WhileStmt, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, if (ws.is_until) "until " else "while ");
        try self.formatNode(tree, ws.condition);
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(tree, ws.body);
    }

    fn formatForStmt(self: *Formatter, tree: *const ast.Tree, fs: ast.ForStmt, start_line: u32) Error!void {
        const kw = if (fs.is_intersection) "intersection_for(" else "for(";
        try self.out.appendSlice(self.allocator, kw);
        for (tree.getForBindings(fs.bindings), 0..) |b, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, tree.getString(b.name));
            try self.out.appendSlice(self.allocator, " = ");
            try self.formatNode(tree, b.range);
        }
        try self.out.appendSlice(self.allocator, ")");
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(tree, fs.body);
    }

    fn formatCaseStmt(self: *Formatter, tree: *const ast.Tree, cs: ast.CaseStmt, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "case");
        if (cs.condition != .none) {
            try self.out.append(self.allocator, ' ');
            try self.formatNode(tree, cs.condition);
        }
        try self.flushInlineComments(start_line);
        try self.out.append(self.allocator, '\n');

        for (tree.getWhenBranches(cs.when_branches)) |wb| {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "when ");
            for (tree.getNodes(wb.conditions), 0..) |cond, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.formatNode(tree, cond);
            }
            try self.ensureNewline();
            self.indent_level += 1;
            try self.formatNode(tree, wb.body);
            self.indent_level -= 1;
            try self.ensureNewline(); // Force a newline before the next 'when', 'else', or 'end'
        }

        if (cs.else_branch != .none) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "else\n");
            self.indent_level += 1;
            try self.formatNode(tree, cs.else_branch);
            self.indent_level -= 1;
            try self.ensureNewline(); // Force a newline before 'end'
        }

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "end");
    }

    fn formatBeginStmt(self: *Formatter, tree: *const ast.Tree, bs: ast.BeginStmt, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "begin");
        try self.flushInlineComments(start_line);
        try self.out.append(self.allocator, '\n');

        self.indent_level += 1;
        try self.formatNode(tree, bs.body);
        self.indent_level -= 1;
        try self.ensureNewline(); // Force a newline before 'rescue', 'ensure', or 'end'

        for (tree.getRescueClauses(bs.rescues)) |r| {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "rescue");

            const errors = tree.getStringLists(r.errors);
            if (errors.len > 0) {
                try self.out.append(self.allocator, ' ');
                for (errors, 0..) |e_id, i| {
                    if (i > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.out.appendSlice(self.allocator, tree.getString(e_id));
                }
            }
            if (r.variable != .none) {
                try self.out.appendSlice(self.allocator, " => ");
                try self.out.appendSlice(self.allocator, tree.getString(r.variable));
            }
            try self.ensureNewline();
            self.indent_level += 1;
            try self.formatNode(tree, r.body);
            self.indent_level -= 1;
            try self.ensureNewline(); // Force a newline before the next 'rescue', 'ensure', or 'end'
        }

        if (bs.ensure_body != .none) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "ensure\n");
            self.indent_level += 1;
            try self.formatNode(tree, bs.ensure_body);
            self.indent_level -= 1;
            try self.ensureNewline(); // Force a newline before 'end'
        }

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "end");
    }

    fn formatDefStmt(self: *Formatter, tree: *const ast.Tree, def: ast.DefStmt, start_line: u32) Error!void {
        if (def.is_private) {
            try self.out.appendSlice(self.allocator, "private ");
        }
        try self.out.appendSlice(self.allocator, "def ");

        if (def.is_class_method) try self.out.appendSlice(self.allocator, "self.");
        try self.out.appendSlice(self.allocator, tree.getString(def.name));

        const params = tree.getParams(def.params);
        if (params.len > 0) {
            try self.out.append(self.allocator, '(');
            for (params, 0..) |p, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                if (p.modifier) |mod| try self.out.appendSlice(self.allocator, getArgModifierStr(mod));

                try self.out.appendSlice(self.allocator, tree.getString(p.name));
                if (p.is_keyword) try self.out.append(self.allocator, ':');
                if (p.default_value != .none) {
                    try self.out.appendSlice(self.allocator, if (p.is_keyword) " " else " = ");
                    try self.formatNode(tree, p.default_value);
                }
            }
            try self.out.append(self.allocator, ')');
        }
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(tree, def.body);
    }

    fn formatClassStmt(self: *Formatter, tree: *const ast.Tree, cls: ast.ClassStmt, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "class ");
        try self.formatNode(tree, cls.name);
        if (cls.super_class != .none) {
            try self.out.appendSlice(self.allocator, " < ");
            try self.formatNode(tree, cls.super_class);
        }
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(tree, cls.body);
    }

    fn formatSingletonClass(self: *Formatter, tree: *const ast.Tree, sc: ast.SingletonClass, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "class << ");
        try self.formatNode(tree, sc.target);
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(tree, sc.body);
    }

    fn formatModuleStmt(self: *Formatter, tree: *const ast.Tree, m: ast.ModuleStmt, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "module ");
        try self.out.appendSlice(self.allocator, tree.getString(m.name));
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(tree, m.body);
    }

    fn formatLambda(self: *Formatter, tree: *const ast.Tree, l: ast.LambdaExpr, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "->");
        const params = tree.getParams(l.params);
        if (params.len > 0) {
            try self.out.append(self.allocator, '(');
            for (params, 0..) |p, i| {
                if (i > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, tree.getString(p.name));
            }
            try self.out.append(self.allocator, ')');
        }

        const body_node = tree.getNode(l.body).?;
        if (body_node.tag == .block) {
            try self.out.appendSlice(self.allocator, " ");
            try self.formatBlockClosure(tree, l.body, start_line);
        } else {
            try self.out.appendSlice(self.allocator, " { ");
            try self.formatNode(tree, l.body);
            try self.out.appendSlice(self.allocator, " }");
        }
    }

    fn formatNamespace(self: *Formatter, tree: *const ast.Tree, path: []const ast.StringId) Error!void {
        for (path, 0..) |p_id, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, "::");
            try self.out.appendSlice(self.allocator, tree.getString(p_id));
        }
    }

    fn formatRange(self: *Formatter, tree: *const ast.Tree, r: ast.Range) Error!void {
        try self.formatNode(tree, r.start);
        try self.out.appendSlice(self.allocator, if (r.is_exclusive) "..." else "..");
        try self.formatNode(tree, r.end);
    }

    fn formatAssignment(self: *Formatter, tree: *const ast.Tree, a: ast.Assignment) Error!void {
        try self.out.appendSlice(self.allocator, tree.getString(a.name));
        try self.out.append(self.allocator, ' ');
        if (a.op) |op| try self.out.appendSlice(self.allocator, getBinaryOpStr(op));
        try self.out.appendSlice(self.allocator, "= ");
        try self.formatNode(tree, a.value);
    }

    fn formatMultipleAssignment(self: *Formatter, tree: *const ast.Tree, ma: ast.MultipleAssignment) Error!void {
        for (tree.getLhsExprs(ma.lhs), 0..) |item, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
            if (item.modifier) |mod| try self.out.appendSlice(self.allocator, getArgModifierStr(mod));
            try self.out.appendSlice(self.allocator, tree.getString(item.name));
        }
        try self.out.appendSlice(self.allocator, " = ");
        try self.formatNode(tree, ma.value);
    }

    fn formatPropertyAssignment(self: *Formatter, tree: *const ast.Tree, pa: ast.PropertyAssignment) Error!void {
        try self.formatNode(tree, pa.target);
        try self.out.append(self.allocator, '.');
        try self.out.appendSlice(self.allocator, tree.getString(pa.property));
        try self.out.append(self.allocator, ' ');
        if (pa.op) |op| try self.out.appendSlice(self.allocator, getBinaryOpStr(op));
        try self.out.appendSlice(self.allocator, "= ");
        try self.formatNode(tree, pa.value);
    }

    fn formatIndexAssignment(self: *Formatter, tree: *const ast.Tree, ia: ast.IndexAssignment) Error!void {
        try self.formatNode(tree, ia.target);
        try self.out.append(self.allocator, '[');
        try self.formatNode(tree, ia.index);
        try self.out.appendSlice(self.allocator, "] ");
        if (ia.op) |op| try self.out.appendSlice(self.allocator, getBinaryOpStr(op));
        try self.out.appendSlice(self.allocator, "= ");
        try self.formatNode(tree, ia.value);
    }

    fn formatIndexAccess(self: *Formatter, tree: *const ast.Tree, ia: anytype) Error!void {
        try self.formatNode(tree, ia.target);
        try self.out.append(self.allocator, '[');
        try self.formatNode(tree, ia.index);
        try self.out.append(self.allocator, ']');
    }

    fn formatBinaryOp(self: *Formatter, tree: *const ast.Tree, b: ast.BinaryExpr) Error!void {
        try self.formatNode(tree, b.left);
        try self.out.append(self.allocator, ' ');
        try self.out.appendSlice(self.allocator, getBinaryOpStr(b.op));
        try self.out.append(self.allocator, ' ');
        try self.formatNode(tree, b.right);
    }

    fn formatUnaryOp(self: *Formatter, tree: *const ast.Tree, u: anytype) Error!void {
        const op_str = switch (u.op) {
            .negate => "-",
            .positive => "+",
            .not => "!",
            .bitwise_not => "~",
        };
        try self.out.appendSlice(self.allocator, op_str);
        try self.formatNode(tree, u.operand);
    }

    fn formatTernaryOp(self: *Formatter, tree: *const ast.Tree, t: ast.TernaryExpr) Error!void {
        try self.formatNode(tree, t.condition);
        try self.out.appendSlice(self.allocator, " ? ");
        try self.formatNode(tree, t.then_branch);
        try self.out.appendSlice(self.allocator, " : ");
        try self.formatNode(tree, t.else_branch);
    }

    fn formatSplat(self: *Formatter, tree: *const ast.Tree, node: ast.NodeIndex, prefix: []const u8) Error!void {
        try self.out.appendSlice(self.allocator, prefix);
        try self.formatNode(tree, node);
    }

    fn formatRescueModifier(self: *Formatter, tree: *const ast.Tree, rm: anytype) Error!void {
        try self.formatNode(tree, rm.expr);
        try self.out.appendSlice(self.allocator, " rescue ");
        try self.formatNode(tree, rm.rescue_expr);
    }

    fn formatMethodCall(self: *Formatter, tree: *const ast.Tree, mc: ast.MethodCall, start_line: u32) Error!void {
        if (mc.receiver != .none) {
            try self.formatNode(tree, mc.receiver);
            // Multi-line indentation alignment for fluent method chains
            const r_node = tree.getNode(mc.receiver).?;
            if (r_node.tag == .method_call) {
                try self.ensureNewline();
                self.indent_level += 1;
                try self.writeIndent();
                self.indent_level -= 1;
            }
            try self.out.appendSlice(self.allocator, if (mc.is_safe) "&." else ".");
        }
        try self.out.appendSlice(self.allocator, tree.getString(mc.method_name));

        const args = tree.getNamedArgs(mc.args);
        if (args.len > 0) {
            try self.out.append(self.allocator, '(');
            for (args, 0..) |arg, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                if (arg.modifier) |mod| try self.out.appendSlice(self.allocator, getArgModifierStr(mod));

                const arg_name = tree.getString(arg.name);
                if (arg_name.len > 0) {
                    try self.out.appendSlice(self.allocator, arg_name);
                    try self.out.appendSlice(self.allocator, ": ");
                }
                try self.formatNode(tree, arg.value);
            }
            try self.out.append(self.allocator, ')');
        } else if (mc.receiver == .none and mc.block == .none) {
            try self.out.appendSlice(self.allocator, "()");
        }
        if (mc.block != .none) {
            try self.out.append(self.allocator, ' ');
            try self.formatBlockClosure(tree, mc.block, start_line);
        }
    }

    fn formatBlockClosure(self: *Formatter, tree: *const ast.Tree, block_idx: ast.NodeIndex, start_line: u32) Error!void {
        if (block_idx == .none) return;
        const block_node = tree.getNode(block_idx).?;
        if (block_node.tag != .block) return;
        const b = tree.block(block_node);

        try self.out.appendSlice(self.allocator, "do");
        const params = tree.getNodes(b.params);
        if (params.len > 0) {
            try self.out.appendSlice(self.allocator, " |");
            for (params, 0..) |p_idx, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.formatNode(tree, p_idx);
            }
            try self.out.append(self.allocator, '|');
        }
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(tree, block_idx);
    }

    fn formatSuperCall(self: *Formatter, tree: *const ast.Tree, sc: ast.SuperCall, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "super");
        const args = tree.getNamedArgs(sc.args);
        if (args.len > 0) {
            try self.out.append(self.allocator, '(');
            for (args, 0..) |arg, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                const arg_name = tree.getString(arg.name);
                if (arg_name.len > 0) {
                    try self.out.appendSlice(self.allocator, arg_name);
                    try self.out.appendSlice(self.allocator, ": ");
                }
                try self.formatNode(tree, arg.value);
            }
            try self.out.append(self.allocator, ')');
        }
        if (sc.block != .none) {
            try self.out.append(self.allocator, ' ');
            try self.formatBlockClosure(tree, sc.block, start_line);
        }
    }

    fn formatFlowControl(self: *Formatter, tree: *const ast.Tree, kw: []const u8, val: ast.NodeIndex) Error!void {
        try self.out.appendSlice(self.allocator, kw);
        if (val != .none) {
            try self.out.append(self.allocator, ' ');

            const val_node = tree.getNode(val).?;
            if (val_node.tag == .array_literal) {
                // If multiple values were returned, they are packed in an Array.
                // Format them as comma-separated values without the brackets.
                const arr_elems = tree.getNodes(tree.nodeSpan(val_node));
                for (arr_elems, 0..) |elem, idx| {
                    if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.formatNode(tree, elem);
                }
            } else {
                try self.formatNode(tree, val);
            }
        }
    }

    fn formatYield(self: *Formatter, tree: *const ast.Tree, mc: ast.MethodCall) Error!void {
        try self.out.appendSlice(self.allocator, "yield");

        const args = tree.getNamedArgs(mc.args);
        if (args.len > 0) {
            try self.out.append(self.allocator, '(');
            for (args, 0..) |arg, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                if (arg.modifier) |mod| try self.out.appendSlice(self.allocator, getArgModifierStr(mod));

                const arg_name = tree.getString(arg.name);
                if (arg_name.len > 0) {
                    try self.out.appendSlice(self.allocator, arg_name);
                    try self.out.appendSlice(self.allocator, ": ");
                }
                try self.formatNode(tree, arg.value);
            }
            try self.out.append(self.allocator, ')');
        }
    }

    fn formatImportExport(self: *Formatter, tree: *const ast.Tree, kw: []const u8, symbols: []const ast.StringId, path: []const u8, attrs: ast.NodeIndex) Error!void {
        try self.out.appendSlice(self.allocator, kw);
        try self.out.append(self.allocator, ' ');
        if (symbols.len > 0) {
            try self.out.appendSlice(self.allocator, "{ ");
            for (symbols, 0..) |sym_id, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, tree.getString(sym_id));
            }
            try self.out.appendSlice(self.allocator, " } from ");
        }
        try self.out.append(self.allocator, '"');
        try self.out.appendSlice(self.allocator, path);
        try self.out.append(self.allocator, '"');

        if (attrs != .none) {
            try self.out.appendSlice(self.allocator, " with ");
            try self.formatNode(tree, attrs);
        }
    }

    fn formatDocString(self: *Formatter, tree: *const ast.Tree, doc: ast.DocString) Error!void {
        const tag = tree.getString(doc.tag_name);
        const content = tree.getString(doc.content);

        try self.out.appendSlice(self.allocator, "# @");
        try self.out.appendSlice(self.allocator, tag);

        if (content.len > 0) {
            var lines = std.mem.splitScalar(u8, content, '\n');

            // First line sits on the same line right after the tag
            if (lines.next()) |first_line| {
                try self.out.append(self.allocator, ' ');
                try self.out.appendSlice(self.allocator, first_line);
            }

            // Subsequent continuation lines get an indented YARD comment prefix (#   )
            while (lines.next()) |line| {
                try self.ensureNewline();
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "#   ");
                try self.out.appendSlice(self.allocator, line);
            }
        }
    }

    fn formatWrappedText(self: *Formatter, text: []const u8, current_line_len: *usize) Error!void {
        var line_iter = std.mem.splitScalar(u8, text, '\n');
        var first_line = true;
        while (line_iter.next()) |line| {
            if (!first_line) {
                try self.ensureNewline();
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "#   ");
                current_line_len.* = self.indent_level * self.config.indent_width + 4;
            } else {
                try self.out.append(self.allocator, ' ');
                current_line_len.* += 1;
            }
            first_line = false;

            var word_iter = std.mem.tokenizeAny(u8, line, " \t\r");
            var first_word = true;
            while (word_iter.next()) |word| {
                if (!first_word) {
                    if (current_line_len.* + 1 + word.len > self.config.max_line_length) {
                        try self.ensureNewline();
                        try self.writeIndent();
                        try self.out.appendSlice(self.allocator, "#   ");
                        current_line_len.* = self.indent_level * self.config.indent_width + 4;
                    } else {
                        try self.out.append(self.allocator, ' ');
                        current_line_len.* += 1;
                    }
                }
                try self.out.appendSlice(self.allocator, word);
                current_line_len.* += word.len;
                first_word = false;
            }
        }
    }
};

// --- Pure Data Lookups ---

fn getBinaryOpStr(op: ast.BinaryOp) []const u8 {
    return switch (op) {
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
        .spaceship => "<=>",
    };
}

fn getArgModifierStr(mod: ast.ArgModifier) []const u8 {
    return switch (mod) {
        .splat => "*",
        .double_splat => "**",
        .block => "&",
    };
}
