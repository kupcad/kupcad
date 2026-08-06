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

    pub fn format(self: *Formatter, root: *ast.Node) ![]const u8 {
        try self.formatNode(root);
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

    fn formatBodyWithEnd(self: *Formatter, body: *ast.Node) Error!void {
        try self.ensureNewline();
        self.indent_level += 1;
        try self.formatNode(body);
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

    fn formatNode(self: *Formatter, node: *ast.Node) Error!void {
        try self.flushLeadingComments(node.loc.line);
        switch (node.kind) {
            .block => |b| try self.formatBlockStmts(b.stmts),
            .number => |n| {
                var buf: [64]u8 = undefined;
                try self.out.appendSlice(self.allocator, try std.fmt.bufPrint(&buf, "{d}", .{n}));
            },
            .string => |s| try self.formatWrappedString(s, '"'),
            .interpolated_string => |parts| try self.formatInterpolatedString(parts),
            .symbol => |s| try self.formatWrappedString(s, ':'),
            .boolean => |b| try self.out.appendSlice(self.allocator, if (b) "true" else "false"),
            .nil => try self.out.appendSlice(self.allocator, "nil"),
            .undef => try self.out.appendSlice(self.allocator, "undef"),
            .self_expr => try self.out.appendSlice(self.allocator, "self"),
            .identifier => |i| try self.out.appendSlice(self.allocator, i),
            .array_literal => |arr| try self.formatArray(arr),
            .hash_literal => |entries| try self.formatHash(entries),
            .if_stmt => |ifs| try self.formatIfStmt(ifs, node.loc.line),
            .while_stmt => |ws| try self.formatWhileStmt(ws, node.loc.line),
            .for_stmt => |fs| try self.formatForStmt(fs, node.loc.line),
            .case_stmt => |cs| try self.formatCaseStmt(cs, node.loc.line),
            .begin_stmt => |bs| try self.formatBeginStmt(bs, node.loc.line),
            .def_stmt => |def| try self.formatDefStmt(def, node.loc.line),
            .class_stmt => |cls| try self.formatClassStmt(cls, node.loc.line),
            .module_stmt => |m| try self.formatModuleStmt(m, node.loc.line),
            .lambda_expr => |l| try self.formatLambda(l, node.loc.line),
            .namespace_access => |ns| try self.formatNamespace(ns),
            .range => |r| try self.formatRange(r),
            .assignment => |a| try self.formatAssignment(a),
            .multiple_assignment => |ma| try self.formatMultipleAssignment(ma),
            .property_assignment => |pa| try self.formatPropertyAssignment(pa),
            .index_assignment => |ia| try self.formatIndexAssignment(ia),
            .index_access => |ia| try self.formatIndexAccess(ia),
            .binary_op => |b| try self.formatBinaryOp(b),
            .unary_op => |u| try self.formatUnaryOp(u),
            .ternary_op => |t| try self.formatTernaryOp(t),
            .splat_expr => |s| try self.formatSplat(s, "*"),
            .double_splat_expr => |s| try self.formatSplat(s, "**"),
            .each_expr => |e| try self.formatSplat(e, "each "),
            .rescue_modifier => |rm| try self.formatRescueModifier(rm),
            .method_call => |mc| try self.formatMethodCall(mc, node.loc.line),
            .super_call => |sc| try self.formatSuperCall(sc, node.loc.line),
            .return_stmt => |r| try self.formatFlowControl("return", r),
            .break_stmt => |b| try self.formatFlowControl("break", b),
            .next_stmt => |n| try self.formatFlowControl("next", n),
            .yield_stmt => |y| try self.formatYield(y),
            .import_stmt => |is| try self.formatImportExport("import", is.symbols, is.path, is.attributes),
            .export_stmt => |es| try self.formatImportExport("export", es.symbols, es.path, es.attributes),
            .param_doc => |doc| try self.formatParamDoc(doc),
            .comment => |c| try self.out.appendSlice(self.allocator, c),
        }
    }

    // --- Isolated Node Formatters ---

    fn formatBlockStmts(self: *Formatter, stmts: []const *ast.Node) Error!void {
        var temp_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer temp_arena.deinit();

        var print_stmts = stmts;
        for (self.rules.items) |rule| {
            print_stmts = rule.processBlockStmts(temp_arena.allocator(), print_stmts);
        }

        for (print_stmts, 0..) |stmt, idx| {
            if (idx > 0) {
                const prev_stmt = print_stmts[idx - 1];
                if (requiresBlankLineSeparation(prev_stmt) or requiresBlankLineSeparation(stmt)) {
                    try self.ensureBlankLine();
                }
            }

            // Flush comments BEFORE indenting the statement to keep indentation intact
            try self.flushLeadingComments(stmt.loc.line);

            if (self.isAtLineStartOrEmpty()) try self.writeIndent();
            try self.formatNode(stmt);
            try self.flushInlineComments(stmt.loc.line);
            try self.ensureNewline(); // Unconditionally ensure a newline
        }
    }

    fn formatWrappedString(self: *Formatter, s: []const u8, wrapper: u8) Error!void {
        if (wrapper == '"') try self.out.append(self.allocator, '"');
        if (wrapper == ':') try self.out.append(self.allocator, ':');
        try self.out.appendSlice(self.allocator, s);
        if (wrapper == '"') try self.out.append(self.allocator, '"');
    }

    fn formatInterpolatedString(self: *Formatter, parts: []const *ast.Node) Error!void {
        try self.out.append(self.allocator, '"');
        for (parts) |part| {
            if (part.kind == .string) {
                try self.out.appendSlice(self.allocator, part.kind.string);
            } else {
                try self.out.appendSlice(self.allocator, "#{");
                try self.formatNode(part);
                try self.out.append(self.allocator, '}');
            }
        }
        try self.out.append(self.allocator, '"');
    }

    fn formatArray(self: *Formatter, arr: []const *ast.Node) Error!void {
        if (arr.len == 0) return self.out.appendSlice(self.allocator, "[]");
        try self.out.append(self.allocator, '[');
        for (arr, 0..) |elem, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.formatNode(elem);
        }
        try self.out.append(self.allocator, ']');
    }

    fn formatHash(self: *Formatter, entries: []const ast.HashEntry) Error!void {
        if (entries.len == 0) return self.out.appendSlice(self.allocator, "{}");
        try self.out.appendSlice(self.allocator, "{ ");
        for (entries, 0..) |entry, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
            if (entry.key.kind == .double_splat_expr) {
                try self.formatNode(entry.key);
            } else if (entry.key.kind == .symbol and entry.value.kind == .identifier and std.mem.eql(u8, entry.key.kind.symbol, entry.value.kind.identifier)) {
                try self.out.appendSlice(self.allocator, entry.key.kind.symbol);
                try self.out.append(self.allocator, ':');
            } else {
                if (entry.key.kind == .symbol) {
                    try self.out.appendSlice(self.allocator, entry.key.kind.symbol);
                    try self.out.appendSlice(self.allocator, ": ");
                } else {
                    try self.formatNode(entry.key);
                    try self.out.appendSlice(self.allocator, " => ");
                }
                try self.formatNode(entry.value);
            }
        }
        try self.out.appendSlice(self.allocator, " }");
    }

    fn formatIfStmt(self: *Formatter, ifs: *ast.IfStmt, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, if (ifs.is_unless) "unless " else "if ");
        try self.formatNode(ifs.condition);
        try self.flushInlineComments(start_line);
        try self.ensureNewline();

        self.indent_level += 1;
        try self.formatNode(ifs.then_branch);
        self.indent_level -= 1;
        try self.ensureNewline(); // Force a newline before 'else' or 'end'

        if (ifs.else_branch) |eb| {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "else\n");
            self.indent_level += 1;
            try self.formatNode(eb);
            self.indent_level -= 1;
            try self.ensureNewline(); // Force a newline before 'end'
        }

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "end");
    }

    fn formatWhileStmt(self: *Formatter, ws: *ast.WhileStmt, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, if (ws.is_until) "until " else "while ");
        try self.formatNode(ws.condition);
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(ws.body);
    }

    fn formatForStmt(self: *Formatter, fs: *ast.ForStmt, start_line: u32) Error!void {
        const kw = if (fs.is_intersection) "intersection_for(" else "for(";
        try self.out.appendSlice(self.allocator, kw);
        for (fs.bindings, 0..) |b, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, b.name);
            try self.out.appendSlice(self.allocator, " = ");
            try self.formatNode(b.range);
        }
        try self.out.appendSlice(self.allocator, ")");
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(fs.body);
    }

    fn formatCaseStmt(self: *Formatter, cs: *ast.CaseStmt, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "case");
        if (cs.condition) |cond| {
            try self.out.append(self.allocator, ' ');
            try self.formatNode(cond);
        }
        try self.flushInlineComments(start_line);
        try self.out.append(self.allocator, '\n');

        for (cs.when_branches) |wb| {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "when ");
            for (wb.conditions, 0..) |cond, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.formatNode(cond);
            }
            try self.ensureNewline();
            self.indent_level += 1;
            try self.formatNode(wb.body);
            self.indent_level -= 1;
            try self.ensureNewline(); // Force a newline before the next 'when', 'else', or 'end'
        }

        if (cs.else_branch) |eb| {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "else\n");
            self.indent_level += 1;
            try self.formatNode(eb);
            self.indent_level -= 1;
            try self.ensureNewline(); // Force a newline before 'end'
        }

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "end");
    }

    fn formatBeginStmt(self: *Formatter, bs: *ast.BeginStmt, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "begin");
        try self.flushInlineComments(start_line);
        try self.out.append(self.allocator, '\n');

        self.indent_level += 1;
        try self.formatNode(bs.body);
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
            try self.formatNode(r.body);
            self.indent_level -= 1;
            try self.ensureNewline(); // Force a newline before the next 'rescue', 'ensure', or 'end'
        }

        if (bs.ensure_body) |eb| {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "ensure\n");
            self.indent_level += 1;
            try self.formatNode(eb);
            self.indent_level -= 1;
            try self.ensureNewline(); // Force a newline before 'end'
        }

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "end");
    }

    fn formatDefStmt(self: *Formatter, def: *ast.DefStmt, start_line: u32) Error!void {
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
                if (p.default_value) |dv| {
                    try self.out.appendSlice(self.allocator, if (p.is_keyword) " " else " = ");
                    try self.formatNode(dv);
                }
            }
            try self.out.append(self.allocator, ')');
        }
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(def.body);
    }

    fn formatClassStmt(self: *Formatter, cls: *ast.ClassStmt, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "class ");
        try self.formatNode(cls.name);
        if (cls.super_class) |sc| {
            try self.out.appendSlice(self.allocator, " < ");
            try self.formatNode(sc);
        }
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(cls.body);
    }

    fn formatModuleStmt(self: *Formatter, m: *ast.ModuleStmt, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "module ");
        try self.out.appendSlice(self.allocator, m.name);
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(m.body);
    }

    fn formatLambda(self: *Formatter, l: *ast.LambdaExpr, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "->");
        if (l.params.len > 0) {
            try self.out.append(self.allocator, '(');
            for (l.params, 0..) |p, i| {
                if (i > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, p.name);
            }
            try self.out.append(self.allocator, ')');
        }

        if (l.body.kind == .block) {
            try self.out.appendSlice(self.allocator, " ");
            try self.formatBlockClosure(l.body, start_line);
        } else {
            try self.out.appendSlice(self.allocator, " { ");
            try self.formatNode(l.body);
            try self.out.appendSlice(self.allocator, " }");
        }
    }

    fn formatNamespace(self: *Formatter, ns: anytype) Error!void {
        for (ns.path, 0..) |p, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, "::");
            try self.out.appendSlice(self.allocator, p);
        }
    }

    fn formatRange(self: *Formatter, r: *ast.Range) Error!void {
        try self.formatNode(r.start);
        try self.out.appendSlice(self.allocator, if (r.is_exclusive) "..." else "..");
        try self.formatNode(r.end);
    }

    fn formatAssignment(self: *Formatter, a: *ast.Assignment) Error!void {
        try self.out.appendSlice(self.allocator, a.name);
        try self.out.append(self.allocator, ' ');
        if (a.op) |op| try self.out.appendSlice(self.allocator, getBinaryOpStr(op));
        try self.out.appendSlice(self.allocator, "= ");
        try self.formatNode(a.value);
    }

    fn formatMultipleAssignment(self: *Formatter, ma: *ast.MultipleAssignment) Error!void {
        for (ma.lhs, 0..) |item, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
            if (item.modifier) |mod| try self.out.appendSlice(self.allocator, getArgModifierStr(mod));
            try self.out.appendSlice(self.allocator, item.name);
        }
        try self.out.appendSlice(self.allocator, " = ");
        try self.formatNode(ma.value);
    }

    fn formatPropertyAssignment(self: *Formatter, pa: *ast.PropertyAssignment) Error!void {
        try self.formatNode(pa.target);
        try self.out.append(self.allocator, '.');
        try self.out.appendSlice(self.allocator, pa.property);
        try self.out.append(self.allocator, ' ');
        if (pa.op) |op| try self.out.appendSlice(self.allocator, getBinaryOpStr(op));
        try self.out.appendSlice(self.allocator, "= ");
        try self.formatNode(pa.value);
    }

    fn formatIndexAssignment(self: *Formatter, ia: *ast.IndexAssignment) Error!void {
        try self.formatNode(ia.target);
        try self.out.append(self.allocator, '[');
        try self.formatNode(ia.index);
        try self.out.appendSlice(self.allocator, "] ");
        if (ia.op) |op| try self.out.appendSlice(self.allocator, getBinaryOpStr(op));
        try self.out.appendSlice(self.allocator, "= ");
        try self.formatNode(ia.value);
    }

    fn formatIndexAccess(self: *Formatter, ia: anytype) Error!void {
        try self.formatNode(ia.target);
        try self.out.append(self.allocator, '[');
        try self.formatNode(ia.index);
        try self.out.append(self.allocator, ']');
    }

    fn formatBinaryOp(self: *Formatter, b: *ast.BinaryExpr) Error!void {
        try self.formatNode(b.left);
        try self.out.append(self.allocator, ' ');
        try self.out.appendSlice(self.allocator, getBinaryOpStr(b.op));
        try self.out.append(self.allocator, ' ');
        try self.formatNode(b.right);
    }

    fn formatUnaryOp(self: *Formatter, u: anytype) Error!void {
        const op_str = switch (u.op) {
            .negate => "-",
            .positive => "+",
            .not => "!",
            .bitwise_not => "~",
        };
        try self.out.appendSlice(self.allocator, op_str);
        try self.formatNode(u.operand);
    }

    fn formatTernaryOp(self: *Formatter, t: *ast.TernaryExpr) Error!void {
        try self.formatNode(t.condition);
        try self.out.appendSlice(self.allocator, " ? ");
        try self.formatNode(t.then_branch);
        try self.out.appendSlice(self.allocator, " : ");
        try self.formatNode(t.else_branch);
    }

    fn formatSplat(self: *Formatter, node: *ast.Node, prefix: []const u8) Error!void {
        try self.out.appendSlice(self.allocator, prefix);
        try self.formatNode(node);
    }

    fn formatRescueModifier(self: *Formatter, rm: anytype) Error!void {
        try self.formatNode(rm.expr);
        try self.out.appendSlice(self.allocator, " rescue ");
        try self.formatNode(rm.rescue_expr);
    }

    fn formatMethodCall(self: *Formatter, mc: *ast.MethodCall, start_line: u32) Error!void {
        if (mc.receiver) |r| {
            try self.formatNode(r);
            // Multi-line indentation alignment for fluent method chains
            if (r.kind == .method_call) {
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
                try self.formatNode(arg.value);
            }
            try self.out.append(self.allocator, ')');
        } else if (mc.receiver == null and mc.block == null) {
            try self.out.appendSlice(self.allocator, "()");
        }
        if (mc.block) |block_node| {
            try self.out.append(self.allocator, ' ');
            try self.formatBlockClosure(block_node, start_line);
        }
    }

    fn formatBlockClosure(self: *Formatter, block_node: *ast.Node, start_line: u32) Error!void {
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
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(block_node);
    }

    fn formatSuperCall(self: *Formatter, sc: *ast.SuperCall, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "super");
        if (sc.args.len > 0) {
            try self.out.append(self.allocator, '(');
            for (sc.args, 0..) |arg, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                if (arg.name.len > 0) {
                    try self.out.appendSlice(self.allocator, arg.name);
                    try self.out.appendSlice(self.allocator, ": ");
                }
                try self.formatNode(arg.value);
            }
            try self.out.append(self.allocator, ')');
        }
        if (sc.block) |b| {
            try self.out.append(self.allocator, ' ');
            try self.formatBlockClosure(b, start_line);
        }
    }

    fn formatFlowControl(self: *Formatter, kw: []const u8, val: ?*ast.Node) Error!void {
        try self.out.appendSlice(self.allocator, kw);
        if (val) |expr| {
            try self.out.append(self.allocator, ' ');
            try self.formatNode(expr);
        }
    }

    fn formatYield(self: *Formatter, args: []const *ast.Node) Error!void {
        try self.out.appendSlice(self.allocator, "yield");
        if (args.len > 0) {
            try self.out.append(self.allocator, ' ');
            for (args, 0..) |expr, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.formatNode(expr);
            }
        }
    }

    fn formatImportExport(self: *Formatter, kw: []const u8, symbols: []const []const u8, path: []const u8, attrs: ?*ast.Node) Error!void {
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

        if (attrs) |attr| {
            try self.out.appendSlice(self.allocator, " with ");
            try self.formatNode(attr);
        }
    }

    fn formatParamDoc(self: *Formatter, doc: *ast.ParamDoc) Error!void {
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

        if (doc.options_expr) |opts| {
            try self.out.append(self.allocator, ' ');
            try self.formatNode(opts);
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
