//! `Linter`: walks a parsed script once (`check`) and runs every enabled rule of `RuleSet` on
//! each node, keeping the scopes and bindings the rules ask about, and collects their findings
//! and fixes (`LinterDiagnostic`, `Fix`) along with the parser's errors.

const std = @import("std");
const ast = @import("../../core/ast.zig");
const token_span = @import("../../core/token_span.zig");
const token = @import("../../core/token.zig");
const common_errors = @import("../../core/errors.zig");
const config_mod = @import("config.zig");
const Config = config_mod.Config;
const LintRule = @import("rules/rule.zig").LintRule;
const visitor = @import("../../core/visitor.zig");
const Document = @import("../../core/document.zig").Document;

const NegativeDimRule = @import("rules/negative_dim.zig").NegativeDimRule;
const UnusedVarsRule = @import("rules/unused_vars.zig").UnusedVarsRule;
const UnreachableCodeRule = @import("rules/unreachable_code.zig").UnreachableCodeRule;
const SelfSubtractionRule = @import("rules/self_subtraction.zig").SelfSubtractionRule;
const ParamOrderRule = @import("rules/param_order.zig").ParamOrderRule;
const UnknownKeywordRule = @import("rules/unknown_keyword.zig").UnknownKeywordRule;
const SegmentsAsSidesRule = @import("rules/segments_as_sides.zig").SegmentsAsSidesRule;
const BrepUnsupportedRule = @import("rules/brep_unsupported.zig").BrepUnsupportedRule;
const ShapeMismatchRule = @import("rules/shape_mismatch.zig").ShapeMismatchRule;
const UnusedParamRule = @import("rules/unused_param.zig").UnusedParamRule;

pub const LinterSeverity = enum {
    @"error",
    warning,
    info,

    pub fn toString(self: LinterSeverity) []const u8 {
        return @tagName(self);
    }
    pub fn toChar(self: LinterSeverity) []const u8 {
        return switch (self) {
            .@"error" => "E",
            .warning => "W",
            .info => "I",
        };
    }
};

/// One change to the source: `length` bytes at `offset` become `replacement`.
pub const Edit = struct {
    offset: u32,
    length: u32,
    replacement: []const u8,
};

/// How to resolve a finding: every edit at once (renaming `x` renames each place it is
/// bound).
pub const Fix = struct {
    /// What it does, as an editor offers it ("Rename 'x' to '_x'").
    title: []const u8,
    edits: []Edit,
    /// Whether it keeps the model's meaning, so `check --fix` may apply it unasked; a fix
    /// that isn't (deleting unreachable code) is only offered, in the editor.
    safe: bool,

    pub fn deinit(self: Fix, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        for (self.edits) |e| allocator.free(e.replacement);
        allocator.free(self.edits);
    }
};

pub const LinterDiagnostic = struct {
    loc: token.Location,
    severity: LinterSeverity,
    message: []const u8,
    origin: Origin,
    fix: ?Fix = null,

    /// What reported it: a lint rule, by its id, or the parser or the compiler, by the
    /// error's code.
    pub const Origin = union(enum) {
        rule: []const u8,
        error_code: common_errors.Code,
    };

    /// The id of the rule that reported it; null for a syntax or compile error.
    pub fn ruleId(self: LinterDiagnostic) ?[]const u8 {
        return switch (self.origin) {
            .rule => |id| id,
            .error_code => null,
        };
    }

    /// What it is shown and matched by: its rule's id, or its error's code.
    pub fn code(self: LinterDiagnostic) []const u8 {
        return switch (self.origin) {
            .rule => |id| id,
            .error_code => |error_code| error_code.name(),
        };
    }

    /// Frees what the finding owns: its message and fix.
    pub fn deinit(self: LinterDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.fix) |f| f.deinit(allocator);
    }
};

/// Every rule, each field named by its id; `.kupcad.json` sets each one's level by the same
/// name (config.Config).
pub const RuleSet = struct {
    @"nonpositive-size": NegativeDimRule = .{},
    @"unused-variable": UnusedVarsRule = .{},
    @"unreachable-code": UnreachableCodeRule = .{},
    @"self-subtraction": SelfSubtractionRule = .{},
    @"param-order": ParamOrderRule = .{},
    @"unused-param": UnusedParamRule = .{},
    @"unknown-keyword": UnknownKeywordRule = .{},
    @"segments-as-sides": SegmentsAsSidesRule = .{},
    @"brep-unsupported": BrepUnsupportedRule = .{},
    @"shape-mismatch": ShapeMismatchRule = .{},

    pub const ids = @typeInfo(RuleSet).@"struct".field_names;

    comptime {
        for (ids) |rule_id| {
            if (!std.mem.eql(u8, @FieldType(RuleSet, rule_id).id, rule_id)) @compileError("rule '" ++ rule_id ++ "' is stored under another id");
            if (!@hasField(Config, rule_id)) @compileError("lint.Config has no level for rule '" ++ rule_id ++ "'");
        }
        for (@typeInfo(Config).@"struct".field_names) |rule_id| {
            if (!@hasField(RuleSet, rule_id)) @compileError("lint.Config sets '" ++ rule_id ++ "', which is no rule");
        }
    }

    /// The description of the rule with this id, or null if there is none.
    pub fn describe(rule_id: []const u8) ?[]const u8 {
        inline for (ids) |known| {
            if (std.mem.eql(u8, known, rule_id)) return @FieldType(RuleSet, known).description;
        }
        return null;
    }
};

/// A variable a scope binds.
pub const Binding = struct {
    /// Where it is first bound; findings about it point there.
    loc: token.Location,
    /// Each place it is bound by its name alone (`x = ...`, a block parameter): what a
    /// rename has to change.
    sites: std.ArrayList(token.Location) = .empty,
    /// False once it is also bound where a rename would change more than the variable
    /// (a method's parameter or name, which callers use) or where no token holds its name
    /// alone (a `for` target, a multiple assignment).
    renamable: bool = true,
};

pub const Scope = struct {
    declared_vars: std.StringHashMapUnmanaged(Binding) = .empty,
    used_vars: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        var it = self.declared_vars.valueIterator();
        while (it.next()) |binding| binding.sites.deinit(allocator);
        self.declared_vars.deinit(allocator);
        self.used_vars.deinit(allocator);
    }
};

const LintContext = struct {
    linter: *Linter,

    pub fn enterNode(self: *LintContext, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx).?;

        // A call's block is a scope; an `if` or `while` body, also a block, is not.
        const call_block: ast.NodeIndex = switch (node.tag) {
            .method_call => tree.methodCall(node).block,
            .super_call => tree.superCall(node).block,
            else => .none,
        };
        if (call_block != .none) try self.linter.closure_blocks.put(self.linter.allocator, call_block, {});
        if (node.tag == .block and node_idx != self.linter.root) self.linter.body_depth += 1;

        // 1. Trigger general lint rules
        for (self.linter.rules.items) |rule| try rule.checkNode(self.linter, tree, node_idx);

        // 2. Open a new scope if we entered a block or function
        if (self.linter.opensScope(node.tag, node_idx)) {
            try self.linter.pushScope();
            for (self.linter.rules.items) |rule| try rule.enterScope(self.linter, tree, node_idx);
        }
    }

    pub fn leaveNode(self: *LintContext, tree: *const ast.Tree, node_idx: ast.NodeIndex) !void {
        const node = tree.getNode(node_idx).?;

        // Close the scope now that all children have been traversed
        if (self.linter.opensScope(node.tag, node_idx)) {
            try self.linter.popScope();
        }
        if (node.tag == .block) {
            _ = self.linter.closure_blocks.remove(node_idx);
            if (node_idx != self.linter.root) self.linter.body_depth -= 1;
        }
    }
};

pub const Linter = struct {
    allocator: std.mem.Allocator,
    config: Config,
    diagnostics: std.ArrayList(LinterDiagnostic) = .empty,
    rules: std.ArrayList(LintRule) = .empty,
    scopes: std.ArrayList(Scope) = .empty,
    /// The blocks given to calls being walked: those open a scope, other blocks don't.
    closure_blocks: std.AutoHashMapUnmanaged(ast.NodeIndex, void) = .empty,
    /// How many bodies (def, block, if, while, ...) enclose the node being checked; 0 for a
    /// statement of the script itself. Unlike `scopes`, every body counts.
    body_depth: usize = 0,
    /// The script's own block, as passed to `check`.
    root: ast.NodeIndex = .none,

    // Token location lookup
    source: []const u8 = "",
    /// Every word in `source`, built the first time a rule asks (sourceHasWord).
    words: ?std.StringHashMapUnmanaged(void) = null,
    token_starts: []const u32 = &.{},
    token_lengths: []const u32 = &.{},
    file_id: u32 = 0,

    rule_set: RuleSet = .{},

    pub fn init(allocator: std.mem.Allocator, config: Config) Linter {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Linter) void {
        for (self.scopes.items) |*s| s.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.closure_blocks.deinit(self.allocator);
        if (self.words) |*w| w.deinit(self.allocator);
        self.rules.deinit(self.allocator);
        for (self.diagnostics.items) |d| d.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
    }

    /// Every rule the config doesn't turn off.
    pub fn registerDefaultRules(self: *Linter) !void {
        inline for (RuleSet.ids) |rule_id| {
            if (@field(self.config, rule_id) != .off) try self.rules.append(self.allocator, @field(self.rule_set, rule_id).rule());
        }
    }

    pub fn getLoc(self: *const Linter, main_token: u24) token.Location {
        if (main_token >= self.token_starts.len) return .{ .offset = 0, .length = 0, .file_id = self.file_id };
        return .{
            .offset = self.token_starts[main_token],
            .length = self.token_lengths[main_token],
            .file_id = self.file_id,
        };
    }

    /// The source a node spans, from its first token to its last: `-2` whole, where its main
    /// token is only the `-`.
    pub fn nodeLoc(self: *const Linter, tree: *const ast.Tree, node_idx: ast.NodeIndex) token.Location {
        const first = self.getLoc(@intCast(token_span.first(tree, node_idx)));
        const last = self.getLoc(@intCast(token_span.last(tree, node_idx)));
        if (last.offset < first.offset) return first;
        return .{ .offset = first.offset, .length = last.offset + last.length - first.offset, .file_id = self.file_id };
    }

    /// Reports a finding of rule `rule_id`, at the level the config gives that rule.
    pub fn report(self: *Linter, comptime rule_id: []const u8, loc: token.Location, comptime fmt: []const u8, args: anytype) !void {
        return self.reportFix(rule_id, loc, null, fmt, args);
    }

    /// `report` with a way to resolve the finding, which the linter then owns (freed even
    /// if reporting fails).
    pub fn reportFix(self: *Linter, comptime rule_id: []const u8, loc: token.Location, fix: ?Fix, comptime fmt: []const u8, args: anytype) !void {
        errdefer if (fix) |f| f.deinit(self.allocator);
        const severity: LinterSeverity = switch (@field(self.config, rule_id)) {
            .off => {
                if (fix) |f| f.deinit(self.allocator);
                return;
            },
            .info => .info,
            .warning => .warning,
            .@"error" => .@"error",
        };
        const msg = try self.allocator.print(fmt, args);
        errdefer self.allocator.free(msg);
        try self.diagnostics.append(self.allocator, .{
            .loc = loc,
            .severity = severity,
            .message = msg,
            .origin = .{ .rule = rule_id },
            .fix = fix,
        });
    }

    /// The source being checked, for rules whose fixes edit whole lines.
    pub fn sourceText(self: *const Linter) []const u8 {
        return self.source;
    }

    /// Whether `word` occurs in the source as a whole word (an identifier, or the same
    /// letters anywhere else: a comment or a string counts, which errs on the safe side).
    /// The words are collected once, so asking per finding stays linear in the file.
    pub fn sourceHasWord(self: *Linter, word: []const u8) !bool {
        if (self.words == null) {
            var words: std.StringHashMapUnmanaged(void) = .empty;
            errdefer words.deinit(self.allocator);
            var start: ?usize = null;
            for (self.source, 0..) |c, i| {
                const in_word = std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
                if (in_word and start == null) start = i;
                if (!in_word) if (start) |s| {
                    try words.put(self.allocator, self.source[s..i], {});
                    start = null;
                };
            }
            if (start) |s| try words.put(self.allocator, self.source[s..], {});
            self.words = words;
        }
        return self.words.?.contains(word);
    }

    /// The bytes from token `first` to token `last`, widened to whole lines when nothing
    /// else shares them (the indentation before, the line break after), so deleting the
    /// range leaves no blank line behind.
    pub fn deletionRange(self: *const Linter, first: u32, last: u32) struct { offset: u32, length: u32 } {
        const src = self.source;
        var start: usize = self.getLoc(@intCast(first)).offset;
        const last_loc = self.getLoc(@intCast(last));
        var end: usize = last_loc.offset + last_loc.length;
        // A statement's last token can be the line break that ends it.
        while (end > start and std.ascii.isWhitespace(src[end - 1])) end -= 1;
        const line_start = if (std.mem.findScalarLast(u8, src[0..start], '\n')) |nl| nl + 1 else 0;
        const line_end = std.mem.findScalarPos(u8, src, end, '\n') orelse src.len;
        const alone_before = std.mem.trim(u8, src[line_start..start], " \t").len == 0;
        const alone_after = std.mem.trim(u8, src[end..line_end], " \t\r").len == 0;
        if (alone_before and alone_after) {
            start = line_start;
            end = @min(line_end + 1, src.len);
        }
        return .{ .offset = @intCast(start), .length = @intCast(end - start) };
    }

    pub fn pushScope(self: *Linter) !void {
        try self.scopes.append(self.allocator, .{});
    }

    pub fn popScope(self: *Linter) !void {
        if (self.scopes.items.len == 0) return;

        const last_idx = self.scopes.items.len - 1;
        const scope_ptr = &self.scopes.items[last_idx];

        for (self.rules.items) |rule| {
            try rule.exitScope(scope_ptr, self);
        }

        scope_ptr.deinit(self.allocator);
        self.scopes.items.len -= 1;
    }

    /// Whether the node opens a variable scope. These match the language: a def, lambda,
    /// call block, class or module body; not an `if`, `while` or `for` body, whose
    /// variables stay after it (they used to be reported unused when read afterwards).
    pub fn opensScope(self: *const Linter, tag: ast.Tag, node_idx: ast.NodeIndex) bool {
        return switch (tag) {
            .def_stmt, .lambda_expr, .class_stmt, .module_stmt, .singleton_class => true,
            .block => self.closure_blocks.contains(node_idx),
            else => false,
        };
    }

    /// Declares a variable an assignment binds, unless a scope it can see already has it:
    /// then the assignment writes that one (`n = 0; while ... n = n + 1`). `renamable`
    /// says whether `loc` is the name alone (see Binding).
    pub fn declareAssigned(self: *Linter, name: []const u8, loc: token.Location, renamable: bool) !void {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].declared_vars.getPtr(name)) |binding| return self.addSite(binding, loc, renamable);
        }
        try self.declareVar(name, loc, renamable);
    }

    /// Declares a binding in the innermost scope (a parameter, a method name).
    pub fn declareVar(self: *Linter, name: []const u8, loc: token.Location, renamable: bool) !void {
        if (self.scopes.items.len == 0) return;
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        const entry = try scope.declared_vars.getOrPut(self.allocator, name);
        if (!entry.found_existing) entry.value_ptr.* = .{ .loc = loc };
        try self.addSite(entry.value_ptr, loc, renamable);
    }

    fn addSite(self: *Linter, binding: *Binding, loc: token.Location, renamable: bool) !void {
        if (!renamable) {
            binding.renamable = false;
            return;
        }
        try binding.sites.append(self.allocator, loc);
    }

    pub fn markUsed(self: *Linter, name: []const u8) !void {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const scope = &self.scopes.items[i];
            if (scope.declared_vars.contains(name)) {
                try scope.used_vars.put(self.allocator, name, {});
                return;
            }
        }
    }

    /// check, for a parsed document: its tree, source, tokens and syntax errors.
    pub fn checkDocument(self: *Linter, doc: *const Document) !void {
        return self.check(&doc.tree, doc.source, doc.tokens.starts, doc.tokens.lengths, doc.tree.root, doc.diagnostics);
    }

    pub fn check(self: *Linter, tree: *const ast.Tree, source: []const u8, token_starts: []const u32, token_lengths: []const u32, root: ast.NodeIndex, parser_diagnostics: []const common_errors.Diagnostic) !void {
        self.source = source;
        self.token_starts = token_starts;
        self.token_lengths = token_lengths;

        for (parser_diagnostics) |diag| {
            try self.diagnostics.append(self.allocator, .{
                .loc = diag.loc,
                .severity = .@"error",
                .origin = .{ .error_code = diag.code },
                .message = try self.allocator.dupe(u8, diag.message),
            });
        }

        if (root == .none) return;
        self.root = root;
        defer for (self.rules.items) |rule| rule.deinit(self.allocator);

        // Establish the global scope
        try self.pushScope();

        // Automatically walk the AST
        var ctx = LintContext{ .linter = self };
        try visitor.walk(LintContext, &ctx, tree, root);

        // Conclude linting
        for (self.rules.items) |rule| {
            try rule.checkEOF(self);
        }
        try self.popScope();
    }
};
