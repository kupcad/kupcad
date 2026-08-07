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
        return .{
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

    pub fn format(self: *Formatter, tree: *const ast.Tree, root: ast.NodeIndex) ![]const u8 {
        try self.formatNode(tree, root);
        try self.flushLeadingComments(std.math.maxInt(u32)); // Flush EOF comments
        try self.ensureNewline();
        return try self.out.toOwnedSlice(self.allocator);
    }

    // --- State & Spacing Helpers ---

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
        return switch (node.kind) {
            .def_stmt, .class_stmt, .module_stmt => true,
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
            if (c.loc.line < up_to_line) {
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
            if (c.loc.line == exact_line) {
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

        try self.flushLeadingComments(node.loc.line);
        switch (node.kind) {
            .block => |b| try self.formatBlockStmts(tree, b.stmts),
            .number => |n| {
                var buf: [64]u8 = undefined;
                try self.out.appendSlice(self.allocator, try std.fmt.bufPrint(&buf, "{d}", .{n}));
            },
            .string => |s| try self.formatWrappedString(s, '"'),
            .interpolated_string => |parts| try self.formatInterpolatedString(tree, parts),
            .symbol => |s| try self.formatWrappedString(s, ':'),
            .boolean => |b| try self.out.appendSlice(self.allocator, if (b) "true" else "false"),
            .nil => try self.out.appendSlice(self.allocator, "nil"),
            .undef => try self.out.appendSlice(self.allocator, "undef"),
            .self_expr => try self.out.appendSlice(self.allocator, "self"),
            .identifier => |i| try self.out.appendSlice(self.allocator, i),
            .array_literal => |arr| try self.formatArray(tree, arr),
            .hash_literal => |entries| try self.formatHash(tree, entries),
            .if_stmt => |ifs| try self.formatIfStmt(tree, ifs, node.loc.line),
            .while_stmt => |ws| try self.formatWhileStmt(tree, ws, node.loc.line),
            .for_stmt => |fs| try self.formatForStmt(tree, fs, node.loc.line),
            .case_stmt => |cs| try self.formatCaseStmt(tree, cs, node.loc.line),
            .begin_stmt => |bs| try self.formatBeginStmt(tree, bs, node.loc.line),
            .def_stmt => |def| try self.formatDefStmt(tree, def, node.loc.line),
            .class_stmt => |cls| try self.formatClassStmt(tree, cls, node.loc.line),
            .module_stmt => |m| try self.formatModuleStmt(tree, m, node.loc.line),
            .lambda_expr => |l| try self.formatLambda(tree, l, node.loc.line),
            .namespace_access => |ns| try self.formatNamespace(ns),
            .range => |r| try self.formatRange(tree, r),
            .assignment => |a| try self.formatAssignment(tree, a),
            .multiple_assignment => |ma| try self.formatMultipleAssignment(tree, ma),
            .property_assignment => |pa| try self.formatPropertyAssignment(tree, pa),
            .index_assignment => |ia| try self.formatIndexAssignment(tree, ia),
            .index_access => |ia| try self.formatIndexAccess(tree, ia),
            .binary_op => |b| try self.formatBinaryOp(tree, b),
            .unary_op => |u| try self.formatUnaryOp(tree, u),
            .ternary_op => |t| try self.formatTernaryOp(tree, t),
            .splat_expr => |s| try self.formatSplat(tree, s, "*"),
            .double_splat_expr => |s| try self.formatSplat(tree, s, "**"),
            .each_expr => |e| try self.formatSplat(tree, e, "each "),
            .rescue_modifier => |rm| try self.formatRescueModifier(tree, rm),
            .method_call => |mc| try self.formatMethodCall(tree, mc, node.loc.line),
            .super_call => |sc| try self.formatSuperCall(tree, sc, node.loc.line),
            .return_stmt => |r| try self.formatFlowControl(tree, "return", r),
            .break_stmt => |b| try self.formatFlowControl(tree, "break", b),
            .next_stmt => |n| try self.formatFlowControl(tree, "next", n),
            .yield_stmt => |y| try self.formatYield(tree, y),
            .import_stmt => |is| try self.formatImportExport(tree, "import", is.symbols, is.path, is.attributes),
            .export_stmt => |es| try self.formatImportExport(tree, "export", es.symbols, es.path, es.attributes),
            .param_doc => |doc| try self.formatParamDoc(tree, doc),
            .comment => |c| try self.out.appendSlice(self.allocator, c),
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
            if (idx > 0) {
                const prev_stmt = tree.getNode(print_stmts[idx - 1]).?;
                if (requiresBlankLineSeparation(prev_stmt) or requiresBlankLineSeparation(stmt)) {
                    try self.ensureBlankLine();
                }
            }

            try self.flushLeadingComments(stmt.loc.line);
            if (self.isAtLineStartOrEmpty()) try self.writeIndent();
            try self.formatNode(tree, stmt_idx);
            try self.flushInlineComments(stmt.loc.line);
            try self.ensureNewline();
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
            if (part.kind == .string) {
                try self.out.appendSlice(self.allocator, part.kind.string);
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

            if (key_node.kind == .double_splat_expr) {
                try self.formatNode(tree, entry.key);
            } else if (key_node.kind == .symbol and val_node.kind == .identifier and std.mem.eql(u8, key_node.kind.symbol, val_node.kind.identifier)) {
                try self.out.appendSlice(self.allocator, key_node.kind.symbol);
                try self.out.append(self.allocator, ':');
            } else {
                if (key_node.kind == .symbol) {
                    try self.out.appendSlice(self.allocator, key_node.kind.symbol);
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
        for (fs.bindings, 0..) |b, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, b.name);
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

        for (cs.when_branches) |wb| {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "when ");
            for (wb.conditions, 0..) |cond, idx| {
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

        for (bs.rescues) |r| {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "rescue");
            if (r.errors.len > 0) {
                try self.out.append(self.allocator, ' ');
                for (r.errors, 0..) |e, i| {
                    if (i > 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.out.appendSlice(self.allocator, e);
                }
            }
            if (r.variable) |v| {
                try self.out.appendSlice(self.allocator, " => ");
                try self.out.appendSlice(self.allocator, v);
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
        try self.out.appendSlice(self.allocator, "def ");
        if (def.is_class_method) try self.out.appendSlice(self.allocator, "self.");
        try self.out.appendSlice(self.allocator, def.name);
        if (def.params.len > 0) {
            try self.out.append(self.allocator, '(');
            for (def.params, 0..) |p, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                if (p.modifier) |mod| try self.out.appendSlice(self.allocator, getArgModifierStr(mod));
                try self.out.appendSlice(self.allocator, p.name);
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

    fn formatModuleStmt(self: *Formatter, tree: *const ast.Tree, m: ast.ModuleStmt, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "module ");
        try self.out.appendSlice(self.allocator, m.name);
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(tree, m.body);
    }

    fn formatLambda(self: *Formatter, tree: *const ast.Tree, l: ast.LambdaExpr, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "->");
        if (l.params.len > 0) {
            try self.out.append(self.allocator, '(');
            for (l.params, 0..) |p, i| {
                if (i > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, p.name);
            }
            try self.out.append(self.allocator, ')');
        }

        const body_node = tree.getNode(l.body).?;
        if (body_node.kind == .block) {
            try self.out.appendSlice(self.allocator, " ");
            try self.formatBlockClosure(tree, l.body, start_line);
        } else {
            try self.out.appendSlice(self.allocator, " { ");
            try self.formatNode(tree, l.body);
            try self.out.appendSlice(self.allocator, " }");
        }
    }

    fn formatNamespace(self: *Formatter, ns: anytype) Error!void {
        for (ns.path, 0..) |p, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, "::");
            try self.out.appendSlice(self.allocator, p);
        }
    }

    fn formatRange(self: *Formatter, tree: *const ast.Tree, r: ast.Range) Error!void {
        try self.formatNode(tree, r.start);
        try self.out.appendSlice(self.allocator, if (r.is_exclusive) "..." else "..");
        try self.formatNode(tree, r.end);
    }

    fn formatAssignment(self: *Formatter, tree: *const ast.Tree, a: ast.Assignment) Error!void {
        try self.out.appendSlice(self.allocator, a.name);
        try self.out.append(self.allocator, ' ');
        if (a.op) |op| try self.out.appendSlice(self.allocator, getBinaryOpStr(op));
        try self.out.appendSlice(self.allocator, "= ");
        try self.formatNode(tree, a.value);
    }

    fn formatMultipleAssignment(self: *Formatter, tree: *const ast.Tree, ma: ast.MultipleAssignment) Error!void {
        for (ma.lhs, 0..) |item, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
            if (item.modifier) |mod| try self.out.appendSlice(self.allocator, getArgModifierStr(mod));
            try self.out.appendSlice(self.allocator, item.name);
        }
        try self.out.appendSlice(self.allocator, " = ");
        try self.formatNode(tree, ma.value);
    }

    fn formatPropertyAssignment(self: *Formatter, tree: *const ast.Tree, pa: ast.PropertyAssignment) Error!void {
        try self.formatNode(tree, pa.target);
        try self.out.append(self.allocator, '.');
        try self.out.appendSlice(self.allocator, pa.property);
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
            if (r_node.kind == .method_call) {
                try self.ensureNewline();
                self.indent_level += 1;
                try self.writeIndent();
                self.indent_level -= 1;
            }
            try self.out.appendSlice(self.allocator, if (mc.is_safe) "&." else ".");
        }
        try self.out.appendSlice(self.allocator, mc.method_name);
        if (mc.args.len > 0) {
            try self.out.append(self.allocator, '(');
            for (mc.args, 0..) |arg, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                if (arg.modifier) |mod| try self.out.appendSlice(self.allocator, getArgModifierStr(mod));
                if (arg.name.len > 0) {
                    try self.out.appendSlice(self.allocator, arg.name);
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
        if (block_node.kind != .block) return;
        const b = block_node.kind.block;

        try self.out.appendSlice(self.allocator, "do");
        if (b.params.len > 0) {
            try self.out.appendSlice(self.allocator, " |");
            for (b.params, 0..) |p_idx, idx| {
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
        if (sc.args.len > 0) {
            try self.out.append(self.allocator, '(');
            for (sc.args, 0..) |arg, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                if (arg.name.len > 0) {
                    try self.out.appendSlice(self.allocator, arg.name);
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
            try self.formatNode(tree, val);
        }
    }

    fn formatYield(self: *Formatter, tree: *const ast.Tree, args: []const ast.NodeIndex) Error!void {
        try self.out.appendSlice(self.allocator, "yield");
        if (args.len > 0) {
            try self.out.append(self.allocator, ' ');
            for (args, 0..) |expr, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.formatNode(tree, expr);
            }
        }
    }

    fn formatImportExport(self: *Formatter, tree: *const ast.Tree, kw: []const u8, symbols: []const []const u8, path: []const u8, attrs: ast.NodeIndex) Error!void {
        try self.out.appendSlice(self.allocator, kw);
        try self.out.append(self.allocator, ' ');
        if (symbols.len > 0) {
            try self.out.appendSlice(self.allocator, "{ ");
            for (symbols, 0..) |sym, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, sym);
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

    fn formatParamDoc(self: *Formatter, tree: *const ast.Tree, doc: ast.ParamDoc) Error!void {
        try self.out.appendSlice(self.allocator, "# @");
        try self.out.appendSlice(self.allocator, doc.tag_name);

        var current_line_len: usize = self.indent_level * self.config.indent_width + 3 + doc.tag_name.len;

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

        if (doc.description.len > 0) try self.formatWrappedText(doc.description, &current_line_len);

        if (doc.options_expr != .none) {
            try self.out.append(self.allocator, ' ');
            try self.formatNode(tree, doc.options_expr);
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
    };
}

fn getArgModifierStr(mod: ast.ArgModifier) []const u8 {
    return switch (mod) {
        .splat => "*",
        .double_splat => "**",
        .block => "&",
    };
}
