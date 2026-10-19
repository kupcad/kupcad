//! `Formatter`: prints a parsed script back as source in the house style, keeping its
//! comments and literals as written, and laying out a call, list or chain over several lines
//! when it won't fit the configured line width. Used by api.zig's `formatDocument`.

const std = @import("std");
const ast = @import("../../core/ast.zig");
const token = @import("../../core/token.zig");
const LineIndex = @import("../../core/line_index.zig").LineIndex;
const Document = @import("../../core/document.zig").Document;
const Config = @import("config.zig").Config;
const parser = @import("../../frontend/parser.zig");
const Precedence = parser.Precedence;
const token_span = @import("../../core/token_span.zig");
const string_escape = @import("../../core/string_escape.zig");
const TokenTag = @import("../../frontend/lexer.zig").Tag;
const FormatRule = @import("rules/rule.zig").FormatRule;
const SortImportsRule = @import("rules/sort_imports.zig").SortImportsRule;

pub const Formatter = struct {
    pub const Error = error{ OutOfMemory, NoSpaceLeft, SyntaxError };

    allocator: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    /// The text being formatted: literals are printed as written.
    source: []const u8,
    token_starts: []const u32,
    token_lengths: []const u32,
    token_tags: []const TokenTag,
    /// The heredocs' bodies, in the order of their openers.
    heredocs: []const token.Heredoc,
    line_index: *const LineIndex,
    comments: []const token.Comment,
    config: Config,
    rules: std.ArrayList(FormatRule) = .empty,

    comment_idx: usize = 0,
    indent_level: usize = 0,
    /// Set while a construct is printed on one line to measure it (layOut): everything
    /// inside it is then printed flat too, and decides nothing on its own.
    flat: bool = false,

    sort_imports_rule: SortImportsRule = .{},

    /// A formatter for a parsed document: its source, tokens, line index and comments.
    pub fn forDocument(allocator: std.mem.Allocator, doc: *const Document, config: Config) Formatter {
        return init(allocator, doc.source, doc.tokens, &doc.line_index, doc.comments, config);
    }

    pub fn init(allocator: std.mem.Allocator, source: []const u8, tokens: token.TokenList(TokenTag), line_index: *const LineIndex, comments: []const token.Comment, config: Config) Formatter {
        return .{
            .allocator = allocator,
            .source = source,
            .token_starts = tokens.starts,
            .token_lengths = tokens.lengths,
            .token_tags = tokens.tags,
            .heredocs = tokens.heredocs,
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

    /// The line of a block's closing token, or past every line for one that closes at the
    /// end of the file (the script's own block): a last comment with no newline after it
    /// shares the end-of-file token's line, and was glued to the statement above it.
    fn blockEndLine(self: *const Formatter, end_token: u32) u32 {
        if (end_token >= self.token_starts.len or self.token_starts[end_token] == self.source.len) return std.math.maxInt(u32);
        return self.line_index.getLine(self.token_starts[end_token]);
    }

    fn lineOf(self: *const Formatter, tok: u32) u32 {
        if (tok >= self.token_starts.len) return std.math.maxInt(u32);
        return self.line_index.getLine(self.token_starts[tok]);
    }

    /// The column the next character lands in, counting characters, not bytes.
    fn column(self: *const Formatter) usize {
        const line = self.out.items[if (std.mem.findScalarLast(u8, self.out.items, '\n')) |nl| nl + 1 else 0..];
        return std.unicode.utf8CountCodepoints(line) catch line.len;
    }

    /// Prints a construct on one line if it fits within `line_width` and the author didn't
    /// break it over lines, else over lines: `layout` has `flat` and `broken` methods. A
    /// construct that can't be one line (it holds a body, a comment, or one of its own the
    /// author broke) is laid out over lines, so the author's breaks carry outward.
    fn layOut(self: *Formatter, author_broke: bool, layout: anytype) Error!void {
        if (author_broke) return layout.broken(self);
        // Inside a construct being measured, everything is flat: the outer one decides.
        if (self.flat) return layout.flat(self);

        const mark = self.out.items.len;
        const comment_mark = self.comment_idx;
        self.flat = true;
        layout.flat(self) catch |err| {
            self.flat = false;
            return err;
        };
        self.flat = false;
        if (std.mem.findScalar(u8, self.out.items[mark..], '\n') == null and self.column() <= self.config.line_width) return;
        self.out.shrinkRetainingCapacity(mark);
        self.comment_idx = comment_mark;
        return layout.broken(self);
    }

    fn tokenText(self: *const Formatter, tok: u32) []const u8 {
        const start = self.token_starts[tok];
        return self.source[start..][0..self.token_lengths[tok]];
    }

    inline fn getNodeLine(self: *Formatter, node: *const ast.Node) u32 {
        if (node.main_token >= self.token_starts.len) return 0;
        return self.lineOf(node.main_token);
    }

    /// The line of a statement's last token, so comments trailing any of its lines stay
    /// with it, even after it is laid out over a different number of lines.
    fn lastLine(self: *Formatter, tree: *const ast.Tree, node_idx: ast.NodeIndex) u32 {
        const last = token_span.last(tree, node_idx);
        if (last >= self.token_starts.len) return 0;
        return self.tokenEndLine(last);
    }

    /// The line a token ends on: a string may run over several (its start line was taken,
    /// so the statement after a multi-line string got a blank line it never had), and a
    /// line with heredoc openers goes on to their terminator lines.
    fn tokenEndLine(self: *const Formatter, tok: u32) u32 {
        const start = self.token_starts[tok];
        const len = self.token_lengths[tok];
        return self.pastHeredocs(self.line_index.getLine(if (len == 0) start else start + len - 1));
    }

    /// `line`, or the terminator line of the last heredoc opened on it: the bodies come
    /// after the line, so what follows starts after them.
    fn pastHeredocs(self: *const Formatter, line: u32) u32 {
        // The heredocs opened on or before `line`, by binary search: they are in source order.
        const upto = std.sort.partitionPoint(token.Heredoc, self.heredocs, Opened{ .formatter = self, .line = line }, Opened.onOrBefore);
        if (upto == 0) return line;
        const last = self.heredocs[upto - 1];
        if (self.lineOf(last.token) != line) return line;
        return self.line_index.getLine(last.bodyEnd());
    }

    const Opened = struct {
        formatter: *const Formatter,
        line: u32,

        fn onOrBefore(self: Opened, heredoc: token.Heredoc) bool {
            return self.formatter.lineOf(heredoc.token) <= self.line;
        }
    };

    /// The line a block body starts on: its first statement's, or its closing keyword's
    /// when it is empty.
    fn blockFirstLine(self: *const Formatter, tree: *const ast.Tree, body: ast.NodeIndex) u32 {
        const node = tree.getNode(body) orelse return std.math.maxInt(u32);
        if (node.tag != .block) return self.lineOf(token_span.first(tree, body));
        const b = tree.block(node);
        const stmts = tree.getNodes(b.stmts);
        if (stmts.len > 0) return self.lineOf(token_span.first(tree, stmts[0]));
        return self.blockEndLine(b.end_token);
    }

    /// Whether a comment follows code on its line (`when 1 # one`), as opposed to
    /// standing on a line of its own.
    fn isInlineComment(self: *const Formatter, c: token.Comment) bool {
        const before = self.source[0..c.loc.offset];
        const line_start = if (std.mem.findScalarLast(u8, before, '\n')) |nl| nl + 1 else 0;
        return std.mem.trim(u8, before[line_start..], " \t\r").len > 0;
    }

    /// For each statement: whether a comment sits on its lines or between it and the
    /// statement before it (what a rule that reorders statements must leave alone).
    fn commentedStatements(self: *Formatter, allocator: std.mem.Allocator, tree: *const ast.Tree, stmts: []const ast.NodeIndex) Error![]const bool {
        const commented = try allocator.alloc(bool, stmts.len);
        var ci = self.comment_idx;
        var prev_last: ?u32 = null;
        for (stmts, commented) |stmt, *flag| {
            const first = self.lineOf(token_span.first(tree, stmt));
            const last = self.lastLine(tree, stmt);
            flag.* = false;
            while (ci < self.comments.len and self.getCommentLine(self.comments[ci]) <= last) : (ci += 1) {
                const line = self.getCommentLine(self.comments[ci]);
                if (line >= first or (prev_last != null and line > prev_last.?)) flag.* = true;
            }
            prev_last = last;
        }
        return commented;
    }

    /// The comment written after a clause keyword (`when 1 # one`, `rescue => e # oops`,
    /// `else # other`): the next comment, when it follows code on a line before `body`
    /// starts. It used to open the body on a line of its own.
    fn flushHeaderComment(self: *Formatter, tree: *const ast.Tree, body: ast.NodeIndex) Error!void {
        if (self.comment_idx >= self.comments.len) return;
        const c = self.comments[self.comment_idx];
        if (self.getCommentLine(c) >= self.blockFirstLine(tree, body) or !self.isInlineComment(c)) return;
        try self.out.append(self.allocator, ' ');
        try self.out.appendSlice(self.allocator, c.lexeme);
        try self.out.append(self.allocator, '\n');
        self.comment_idx += 1;
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
        return self.formatBodyClosedBy(tree, body, "end");
    }

    /// An indented body on lines of its own, then `closer` (`end`, or `}` of a block).
    fn formatBodyClosedBy(self: *Formatter, tree: *const ast.Tree, body: ast.NodeIndex, closer: []const u8) Error!void {
        try self.ensureNewline();
        self.indent_level += 1;
        try self.formatNode(tree, body);
        self.indent_level -= 1;
        try self.ensureNewline(); // Force a newline before the closer
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, closer);
    }

    /// Writes the comments above `up_to_line`, each on its own line.
    fn flushLeadingComments(self: *Formatter, up_to_line: u32) Error!void {
        while (self.comment_idx < self.comments.len) {
            const c = self.comments[self.comment_idx];
            if (self.getCommentLine(c) >= up_to_line) break;
            try self.writeOwnLineComment(c);
        }
    }

    /// Writes the comments above the statement on `stmt_line`, keeping each gap of blank
    /// lines in the source as one blank line, so a script keeps its sections (it used to
    /// lose them all). `prev_line` is the previous statement's last line; without one (the
    /// first statement of a block) no blank line is added before the first comment.
    fn flushCommentsBeforeStatement(self: *Formatter, stmt_line: u32, prev_line: ?u32) Error!void {
        try self.flushCommentsBefore(stmt_line, prev_line, true);
    }

    /// The comments above `line`, keeping gaps between them; `gap_before_line` also keeps
    /// one between the last comment and `line` (not wanted right before `end`).
    fn flushCommentsBefore(self: *Formatter, line: u32, prev_line: ?u32, comptime gap_before_line: bool) Error!void {
        var above = prev_line;
        while (self.comment_idx < self.comments.len) {
            const c = self.comments[self.comment_idx];
            const c_line = self.getCommentLine(c);
            if (c_line >= line) break;
            if (above) |a| if (c_line > a + 1) try self.ensureBlankLine();
            try self.writeOwnLineComment(c);
            above = c_line;
        }
        if (gap_before_line) {
            if (above) |a| if (line > a + 1) try self.ensureBlankLine();
        }
    }

    fn writeOwnLineComment(self: *Formatter, c: token.Comment) Error!void {
        if (self.isAtLineStartOrEmpty()) try self.writeIndent();
        try self.out.appendSlice(self.allocator, c.lexeme);
        try self.out.append(self.allocator, '\n');
        self.comment_idx += 1;
    }

    fn flushInlineComments(self: *Formatter, exact_line: u32) Error!void {
        try self.flushTrailingComments(exact_line, exact_line);
    }

    /// Writes the comments on lines `first_line` through `last_line` after what was just
    /// printed: the first on the same line, any others below it.
    fn flushTrailingComments(self: *Formatter, first_line: u32, last_line: u32) Error!void {
        while (self.comment_idx < self.comments.len) {
            const c = self.comments[self.comment_idx];
            const c_line = self.getCommentLine(c);
            if (c_line >= first_line and c_line <= last_line) {
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

    /// Prints a node, in the parentheses the author put around it (they used to be dropped
    /// unless the meaning needed them: `d + (w * 2)` became `d + w * 2`).
    fn formatNode(self: *Formatter, tree: *const ast.Tree, node_idx: ast.NodeIndex) Error!void {
        if (!tree.isGrouped(node_idx)) return self.formatUngrouped(tree, node_idx);
        try self.out.append(self.allocator, '(');
        try self.formatUngrouped(tree, node_idx);
        try self.out.append(self.allocator, ')');
    }

    fn formatUngrouped(self: *Formatter, tree: *const ast.Tree, node_idx: ast.NodeIndex) Error!void {
        if (node_idx == .none) return;
        const node = tree.getNode(node_idx) orelse return;
        // Comments are placed by blocks only: a statement takes those up to its last line,
        // and a block those before its closing keyword. Written here, before any
        // sub-expression, they landed mid-expression: `.rotate(z: # note` + newline + `5)`.
        const node_line = self.getNodeLine(node);

        switch (node.tag) {
            .invalid => return error.SyntaxError,
            .block => {
                const b = tree.block(node);
                const end_line = self.blockEndLine(b.end_token);
                try self.formatBlockStmts(tree, tree.getNodes(b.stmts), end_line);
            },
            // As written: `20.0` stays `20.0` (it used to print as `20`), `1_000` and `1e3` keep
            // their form. The value can't change: equivalence checks it.
            .number => try self.out.appendSlice(self.allocator, self.tokenText(node.main_token)),
            .string => try self.formatString(tree, node),
            .interpolated_string => {
                const parts = tree.nodeSpan(node);
                try self.formatInterpolatedString(tree, tree.getNodes(parts));
            },
            .symbol => try self.formatSymbol(tree, node),
            .boolean => {
                const b = tree.boolean(node);
                try self.out.appendSlice(self.allocator, if (b) "true" else "false");
            },
            .nil => try self.out.appendSlice(self.allocator, "nil"),
            .self_expr => try self.out.appendSlice(self.allocator, "self"),
            .identifier => try self.out.appendSlice(self.allocator, tree.getString(@fromBackingInt(node.data))),
            .array_literal => {
                const items = try self.arrayItems(tree, tree.getNodes(tree.nodeSpan(node)));
                defer self.allocator.free(items);
                try self.formatList(tree, items, .{ .open = "[", .close = "]" }, node.main_token, tree.arrayLiteral(node).end_token);
            },
            .hash_literal => {
                const items = try self.hashItems(tree, tree.getHashEntries(tree.nodeSpan(node)));
                defer self.allocator.free(items);
                try self.formatList(tree, items, .{ .open = "{", .close = "}", .padded = true }, node.main_token, tree.hashEndToken(node));
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
            .rescue_modifier => try self.formatRescueModifier(tree, tree.rescueModifier(node)),
            .method_call => {
                const mc = tree.methodCall(node);
                const method_name = tree.getString(mc.method_name);

                // Route `yield` back to its dedicated formatter
                if (std.mem.eql(u8, method_name, "yield") and mc.receiver == .none) {
                    try self.formatYield(tree, mc);
                } else {
                    try self.formatMethodCall(tree, node_idx);
                }
            },
            .super_call => try self.formatSuperCall(tree, tree.superCall(node), node_line),
            .return_stmt => try self.formatFlowControl(tree, "return", tree.nodeIndex(node)),
            .break_stmt => try self.formatFlowControl(tree, "break", tree.nodeIndex(node)),
            .next_stmt => try self.formatFlowControl(tree, "next", tree.nodeIndex(node)),
            .import_stmt => {
                const is_stmt = tree.importStmt(node);
                try self.formatImportExport(tree, "import", tree.getAliasPairs(is_stmt.symbols), is_stmt.braced, tree.getString(is_stmt.path), is_stmt.attributes);
            },
            .export_stmt => {
                const es_stmt = tree.exportStmt(node);
                // `export { a }` has no path: it used to print `from ""`, written by no one.
                const path: ?[]const u8 = if (es_stmt.path == .none) null else tree.getString(es_stmt.path);
                try self.formatImportExport(tree, "export", tree.getAliasPairs(es_stmt.symbols), es_stmt.braced, path, es_stmt.attributes);
            },
            .docstring => try self.formatDocString(tree, tree.docString(node)),
        }
    }

    // --- Isolated Node Formatters ---

    /// `end_line` is the line of the keyword that closes the block (`end`, `else`, `when`,
    /// ...); comments above it stay inside the block.
    fn formatBlockStmts(self: *Formatter, tree: *const ast.Tree, stmts: []const ast.NodeIndex, end_line: u32) Error!void {
        var temp_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer temp_arena.deinit();

        const commented = try self.commentedStatements(temp_arena.allocator(), tree, stmts);
        var print_stmts = stmts;
        for (self.rules.items) |rule| {
            print_stmts = rule.processBlockStmts(temp_arena.allocator(), tree, print_stmts, commented);
        }

        // Lines come from the statement at the same position in the source: a rule may
        // have swapped statements (sorted imports), and the comments and blank lines
        // between positions are the source's. (The sorted import's own line was used, so
        // a header comment got a blank line below it.)
        var prev_last_line: u32 = 0;
        for (print_stmts, 0..) |stmt_idx, idx| {
            const stmt = tree.getNode(stmt_idx).?;
            const stmt_line = self.getNodeLine(tree.getNode(stmts[idx]).?);

            if (idx > 0) {
                const prev_stmt = tree.getNode(print_stmts[idx - 1]).?;

                if (stmt_line == prev_last_line and !self.isAtLineStartOrEmpty()) {
                    // Same line in original source! Emit a single semicolon.
                    try self.out.appendSlice(self.allocator, "; ");
                } else {
                    // Different lines, proceed with normal vertical formatting
                    if (requiresBlankLineSeparation(prev_stmt) or requiresBlankLineSeparation(stmt)) {
                        try self.ensureBlankLine();
                    } else {
                        try self.ensureNewline();
                    }
                    try self.flushCommentsBeforeStatement(stmt_line, prev_last_line);
                    if (self.isAtLineStartOrEmpty()) try self.writeIndent();
                }
            } else {
                try self.flushCommentsBeforeStatement(stmt_line, null);
                if (self.isAtLineStartOrEmpty()) try self.writeIndent();
            }

            try self.formatNode(tree, stmt_idx);

            // A comment ends its line, so it forces a newline. Every comment trailing a line
            // of the statement belongs to it: one after `.translate(...)` on the second line
            // of a chain used to move below it on each run.
            prev_last_line = self.lastLine(tree, stmts[idx]);
            try self.flushTrailingComments(stmt_line, prev_last_line);
        }

        // Comments after the last statement belong to this block, not to whatever follows
        // it: one above `end` used to move below it, one above `else` into the else branch.
        if (self.comment_idx < self.comments.len and self.getCommentLine(self.comments[self.comment_idx]) < end_line) {
            try self.ensureNewline();
            try self.flushCommentsBefore(end_line, if (print_stmts.len > 0) prev_last_line else null, false);
        }
    }

    /// The source text of a string piece (the token is the content between its
    /// delimiters, escapes as written) when it still decodes to the node's value; null
    /// when there is none to reuse (a `%w[a b]` word shares the whole literal's token).
    fn rawStringText(self: *Formatter, tree: *const ast.Tree, node: *const ast.Node) Error!?[]const u8 {
        if (node.main_token >= self.token_starts.len) return null;
        if (self.token_tags[node.main_token] == .heredoc) return null; // its token is the opener, `<<~NAME`
        const raw = self.tokenText(node.main_token);
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(self.allocator);
        if (self.token_tags[node.main_token] == .raw_string) {
            // Single-quoted or %q, decoded by its own delimiter, the byte before it
            try string_escape.unescapeRawInto(&decoded, self.allocator, raw, self.source[self.token_starts[node.main_token] - 1]);
        } else {
            var problem: string_escape.Problem = undefined;
            string_escape.unescapeInto(&decoded, self.allocator, raw, &problem) catch |err| switch (err) {
                // The parser refused it already; there is nothing to reuse
                error.InvalidEscape => return null,
                error.OutOfMemory => |e| return e,
            };
        }
        return if (std.mem.eql(u8, decoded.items, tree.getString(@fromBackingInt(node.data)))) raw else null;
    }

    /// The quote that opened a string or symbol token, if one did: the byte before it.
    fn openingQuote(self: *const Formatter, tok: u32) ?u8 {
        const start = self.token_starts[tok];
        if (start == 0) return null;
        const before = self.source[start - 1];
        return if (before == '"' or before == '\'') before else null;
    }

    /// A string literal as the author wrote it, in its own quotes, escapes included. The
    /// decoded value used to be printed, so `"x\ty"` came out with a real TAB in it and
    /// `'a'` as `"a"`. One with no source text to reuse (a heredoc body, a `%w` word) is
    /// written as a double-quoted literal with the value escaped.
    fn formatString(self: *Formatter, tree: *const ast.Tree, node: *const ast.Node) Error!void {
        if (try self.rawStringText(tree, node)) |raw| {
            if (self.openingQuote(node.main_token)) |quote| {
                try self.out.append(self.allocator, quote);
                try self.out.appendSlice(self.allocator, raw);
                try self.out.append(self.allocator, quote);
                return;
            }
        }
        try self.out.append(self.allocator, '"');
        try string_escape.appendEscaped(&self.out, self.allocator, tree.getString(@fromBackingInt(node.data)));
        try self.out.append(self.allocator, '"');
    }

    /// `:name`, or a quoted symbol (`:"with space"`) in its quotes; it used to lose them.
    fn formatSymbol(self: *Formatter, tree: *const ast.Tree, node: *const ast.Node) Error!void {
        const name = tree.getString(@fromBackingInt(node.data));
        try self.out.append(self.allocator, ':');
        const quote: ?u8 = if (node.main_token < self.token_starts.len and std.mem.eql(u8, self.tokenText(node.main_token), name)) self.openingQuote(node.main_token) else null;
        if (quote) |q| try self.out.append(self.allocator, q);
        try self.out.appendSlice(self.allocator, name);
        if (quote) |q| try self.out.append(self.allocator, q);
    }

    /// Whether a String part of an interpolated string is one of its pieces between `"`, `}`
    /// and `#{`, not a String written inside `#{...}`: both are String nodes, and
    /// `"#{"a"}"` was printed as `"a"`, which isn't interpolated.
    fn isStringSegment(self: *const Formatter, part: *const ast.Node) bool {
        if (part.main_token >= self.token_tags.len) return false;
        return switch (self.token_tags[part.main_token]) {
            .string_start, .string_mid, .string_end => true,
            else => false,
        };
    }

    fn formatInterpolatedString(self: *Formatter, tree: *const ast.Tree, parts: []const ast.NodeIndex) Error!void {
        try self.out.append(self.allocator, '"');
        var after_segment = false;
        for (parts) |part_idx| {
            const part = tree.getNode(part_idx).?;
            if (part.tag == .string and self.isStringSegment(part)) {
                // Two pieces in a row had an empty `#{}` between them, which is no part of
                // its own; without it the string would print as a plain one
                if (after_segment) try self.out.appendSlice(self.allocator, "#{}");
                after_segment = true;
                // The piece between the delimiters, `}` and `#{`, as written (it was decoded)
                if (try self.rawStringText(tree, part)) |raw| {
                    try self.out.appendSlice(self.allocator, raw);
                } else {
                    try string_escape.appendEscaped(&self.out, self.allocator, tree.getString(@fromBackingInt(part.data)));
                }
            } else {
                after_segment = false;
                try self.out.appendSlice(self.allocator, "#{");
                try self.formatNode(tree, part_idx);
                try self.out.append(self.allocator, '}');
            }
        }
        try self.out.append(self.allocator, '"');
    }

    // --- Lists: arrays, maps, call arguments ---

    /// One item of a list, with the tokens it spans in the source.
    const ListItem = struct {
        first: u32,
        last: u32,
        value: union(enum) {
            element: ast.NodeIndex,
            entry: ast.HashEntry,
            arg: ast.NamedArg,
        },
    };

    const ListShape = struct {
        open: []const u8,
        close: []const u8,
        /// A space inside the brackets on one line: `{ a: 1 }`.
        padded: bool = false,
        /// A last item that is a list or a lambda may open up in place instead of moving to
        /// its own line: `inspect("Bounds:", [` ... `])` (call arguments, as Prettier does).
        hug_last: bool = false,
    };

    fn arrayItems(self: *Formatter, tree: *const ast.Tree, elements: []const ast.NodeIndex) Error![]ListItem {
        const items = try self.allocator.alloc(ListItem, elements.len);
        for (elements, items) |e, *item| item.* = .{ .first = token_span.first(tree, e), .last = token_span.last(tree, e), .value = .{ .element = e } };
        return items;
    }

    fn hashItems(self: *Formatter, tree: *const ast.Tree, entries: []const ast.HashEntry) Error![]ListItem {
        const items = try self.allocator.alloc(ListItem, entries.len);
        for (entries, items) |e, *item| item.* = .{ .first = token_span.first(tree, e.key), .last = token_span.last(tree, e.value), .value = .{ .entry = e } };
        return items;
    }

    fn argItems(self: *Formatter, tree: *const ast.Tree, args: []const ast.NamedArg) Error![]ListItem {
        const items = try self.allocator.alloc(ListItem, args.len);
        for (args, items) |arg, *item| {
            var first = token_span.first(tree, arg.value);
            // The keyword (`size:` is two tokens) and a modifier (`*`) come before the value.
            if (arg.name != .none and first >= 2) first -= 2;
            if (arg.modifier != null and first >= 1) first -= 1;
            item.* = .{ .first = first, .last = token_span.last(tree, arg.value), .value = .{ .arg = arg } };
        }
        return items;
    }

    /// Prints a list on one line if it fits, else one item per line; a list the author
    /// broke over lines keeps the author's rows (a matrix written row by row stays so; it
    /// used to be flattened). `open_token` and `close_token` are its brackets.
    fn formatList(self: *Formatter, tree: *const ast.Tree, items: []const ListItem, shape: ListShape, open_token: u32, close_token: ?u32) Error!void {
        if (items.len == 0) {
            try self.out.appendSlice(self.allocator, shape.open);
            return self.out.appendSlice(self.allocator, shape.close);
        }
        const Layout = struct {
            tree: *const ast.Tree,
            items: []const ListItem,
            shape: ListShape,
            close_token: ?u32,
            author_rows: bool,

            fn flat(l: @This(), f: *Formatter) Error!void {
                try f.out.appendSlice(f.allocator, l.shape.open);
                if (l.shape.padded) try f.out.append(f.allocator, ' ');
                for (l.items, 0..) |item, i| {
                    if (i > 0) try f.out.appendSlice(f.allocator, ", ");
                    try f.formatListItem(l.tree, item);
                }
                if (l.shape.padded) try f.out.append(f.allocator, ' ');
                try f.out.appendSlice(f.allocator, l.shape.close);
            }

            fn broken(l: @This(), f: *Formatter) Error!void {
                if (l.shape.hug_last and !l.author_rows and try l.hugged(f)) return;
                try f.out.appendSlice(f.allocator, l.shape.open);
                f.indent_level += 1;
                var prev_line: ?u32 = null;
                var i: usize = 0;
                while (i < l.items.len) {
                    // The author's row: the items that start on the line the one before ends.
                    var end = i + 1;
                    if (l.author_rows) {
                        while (end < l.items.len and f.lineOf(l.items[end].first) == f.lineOf(l.items[end - 1].last)) end += 1;
                    }
                    const first_line = f.lineOf(l.items[i].first);
                    try f.ensureNewline();
                    try f.flushCommentsBefore(first_line, prev_line, false);
                    try f.writeIndent();
                    for (l.items[i..end], 0..) |item, k| {
                        if (k > 0) try f.out.appendSlice(f.allocator, ", ");
                        try f.formatListItem(l.tree, item);
                    }
                    try f.out.append(f.allocator, ',');
                    prev_line = f.lineOf(l.items[end - 1].last);
                    try f.flushTrailingComments(first_line, prev_line.?);
                    i = end;
                }
                try f.ensureNewline();
                // At the items' indent, as a block's before its `end`: written after the
                // indent dropped, they moved out to the bracket's when formatted again
                // (an own-line comment after the last item is still the list's)
                if (l.close_token) |close| try f.flushCommentsBefore(f.lineOf(close), prev_line, false);
                f.indent_level -= 1;
                try f.writeIndent();
                try f.out.appendSlice(f.allocator, l.shape.close);
            }

            /// The items before the last on the opening line, and the last opening up there.
            /// False (and nothing written) when they don't fit, or the last would stay on one
            /// line anyway, so hugging saves nothing.
            fn hugged(l: @This(), f: *Formatter) Error!bool {
                const last = l.items[l.items.len - 1];
                if (!huggable(l.tree, last)) return false;
                const mark = f.out.items.len;
                const comment_mark = f.comment_idx;
                try f.out.appendSlice(f.allocator, l.shape.open);
                f.flat = true;
                for (l.items[0 .. l.items.len - 1]) |item| {
                    f.formatListItem(l.tree, item) catch |err| {
                        f.flat = false;
                        return err;
                    };
                    try f.out.appendSlice(f.allocator, ", ");
                }
                f.flat = false;
                const prefix_fits = std.mem.findScalar(u8, f.out.items[mark..], '\n') == null and f.column() < f.config.line_width;
                if (prefix_fits) {
                    const last_start = f.out.items.len;
                    try f.formatListItem(l.tree, last);
                    if (std.mem.findScalar(u8, f.out.items[last_start..], '\n') != null) {
                        try f.out.appendSlice(f.allocator, l.shape.close);
                        return true;
                    }
                }
                f.out.shrinkRetainingCapacity(mark);
                f.comment_idx = comment_mark;
                return false;
            }

            fn huggable(t: *const ast.Tree, item: ListItem) bool {
                const value = switch (item.value) {
                    .arg => |arg| if (arg.modifier == null) arg.value else return false,
                    .element => |e| e,
                    .entry => return false,
                };
                const node = t.getNode(value) orelse return false;
                return switch (node.tag) {
                    .array_literal, .hash_literal, .lambda_expr => true,
                    else => false,
                };
            }
        };
        const broke = self.authorBroke(items, open_token);
        try self.layOut(broke, Layout{ .tree = tree, .items = items, .shape = shape, .close_token = close_token, .author_rows = broke });
    }

    /// Whether an item starts on a later line than the bracket or the item before it ends.
    fn authorBroke(self: *const Formatter, items: []const ListItem, open_token: u32) bool {
        var prev = self.lineOf(open_token);
        for (items) |item| {
            if (self.lineOf(item.first) != prev) return true;
            prev = self.lineOf(item.last);
        }
        return false;
    }

    fn formatListItem(self: *Formatter, tree: *const ast.Tree, item: ListItem) Error!void {
        switch (item.value) {
            .element => |e| try self.formatNode(tree, e),
            .arg => |arg| {
                if (arg.modifier) |mod| try self.out.appendSlice(self.allocator, getArgModifierStr(mod));
                if (arg.name != .none) {
                    try self.out.appendSlice(self.allocator, tree.getString(arg.name));
                    try self.out.appendSlice(self.allocator, ": ");
                }
                // The call's parentheses already hold it: `f((x))` is `f(x)`.
                try self.formatUngrouped(tree, arg.value);
            },
            .entry => |entry| {
                const key_node = tree.getNode(entry.key).?;
                const val_node = tree.getNode(entry.value).?;
                if (key_node.tag == .double_splat_expr) {
                    try self.formatNode(tree, entry.key);
                } else if (key_node.tag == .symbol and val_node.tag == .identifier and std.mem.eql(u8, tree.getString(@fromBackingInt(key_node.data)), tree.getString(@fromBackingInt(val_node.data)))) {
                    try self.out.appendSlice(self.allocator, tree.getString(@fromBackingInt(key_node.data)));
                    try self.out.append(self.allocator, ':');
                } else {
                    if (key_node.tag == .symbol) {
                        try self.out.appendSlice(self.allocator, tree.getString(@fromBackingInt(key_node.data)));
                        try self.out.appendSlice(self.allocator, ": ");
                    } else {
                        try self.formatNode(tree, entry.key);
                        try self.out.appendSlice(self.allocator, " => ");
                    }
                    try self.formatNode(tree, entry.value);
                }
            },
        }
    }

    /// A call's arguments in parentheses (its `(` is the token before the first argument).
    fn formatArgs(self: *Formatter, tree: *const ast.Tree, args: []const ast.NamedArg, close_token: ?u32) Error!void {
        const items = try self.argItems(tree, args);
        defer self.allocator.free(items);
        try self.formatList(tree, items, .{ .open = "(", .close = ")", .hug_last = true }, items[0].first -| 1, close_token);
    }

    fn formatIfStmt(self: *Formatter, tree: *const ast.Tree, ifs: ast.IfStmt, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, if (ifs.is_unless) "unless " else "if ");
        try self.formatNode(tree, ifs.condition);
        try self.flushInlineComments(start_line);
        try self.ensureNewline();

        self.indent_level += 1;
        try self.formatNode(tree, ifs.then_branch);
        self.indent_level -= 1;
        try self.ensureNewline(); // Force a newline before 'elsif', 'else' or 'end'

        // An `elsif` is an `if` that is the else branch itself (a nested `if` written in an
        // `else` is inside a block). It used to print as `else` + `if ... end`, a different
        // program, so the formatter refused any `if` with an `elsif`.
        var else_branch = ifs.else_branch;
        while (tree.getNode(else_branch)) |branch| {
            if (branch.tag != .if_stmt or tree.isGrouped(else_branch)) break;
            const elsif = tree.ifStmt(branch);
            if (elsif.is_unless) break;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "elsif ");
            try self.formatNode(tree, elsif.condition);
            try self.flushInlineComments(self.getNodeLine(branch));
            try self.ensureNewline();
            self.indent_level += 1;
            try self.formatNode(tree, elsif.then_branch);
            self.indent_level -= 1;
            try self.ensureNewline();
            else_branch = elsif.else_branch;
        }

        if (else_branch != .none) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "else");
            try self.flushHeaderComment(tree, else_branch);
            try self.ensureNewline();
            self.indent_level += 1;
            try self.formatNode(tree, else_branch);
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
        try self.out.appendSlice(self.allocator, "for ");
        for (tree.getLhsExprs(fs.targets), 0..) |t, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
            if (t.modifier) |mod| try self.out.appendSlice(self.allocator, getArgModifierStr(mod));
            try self.out.appendSlice(self.allocator, tree.getString(t.name));
        }
        try self.out.appendSlice(self.allocator, " in ");
        try self.formatNode(tree, fs.iterable);
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
        try self.ensureNewline(); // (an unconditional newline after the comment's left a blank line)

        for (tree.getWhenBranches(cs.when_branches)) |wb| {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "when ");
            for (tree.getNodes(wb.conditions), 0..) |cond, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.formatNode(tree, cond);
            }
            try self.flushHeaderComment(tree, wb.body);
            try self.ensureNewline();
            self.indent_level += 1;
            try self.formatNode(tree, wb.body);
            self.indent_level -= 1;
            try self.ensureNewline(); // Force a newline before the next 'when', 'else', or 'end'
        }

        if (cs.else_branch != .none) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "else");
            try self.flushHeaderComment(tree, cs.else_branch);
            try self.ensureNewline();
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
        try self.formatRescueBody(tree, bs);
    }

    /// The body of a `begin`, or of a method with its own `rescue` or `ensure`, then those
    /// clauses and `end`.
    fn formatRescueBody(self: *Formatter, tree: *const ast.Tree, bs: ast.BeginStmt) Error!void {
        try self.ensureNewline();

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
            try self.flushHeaderComment(tree, r.body);
            try self.ensureNewline();
            self.indent_level += 1;
            try self.formatNode(tree, r.body);
            self.indent_level -= 1;
            try self.ensureNewline(); // Force a newline before the next 'rescue', 'ensure', or 'end'
        }

        if (bs.ensure_body != .none) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "ensure");
            try self.flushHeaderComment(tree, bs.ensure_body);
            try self.ensureNewline();
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

        try self.formatParams(tree, tree.getParams(def.params));
        try self.flushInlineComments(start_line);
        // A method's own `rescue`/`ensure` make a begin_stmt its body (an explicit `begin`
        // is inside the body's block): printed in a `begin` of its own, it read back as that.
        const body = tree.getNode(def.body).?;
        if (body.tag == .begin_stmt) return self.formatRescueBody(tree, tree.beginStmt(body));
        try self.formatBodyWithEnd(tree, def.body);
    }

    /// `(a, b = 2, *rest, key: 1, **opts, &blk)` of a def or a lambda; nothing when
    /// there are no parameters. (A lambda's lost its defaults and modifiers, so the
    /// formatter refused any lambda that had them.)
    fn formatParams(self: *Formatter, tree: *const ast.Tree, params: []const ast.Param) Error!void {
        if (params.len == 0) return;
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

    /// Whether an array literal was written as a list without brackets (`return 1, 2`,
    /// `a, b = 1, 2`): the parser packs one, with the first element's token as its own.
    fn isPackedList(self: *const Formatter, node: *const ast.Node) bool {
        if (node.main_token >= self.token_starts.len) return true;
        const text = self.tokenText(node.main_token);
        return !(text.len > 0 and (text[0] == '[' or text[0] == '%'));
    }

    /// The elements of a packed list, comma-separated.
    fn formatPackedList(self: *Formatter, tree: *const ast.Tree, node: *const ast.Node) Error!void {
        for (tree.getNodes(tree.nodeSpan(node)), 0..) |elem, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.formatNode(tree, elem);
        }
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
        try self.formatParams(tree, tree.getParams(l.params));

        const body_node = tree.getNode(l.body).?;
        if (body_node.tag == .block) {
            try self.out.appendSlice(self.allocator, " ");
            // The body is parsed from the token after its `{` or `do`.
            try self.formatBlockOpenedAt(tree, l.body, start_line, body_node.main_token -| 1);
        } else {
            try self.out.appendSlice(self.allocator, " { ");
            try self.formatNode(tree, l.body);
            try self.out.appendSlice(self.allocator, " }");
        }
    }

    fn formatNamespace(self: *Formatter, tree: *const ast.Tree, path: []const ast.StringId) Error!void {
        // One segment is `::A`, the top-level A (parseTopLevelScopeResolution): printed as
        // `A` it read back as a constant looked up in the enclosing modules. With more, the
        // path is resolved from the top anyway, so `::A::B` is `A::B`.
        if (path.len == 1) try self.out.appendSlice(self.allocator, "::");
        for (path, 0..) |p_id, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, "::");
            try self.out.appendSlice(self.allocator, tree.getString(p_id));
        }
    }

    fn formatRange(self: *Formatter, tree: *const ast.Tree, r: ast.Range) Error!void {
        try self.formatOperand(tree, r.start, .range);
        try self.out.appendSlice(self.allocator, if (r.is_exclusive) "..." else "..");
        try self.formatOperand(tree, r.end, Precedence.range.tighter());
    }

    /// How tightly a node binds once printed, on the parser's scale. The AST keeps no
    /// grouping, so `(1 + 2) * 3` used to print as `1 + 2 * 3`.
    fn bindingPower(tree: *const ast.Tree, node_idx: ast.NodeIndex) Precedence {
        const node = tree.getNode(node_idx) orelse return .call;
        return switch (node.tag) {
            .binary_op => parser.binaryPrecedence(tree.binaryExpr(node).op),
            .unary_op => .unary,
            .range => .range,
            .ternary_op => .ternary,
            .rescue_modifier => .rescue_mod,
            .assignment, .multiple_assignment, .property_assignment, .index_assignment => .assignment,
            else => .call,
        };
    }

    /// Prints an operand, in parentheses when it binds looser than `min`, its position needs
    /// (unless the author's own are there already).
    fn formatOperand(self: *Formatter, tree: *const ast.Tree, node_idx: ast.NodeIndex, min: Precedence) Error!void {
        const wrap = @backingInt(bindingPower(tree, node_idx)) < @backingInt(min) and !tree.isGrouped(node_idx);
        if (wrap) try self.out.append(self.allocator, '(');
        try self.formatNode(tree, node_idx);
        if (wrap) try self.out.append(self.allocator, ')');
    }

    fn formatAssignment(self: *Formatter, tree: *const ast.Tree, a: ast.Assignment) Error!void {
        try self.out.appendSlice(self.allocator, tree.getString(a.name));
        try self.out.append(self.allocator, ' ');
        if (a.op) |op| try self.out.appendSlice(self.allocator, getBinaryOpStr(op));
        try self.out.appendSlice(self.allocator, "= ");
        try self.formatNode(tree, a.value);
    }

    fn formatMultipleAssignment(self: *Formatter, tree: *const ast.Tree, ma: ast.MultipleAssignment) Error!void {
        const targets = tree.getLhsExprs(ma.lhs);
        for (targets, 0..) |item, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
            if (item.modifier) |mod| try self.out.appendSlice(self.allocator, getArgModifierStr(mod));
            try self.out.appendSlice(self.allocator, tree.getString(item.name));
        }
        // `a, = list` takes the first element; without its comma it assigned the whole list.
        if (targets.len == 1 and targets[0].modifier == null) try self.out.append(self.allocator, ',');
        try self.out.append(self.allocator, ' ');
        if (ma.op) |op| try self.out.appendSlice(self.allocator, getBinaryOpStr(op)); // `a, b += 1` (the operator was dropped)
        try self.out.appendSlice(self.allocator, "= ");
        const value_node = tree.getNode(ma.value).?;
        if (value_node.tag == .array_literal and self.isPackedList(value_node)) {
            try self.formatPackedList(tree, value_node); // `a, b = 1, 2`, as written, not `[1, 2]`
        } else {
            try self.formatNode(tree, ma.value);
        }
    }

    fn formatPropertyAssignment(self: *Formatter, tree: *const ast.Tree, pa: ast.PropertyAssignment) Error!void {
        try self.formatOperand(tree, pa.target, .call);
        try self.out.append(self.allocator, '.');
        try self.out.appendSlice(self.allocator, tree.getString(pa.property));
        try self.out.append(self.allocator, ' ');
        if (pa.op) |op| try self.out.appendSlice(self.allocator, getBinaryOpStr(op));
        try self.out.appendSlice(self.allocator, "= ");
        try self.formatNode(tree, pa.value);
    }

    fn formatIndexAssignment(self: *Formatter, tree: *const ast.Tree, ia: ast.IndexAssignment) Error!void {
        try self.formatOperand(tree, ia.target, .call);
        try self.out.append(self.allocator, '[');
        try self.formatNode(tree, ia.index);
        try self.out.appendSlice(self.allocator, "] ");
        if (ia.op) |op| try self.out.appendSlice(self.allocator, getBinaryOpStr(op));
        try self.out.appendSlice(self.allocator, "= ");
        try self.formatNode(tree, ia.value);
    }

    fn formatIndexAccess(self: *Formatter, tree: *const ast.Tree, ia: ast.IndexAccess) Error!void {
        try self.formatOperand(tree, ia.target, .call);
        try self.out.append(self.allocator, '[');
        try self.formatNode(tree, ia.index);
        try self.out.append(self.allocator, ']');
    }

    fn formatBinaryOp(self: *Formatter, tree: *const ast.Tree, b: ast.BinaryExpr) Error!void {
        // Left-associative, so `a - (b - c)` keeps its parentheses; `**` is right-associative.
        const prec = parser.binaryPrecedence(b.op);
        const right_assoc = b.op == .exponent;
        try self.formatOperand(tree, b.left, if (right_assoc) prec.tighter() else prec);
        try self.out.append(self.allocator, ' ');
        try self.out.appendSlice(self.allocator, getBinaryOpStr(b.op));

        // A line ends after the operator where the author ended it (a line can't start with
        // one), with the comments there kept: they used to move after the statement.
        const op_line = self.lastLine(tree, b.left);
        const right_line = self.lineOf(token_span.first(tree, b.right));
        const broken = right_line > op_line;
        if (broken) {
            try self.flushTrailingComments(op_line, op_line);
            try self.ensureNewline();
            self.indent_level += 1;
            try self.flushCommentsBefore(right_line, op_line, false);
            try self.writeIndent();
        } else {
            try self.out.append(self.allocator, ' ');
        }
        // The continuation indent holds for all of the right operand, however many lines.
        defer if (broken) {
            self.indent_level -= 1;
        };
        try self.formatOperand(tree, b.right, if (right_assoc) prec else prec.tighter());
    }

    fn formatUnaryOp(self: *Formatter, tree: *const ast.Tree, u: ast.UnaryExpr) Error!void {
        const op_str = switch (u.op) {
            .negate => "-",
            .positive => "+",
            .not => "!",
            .bitwise_not => "~",
        };
        try self.out.appendSlice(self.allocator, op_str);
        // `-3.abs` is (-3).abs, a negative literal, so -(3.abs) keeps parentheses: printed
        // as `-3.abs` (from `- 3.abs`), it was another program.
        if (u.op == .negate and startsWithCallOnNumber(tree, u.operand)) {
            try self.out.append(self.allocator, '(');
            try self.formatNode(tree, u.operand);
            try self.out.append(self.allocator, ')');
            return;
        }
        try self.formatOperand(tree, u.operand, .unary);
    }

    /// Whether a node, printed, starts with a number that a call or indexing applies to
    /// (`3.abs`, `2[0].m`, `2.m ** 2`); `2 ** 2` alone doesn't.
    fn startsWithCallOnNumber(tree: *const ast.Tree, node_idx: ast.NodeIndex) bool {
        var idx = node_idx;
        var called = false;
        while (idx != .none and !tree.isGrouped(idx)) {
            const node = tree.getNode(idx) orelse return false;
            switch (node.tag) {
                .number => return called,
                .method_call => {
                    idx = tree.methodCall(node).receiver;
                    called = true;
                },
                .index_access => {
                    idx = tree.indexAccess(node).target;
                    called = true;
                },
                .binary_op => idx = tree.binaryExpr(node).left,
                else => return false,
            }
        }
        return false;
    }

    fn formatTernaryOp(self: *Formatter, tree: *const ast.Tree, t: ast.TernaryExpr) Error!void {
        try self.formatOperand(tree, t.condition, Precedence.ternary.tighter());
        try self.out.appendSlice(self.allocator, " ? ");
        try self.formatNode(tree, t.then_branch);
        try self.out.appendSlice(self.allocator, " : ");
        try self.formatNode(tree, t.else_branch);
    }

    fn formatSplat(self: *Formatter, tree: *const ast.Tree, node: ast.NodeIndex, prefix: []const u8) Error!void {
        try self.out.appendSlice(self.allocator, prefix);
        try self.formatNode(tree, node);
    }

    fn formatRescueModifier(self: *Formatter, tree: *const ast.Tree, rm: ast.RescueModifier) Error!void {
        try self.formatOperand(tree, rm.expr, .rescue_mod);
        try self.out.appendSlice(self.allocator, " rescue ");
        try self.formatOperand(tree, rm.rescue_expr, Precedence.rescue_mod.tighter());
    }

    /// A call, and the chain of calls it ends (`cube(10).translate(...).rotate(...)`). A
    /// chain is kept on one line when it fits, else broken one call per line; the author's
    /// breaks are kept. A single call on a receiver stays with it (its arguments break
    /// instead): every chain used to be broken, `cube(10).translate(1, 2, 3)` included.
    fn formatMethodCall(self: *Formatter, tree: *const ast.Tree, node_idx: ast.NodeIndex) Error!void {
        // The calls on receivers, outermost first; the chain stops at a parenthesized one.
        var links: std.ArrayList(ast.NodeIndex) = .empty;
        defer links.deinit(self.allocator);
        var root = node_idx;
        while (true) {
            const node = tree.getNode(root).?;
            if (node.tag != .method_call) break;
            const mc = tree.methodCall(node);
            if (mc.receiver == .none or (root != node_idx and tree.isGrouped(root))) break;
            try links.append(self.allocator, root);
            root = mc.receiver;
        }
        std.mem.reverse(ast.NodeIndex, links.items);
        if (links.items.len == 0) return self.formatCallTail(tree, node_idx);

        const Chain = struct {
            tree: *const ast.Tree,
            root: ast.NodeIndex,
            links: []const ast.NodeIndex,
            /// Keep the calls the author put on one line together.
            author_lines: bool,

            fn flat(c: @This(), f: *Formatter) Error!void {
                try f.formatOperand(c.tree, c.root, .call);
                for (c.links) |link| try f.formatLink(c.tree, link);
            }

            fn broken(c: @This(), f: *Formatter) Error!void {
                try f.formatOperand(c.tree, c.root, .call);
                f.indent_level += 1;
                var prev_line = f.lastLine(c.tree, c.root);
                for (c.links, 0..) |link, i| {
                    const link_line = f.lineOf(c.tree.methodCall(c.tree.getNode(link).?).name_token);
                    // A call stays on the line before where the author put it there, and the
                    // first call stays with a bare name (`Box.new(...)`, `self.part(...)`).
                    // A call with no name (`(f)(2)`) is only one on the same line.
                    const unnamed = c.tree.methodCall(c.tree.getNode(link).?).method_name == .none;
                    const joins = unnamed or if (c.author_lines) link_line == prev_line else i == 0 and isBareName(c.tree, c.root);
                    if (joins) {
                        try f.formatLink(c.tree, link);
                        prev_line = f.lastLine(c.tree, link);
                        continue;
                    }
                    try f.ensureNewline();
                    // A comment between the calls stays there, and one after a call on its line.
                    try f.flushCommentsBefore(link_line, prev_line, false);
                    try f.writeIndent();
                    try f.formatLink(c.tree, link);
                    prev_line = f.lastLine(c.tree, link);
                    try f.flushTrailingComments(link_line, prev_line);
                }
                f.indent_level -= 1;
            }
        };
        const broke = self.chainBroken(tree, root, links.items);
        const chain: Chain = .{ .tree = tree, .root = root, .links = links.items, .author_lines = broke };
        if (links.items.len == 1 and !broke) return chain.flat(self);
        try self.layOut(broke, chain);
    }

    fn isBareName(tree: *const ast.Tree, idx: ast.NodeIndex) bool {
        const node = tree.getNode(idx) orelse return false;
        return switch (node.tag) {
            .identifier, .namespace_access, .self_expr => true,
            else => false,
        };
    }

    /// Whether a call of the chain starts on a later line than its receiver ends.
    fn chainBroken(self: *Formatter, tree: *const ast.Tree, root: ast.NodeIndex, links: []const ast.NodeIndex) bool {
        var prev_end = self.lastLine(tree, root);
        for (links) |link| {
            if (self.lineOf(tree.methodCall(tree.getNode(link).?).name_token) > prev_end) return true;
            prev_end = self.lastLine(tree, link);
        }
        return false;
    }

    /// `.name(args) block` of a call on a receiver.
    fn formatLink(self: *Formatter, tree: *const ast.Tree, link: ast.NodeIndex) Error!void {
        const mc = tree.methodCall(tree.getNode(link).?);
        // A call on an expression with no name, `(f)(2)`, has no dot: it fails when it runs
        // (a lambda takes .call), but formatting keeps the script as written. `(f).(2)`
        // didn't parse.
        if (mc.method_name != .none) try self.out.appendSlice(self.allocator, if (mc.is_safe) "&." else ".");
        try self.formatCallTail(tree, link);
    }

    /// A call's name, arguments and block (its receiver is printed by the caller).
    fn formatCallTail(self: *Formatter, tree: *const ast.Tree, node_idx: ast.NodeIndex) Error!void {
        const node = tree.getNode(node_idx).?;
        const mc = tree.methodCall(node);
        try self.out.appendSlice(self.allocator, tree.getString(mc.method_name));
        const args = tree.getNamedArgs(mc.args);
        if (args.len > 0) {
            try self.formatArgs(tree, args, if (mc.end_token != 0) mc.end_token else null);
        } else if ((mc.receiver == .none or mc.method_name == .none) and mc.block == .none) {
            try self.out.appendSlice(self.allocator, "()");
        }
        if (mc.block != .none) {
            try self.out.append(self.allocator, ' ');
            try self.formatBlockClosure(tree, mc.block, self.getNodeLine(node));
        }
    }

    fn formatBlockClosure(self: *Formatter, tree: *const ast.Tree, block_idx: ast.NodeIndex, start_line: u32) Error!void {
        const block_node = tree.getNode(block_idx) orelse return;
        // A call's block starts at its `{` or `do`.
        return self.formatBlockOpenedAt(tree, block_idx, start_line, block_node.main_token);
    }

    /// A block opened by token `opener` (`{` or `do`).
    fn formatBlockOpenedAt(self: *Formatter, tree: *const ast.Tree, block_idx: ast.NodeIndex, start_line: u32, opener: u32) Error!void {
        const block_node = tree.getNode(block_idx) orelse return;
        if (block_node.tag != .block) return;
        const b = tree.block(block_node);

        // The author's delimiter stays: a `{ }` block used to become `do ... end` over three
        // lines, and `do` can't replace `{` everywhere (in a `for` header it starts the body).
        if (std.mem.eql(u8, self.tokenText(opener), "{")) {
            const Braces = struct {
                tree: *const ast.Tree,
                block_idx: ast.NodeIndex,
                start_line: u32,

                fn flat(l: @This(), f: *Formatter) Error!void {
                    const blk = l.tree.block(l.tree.getNode(l.block_idx).?);
                    try f.out.append(f.allocator, '{');
                    try f.formatBlockParams(l.tree, blk);
                    for (l.tree.getNodes(blk.stmts), 0..) |stmt, i| {
                        try f.out.appendSlice(f.allocator, if (i == 0) " " else "; ");
                        try f.formatNode(l.tree, stmt);
                    }
                    try f.out.appendSlice(f.allocator, " }");
                }

                fn broken(l: @This(), f: *Formatter) Error!void {
                    try f.out.append(f.allocator, '{');
                    try f.formatBlockParams(l.tree, l.tree.block(l.tree.getNode(l.block_idx).?));
                    try f.flushInlineComments(l.start_line);
                    try f.formatBodyClosedBy(l.tree, l.block_idx, "}");
                }
            };
            // Broken by the author when it doesn't end on the `{` line.
            const broke = self.lineOf(b.end_token) != self.lineOf(opener);
            return self.layOut(broke, Braces{ .tree = tree, .block_idx = block_idx, .start_line = start_line });
        }

        try self.out.appendSlice(self.allocator, "do");
        try self.formatBlockParams(tree, b);
        try self.flushInlineComments(start_line);
        try self.formatBodyWithEnd(tree, block_idx);
    }

    /// ` |a, b|` after a block's opener, when it has parameters.
    fn formatBlockParams(self: *Formatter, tree: *const ast.Tree, b: ast.Block) Error!void {
        const params = tree.getNodes(b.params);
        if (params.len == 0) return;
        try self.out.appendSlice(self.allocator, " |");
        for (params, 0..) |p_idx, idx| {
            if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
            try self.formatNode(tree, p_idx);
        }
        try self.out.append(self.allocator, '|');
    }

    fn formatSuperCall(self: *Formatter, tree: *const ast.Tree, sc: ast.SuperCall, start_line: u32) Error!void {
        try self.out.appendSlice(self.allocator, "super");
        const args = tree.getNamedArgs(sc.args);
        if (args.len > 0) {
            try self.formatArgs(tree, args, null);
        } else if (!sc.implicit_args) {
            try self.out.appendSlice(self.allocator, "()"); // passes nothing; bare `super` passes the method's arguments
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
            if (val_node.tag == .array_literal and self.isPackedList(val_node)) {
                // `return 1, 2` packs its values into an Array; a written `return []` or
                // `return [a]` keeps its brackets (they were dropped: `return []` lost its value).
                try self.formatPackedList(tree, val_node);
            } else {
                try self.formatNode(tree, val);
            }
        }
    }

    fn formatYield(self: *Formatter, tree: *const ast.Tree, mc: ast.MethodCall) Error!void {
        try self.out.appendSlice(self.allocator, "yield");

        const args = tree.getNamedArgs(mc.args);
        if (args.len > 0) try self.formatArgs(tree, args, if (mc.end_token != 0) mc.end_token else null);
    }

    /// `import { a, b as c } from "path"`; an alias used to be dropped.
    /// `import`/`export`, its names in braces, and `from "path"` unless `path` is null (a
    /// file's own export).
    /// `braced`: the names are in braces, which mean something else than bare ones for a
    /// file (keys of its value, against the value), so they stay as written.
    fn formatImportExport(self: *Formatter, tree: *const ast.Tree, kw: []const u8, symbols: []const ast.AliasPair, braced: bool, path: ?[]const u8, attrs: ast.NodeIndex) Error!void {
        try self.out.appendSlice(self.allocator, kw);
        try self.out.append(self.allocator, ' ');
        if (symbols.len > 0) {
            if (braced) try self.out.appendSlice(self.allocator, "{ ");
            for (symbols, 0..) |pair, idx| {
                if (idx > 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, tree.getString(pair.original));
                if (pair.alias != pair.original and pair.alias != .none) {
                    try self.out.appendSlice(self.allocator, " as ");
                    try self.out.appendSlice(self.allocator, tree.getString(pair.alias));
                }
            }
            if (braced) try self.out.appendSlice(self.allocator, " }");
        }
        if (path) |p| {
            if (symbols.len > 0) try self.out.appendSlice(self.allocator, " from ");
            try self.out.append(self.allocator, '"');
            try self.out.appendSlice(self.allocator, p);
            try self.out.append(self.allocator, '"');
        }

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
