const std = @import("std");

pub const Location = @import("token.zig").Location;

pub const UnaryOp = enum {
    negate, // -
    positive, // +
    not, // !
    bitwise_not, // ~
};

pub const BinaryOp = enum {
    add, // +
    subtract, // -
    multiply, // *
    divide, // /
    modulo, // %
    exponent, // ** or ^
    equal, // ==
    not_equal, // !=
    less, // <
    less_equal, // <=
    greater, // >
    greater_equal, // >=
    logical_and, // &&
    logical_or, // ||
    shift_left, // <<
    shift_right, // >>
    bitwise_and, // & (CSG Intersection)
    bitwise_or, // |
    bitwise_xor, // ^
};

pub const ArgModifier = enum { splat, double_splat, block };

pub const NodeIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const StringId = enum(u32) { none = std.math.maxInt(u32), _ };

/// Defines a slice of elements stored in one of the Tree's contiguous arrays
pub const Span = struct {
    start: u32,
    end: u32,
};

// --- Node Payloads ---

pub const Param = struct {
    name: StringId,
    default_value: NodeIndex = .none,
    modifier: ?ArgModifier = null,
    is_keyword: bool = false,
};

pub const NamedArg = struct {
    name: StringId,
    value: NodeIndex,
    modifier: ?ArgModifier = null,
};

pub const HashEntry = struct {
    key: NodeIndex,
    value: NodeIndex,
};

pub const ForBinding = struct {
    name: StringId,
    range: NodeIndex,
};

pub const WhenBranch = struct {
    conditions: Span, // Span of NodeIndex
    body: NodeIndex,
};

pub const LhsExpr = struct {
    name: StringId,
    modifier: ?ArgModifier = null,
};

pub const RescueClause = struct {
    errors: Span, // Span of StringId
    variable: StringId = .none,
    body: NodeIndex,
};

pub const Range = struct {
    start: NodeIndex,
    end: NodeIndex,
    step: NodeIndex = .none,
    is_exclusive: bool = false,
};

pub const Assignment = struct {
    name: StringId,
    op: ?BinaryOp = null,
    value: NodeIndex,
};

pub const MultipleAssignment = struct {
    lhs: Span, // Span of LhsExpr
    op: ?BinaryOp = null,
    value: NodeIndex,
};

pub const PropertyAssignment = struct {
    target: NodeIndex,
    property: StringId,
    op: ?BinaryOp = null,
    value: NodeIndex,
};

pub const IndexAssignment = struct {
    target: NodeIndex,
    index: NodeIndex,
    op: ?BinaryOp = null,
    value: NodeIndex,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    left: NodeIndex,
    right: NodeIndex,
};

pub const TernaryExpr = struct {
    condition: NodeIndex,
    then_branch: NodeIndex,
    else_branch: NodeIndex,
};

pub const MethodCall = struct {
    receiver: NodeIndex = .none,
    method_name: StringId,
    args: Span, // Span of NamedArg
    block: NodeIndex = .none,
    is_safe: bool = false,
};

pub const SuperCall = struct {
    args: Span, // Span of NamedArg
    block: NodeIndex = .none,
};

pub const LambdaExpr = struct {
    params: Span, // Span of Param
    body: NodeIndex,
};

pub const ImportStmt = struct {
    symbols: Span, // Span of StringId
    path: StringId,
    attributes: NodeIndex = .none,
};

pub const ExportStmt = struct {
    symbols: Span, // Span of StringId
    path: StringId,
    attributes: NodeIndex = .none,
};

pub const IfStmt = struct {
    condition: NodeIndex,
    then_branch: NodeIndex,
    else_branch: NodeIndex = .none,
    is_unless: bool = false,
};

pub const CaseStmt = struct {
    condition: NodeIndex = .none,
    when_branches: Span, // Span of WhenBranch
    else_branch: NodeIndex = .none,
};

pub const WhileStmt = struct {
    condition: NodeIndex,
    body: NodeIndex,
    is_until: bool = false,
};

pub const ForStmt = struct {
    bindings: Span, // Span of ForBinding
    body: NodeIndex,
    is_intersection: bool = false,
};

pub const DefStmt = struct {
    name: StringId,
    params: Span, // Span of Param
    body: NodeIndex,
    is_class_method: bool = false,
};

pub const ClassStmt = struct {
    name: NodeIndex,
    super_class: NodeIndex = .none,
    body: NodeIndex,
};

pub const ModuleStmt = struct {
    name: StringId,
    params: Span, // Span of Param
    body: NodeIndex,
};

pub const BeginStmt = struct {
    body: NodeIndex,
    rescues: Span, // Span of RescueClause
    ensure_body: NodeIndex = .none,
};

pub const Block = struct {
    params: Span, // Span of NodeIndex
    stmts: Span, // Span of NodeIndex
};

pub const ParamDoc = struct {
    tag_name: StringId,
    target_name: StringId = .none,
    type_name: StringId = .none,
    description: StringId,
    options_expr: NodeIndex = .none,
};

pub const NodeKind = union(enum) {
    number: f64,
    string: StringId,
    interpolated_string: Span, // Span of NodeIndex
    symbol: StringId,
    boolean: bool,
    nil,
    undef,
    self_expr,
    array_literal: Span, // Span of NodeIndex
    hash_literal: Span, // Span of HashEntry
    range: Range,
    identifier: StringId,
    namespace_access: Span, // Span of StringId
    assignment: Assignment,
    multiple_assignment: MultipleAssignment,
    property_assignment: PropertyAssignment,
    index_assignment: IndexAssignment,
    unary_op: struct { op: UnaryOp, operand: NodeIndex },
    rescue_modifier: struct { expr: NodeIndex, rescue_expr: NodeIndex },
    binary_op: BinaryExpr,
    ternary_op: TernaryExpr,
    index_access: struct { target: NodeIndex, index: NodeIndex },
    splat_expr: NodeIndex,
    double_splat_expr: NodeIndex,
    each_expr: NodeIndex,
    method_call: MethodCall,
    super_call: SuperCall,
    lambda_expr: LambdaExpr,
    import_stmt: ImportStmt,
    export_stmt: ExportStmt,
    if_stmt: IfStmt,
    case_stmt: CaseStmt,
    while_stmt: WhileStmt,
    for_stmt: ForStmt,
    def_stmt: DefStmt,
    class_stmt: ClassStmt,
    module_stmt: ModuleStmt,
    begin_stmt: BeginStmt,
    return_stmt: NodeIndex,
    yield_stmt: Span, // Span of NodeIndex
    break_stmt: NodeIndex,
    next_stmt: NodeIndex,
    param_doc: u32,
    comment: StringId,
    block: Block,
};

pub const Node = struct {
    kind: NodeKind,
    loc: Location,
};

// --- Data-Oriented Memory Pools ---

pub const StringPool = struct {
    map: std.StringHashMapUnmanaged(StringId) = .empty,
    list: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *StringPool, allocator: std.mem.Allocator) void {
        for (self.list.items) |str| allocator.free(str);
        self.map.deinit(allocator);
        self.list.deinit(allocator);
    }

    pub fn intern(self: *StringPool, allocator: std.mem.Allocator, str: []const u8) !StringId {
        if (str.len == 0) return .none;
        if (self.map.get(str)) |id| return id;

        const duped = try allocator.dupe(u8, str);
        errdefer allocator.free(duped);

        const id: u32 = @intCast(self.list.items.len);
        try self.list.append(allocator, duped);
        try self.map.put(allocator, duped, @enumFromInt(id));
        return @enumFromInt(id);
    }

    pub fn get(self: *const StringPool, id: StringId) []const u8 {
        if (id == .none) return "";
        return self.list.items[@intFromEnum(id)];
    }
};

pub const Tree = struct {
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    root: NodeIndex = .none,

    strings: StringPool = .{},
    param_docs: std.ArrayListUnmanaged(ParamDoc) = .empty,

    // Contiguous Span Storage Arrays
    node_lists: std.ArrayListUnmanaged(NodeIndex) = .empty,
    hash_entries: std.ArrayListUnmanaged(HashEntry) = .empty,
    params: std.ArrayListUnmanaged(Param) = .empty,
    named_args: std.ArrayListUnmanaged(NamedArg) = .empty,
    when_branches: std.ArrayListUnmanaged(WhenBranch) = .empty,
    lhs_exprs: std.ArrayListUnmanaged(LhsExpr) = .empty,
    rescue_clauses: std.ArrayListUnmanaged(RescueClause) = .empty,
    for_bindings: std.ArrayListUnmanaged(ForBinding) = .empty,
    string_lists: std.ArrayListUnmanaged(StringId) = .empty,

    pub fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.strings.deinit(allocator);
        self.param_docs.deinit(allocator);
        self.node_lists.deinit(allocator);
        self.hash_entries.deinit(allocator);
        self.params.deinit(allocator);
        self.named_args.deinit(allocator);
        self.when_branches.deinit(allocator);
        self.lhs_exprs.deinit(allocator);
        self.rescue_clauses.deinit(allocator);
        self.for_bindings.deinit(allocator);
        self.string_lists.deinit(allocator);
    }

    pub inline fn getNode(self: *const Tree, index: NodeIndex) ?*const Node {
        if (index == .none) return null;
        const idx = @intFromEnum(index);
        if (idx >= self.nodes.items.len) return null;
        return &self.nodes.items[idx];
    }

    pub inline fn getString(self: *const Tree, id: StringId) []const u8 {
        return self.strings.get(id);
    }

    // Resolvers for Spans
    pub inline fn getNodes(self: *const Tree, span: Span) []const NodeIndex {
        return self.node_lists.items[span.start..span.end];
    }
    pub inline fn getHashEntries(self: *const Tree, span: Span) []const HashEntry {
        return self.hash_entries.items[span.start..span.end];
    }
    pub inline fn getParams(self: *const Tree, span: Span) []const Param {
        return self.params.items[span.start..span.end];
    }
    pub inline fn getNamedArgs(self: *const Tree, span: Span) []const NamedArg {
        return self.named_args.items[span.start..span.end];
    }
    pub inline fn getWhenBranches(self: *const Tree, span: Span) []const WhenBranch {
        return self.when_branches.items[span.start..span.end];
    }
    pub inline fn getLhsExprs(self: *const Tree, span: Span) []const LhsExpr {
        return self.lhs_exprs.items[span.start..span.end];
    }
    pub inline fn getRescueClauses(self: *const Tree, span: Span) []const RescueClause {
        return self.rescue_clauses.items[span.start..span.end];
    }
    pub inline fn getForBindings(self: *const Tree, span: Span) []const ForBinding {
        return self.for_bindings.items[span.start..span.end];
    }
    pub inline fn getStringLists(self: *const Tree, span: Span) []const StringId {
        return self.string_lists.items[span.start..span.end];
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    tree: Tree = .{},

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        self.tree.deinit(self.allocator);
    }

    pub fn intern(self: *Builder, str: []const u8) !StringId {
        return self.tree.strings.intern(self.allocator, str);
    }

    pub fn createNode(self: *Builder, kind: NodeKind, loc: Location) !NodeIndex {
        const idx: u32 = @intCast(self.tree.nodes.items.len);
        try self.tree.nodes.append(self.allocator, .{ .kind = kind, .loc = loc });
        return @enumFromInt(idx);
    }

    pub fn addParamDoc(self: *Builder, doc: ParamDoc) !u32 {
        const idx: u32 = @intCast(self.tree.param_docs.items.len);
        try self.tree.param_docs.append(self.allocator, doc);
        return idx;
    }

    // --- Span Generators ---
    pub fn addNodes(self: *Builder, items: []const NodeIndex) !Span {
        const start: u32 = @intCast(self.tree.node_lists.items.len);
        try self.tree.node_lists.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = @intCast(self.tree.node_lists.items.len) };
    }
    pub fn addHashEntries(self: *Builder, items: []const HashEntry) !Span {
        const start: u32 = @intCast(self.tree.hash_entries.items.len);
        try self.tree.hash_entries.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = @intCast(self.tree.hash_entries.items.len) };
    }
    pub fn addParams(self: *Builder, items: []const Param) !Span {
        const start: u32 = @intCast(self.tree.params.items.len);
        try self.tree.params.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = @intCast(self.tree.params.items.len) };
    }
    pub fn addNamedArgs(self: *Builder, items: []const NamedArg) !Span {
        const start: u32 = @intCast(self.tree.named_args.items.len);
        try self.tree.named_args.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = @intCast(self.tree.named_args.items.len) };
    }
    pub fn addWhenBranches(self: *Builder, items: []const WhenBranch) !Span {
        const start: u32 = @intCast(self.tree.when_branches.items.len);
        try self.tree.when_branches.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = @intCast(self.tree.when_branches.items.len) };
    }
    pub fn addLhsExprs(self: *Builder, items: []const LhsExpr) !Span {
        const start: u32 = @intCast(self.tree.lhs_exprs.items.len);
        try self.tree.lhs_exprs.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = @intCast(self.tree.lhs_exprs.items.len) };
    }
    pub fn addRescueClauses(self: *Builder, items: []const RescueClause) !Span {
        const start: u32 = @intCast(self.tree.rescue_clauses.items.len);
        try self.tree.rescue_clauses.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = @intCast(self.tree.rescue_clauses.items.len) };
    }
    pub fn addForBindings(self: *Builder, items: []const ForBinding) !Span {
        const start: u32 = @intCast(self.tree.for_bindings.items.len);
        try self.tree.for_bindings.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = @intCast(self.tree.for_bindings.items.len) };
    }
    pub fn addStringLists(self: *Builder, items: []const StringId) !Span {
        const start: u32 = @intCast(self.tree.string_lists.items.len);
        try self.tree.string_lists.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = @intCast(self.tree.string_lists.items.len) };
    }

    // --- Legacy Builder Wrappers ---

    pub fn number(self: *Builder, lexeme: []const u8, loc: Location) !NodeIndex {
        var buf: [128]u8 = undefined;
        var len: usize = 0;
        for (lexeme) |c| {
            if (c != '_') {
                if (len >= buf.len) return error.InvalidExpression;
                buf[len] = c;
                len += 1;
            }
        }
        const clean = buf[0..len];
        if (clean.len == 0) return error.InvalidExpression;
        var val: f64 = 0;
        if (clean.len > 2 and clean[0] == '0') {
            const prefix = clean[1];
            if (prefix == 'x' or prefix == 'X') {
                const int_val = std.fmt.parseInt(u64, clean[2..], 16) catch return error.InvalidExpression;
                val = @floatFromInt(int_val);
            } else if (prefix == 'b' or prefix == 'B') {
                const int_val = std.fmt.parseInt(u64, clean[2..], 2) catch return error.InvalidExpression;
                val = @floatFromInt(int_val);
            } else if (prefix == 'o' or prefix == 'O') {
                const int_val = std.fmt.parseInt(u64, clean[2..], 8) catch return error.InvalidExpression;
                val = @floatFromInt(int_val);
            } else {
                val = std.fmt.parseFloat(f64, clean) catch return error.InvalidExpression;
            }
        } else {
            val = std.fmt.parseFloat(f64, clean) catch return error.InvalidExpression;
        }
        var final_loc = loc;
        if (final_loc.length == 0) final_loc.length = @as(u32, @intCast(lexeme.len));
        return self.createNode(.{ .number = val }, final_loc);
    }

    pub fn binary(self: *Builder, op: BinaryOp, left: NodeIndex, right: NodeIndex, loc: Location) !NodeIndex {
        return self.createNode(.{ .binary_op = .{ .op = op, .left = left, .right = right } }, loc);
    }

    pub fn block(self: *Builder, params: []const NodeIndex, stmts: []const NodeIndex, loc: Location) !NodeIndex {
        return self.createNode(.{ .block = .{ .params = try self.addNodes(params), .stmts = try self.addNodes(stmts) } }, loc);
    }

    pub fn assignment(self: *Builder, name: StringId, op: ?BinaryOp, value: NodeIndex, loc: Location) !NodeIndex {
        return self.createNode(.{ .assignment = .{ .name = name, .op = op, .value = value } }, loc);
    }

    pub fn ifStmt(self: *Builder, condition: NodeIndex, then_branch: NodeIndex, else_branch: NodeIndex, is_unless: bool, loc: Location) !NodeIndex {
        return self.createNode(.{ .if_stmt = .{ .condition = condition, .then_branch = then_branch, .else_branch = else_branch, .is_unless = is_unless } }, loc);
    }

    pub fn whileStmt(self: *Builder, condition: NodeIndex, body: NodeIndex, is_until: bool, loc: Location) !NodeIndex {
        return self.createNode(.{ .while_stmt = .{ .condition = condition, .body = body, .is_until = is_until } }, loc);
    }

    pub fn undefNode(self: *Builder, loc: Location) !NodeIndex {
        return self.createNode(.undef, loc);
    }

    pub fn booleanNode(self: *Builder, val: bool, loc: Location) !NodeIndex {
        var final_loc = loc;
        if (final_loc.length == 0) final_loc.length = if (val) 4 else 5;
        return self.createNode(.{ .boolean = val }, final_loc);
    }

    pub fn identifierNode(self: *Builder, name: []const u8, loc: Location) !NodeIndex {
        var final_loc = loc;
        if (final_loc.length == 0) final_loc.length = @as(u32, @intCast(name.len));
        const interned = try self.intern(name);
        return self.createNode(.{ .identifier = interned }, final_loc);
    }

    pub fn stringNode(self: *Builder, str: []const u8, loc: Location) !NodeIndex {
        var final_loc = loc;
        if (final_loc.length == 0) final_loc.length = @as(u32, @intCast(str.len));
        const interned = try self.intern(str);
        return self.createNode(.{ .string = interned }, final_loc);
    }

    pub fn symbolNode(self: *Builder, sym: []const u8, loc: Location) !NodeIndex {
        var final_loc = loc;
        if (final_loc.length == 0) final_loc.length = @as(u32, @intCast(sym.len));
        const interned = try self.intern(sym);
        return self.createNode(.{ .symbol = interned }, final_loc);
    }
};

pub const Visitor = struct {
    ptr: *anyopaque,
    visitFn: *const fn (ptr: *anyopaque, tree: *const Tree, node_idx: NodeIndex) anyerror!bool,

    pub fn walk(self: Visitor, tree: *const Tree, node_idx: NodeIndex) anyerror!void {
        if (node_idx == .none) return;
        const node = tree.getNode(node_idx) orelse return;

        const traverse_children = try self.visitFn(self.ptr, tree, node_idx);
        if (!traverse_children) return;

        switch (node.kind) {
            .number, .string, .symbol, .boolean, .nil, .undef, .self_expr, .identifier, .comment, .namespace_access => {},
            .param_doc => |doc_idx| {
                const doc = tree.param_docs.items[doc_idx];
                try self.walk(tree, doc.options_expr);
            },
            .interpolated_string => |span| for (tree.getNodes(span)) |p| try self.walk(tree, p),
            .array_literal => |span| for (tree.getNodes(span)) |elem| try self.walk(tree, elem),
            .hash_literal => |span| {
                for (tree.getHashEntries(span)) |e| {
                    try self.walk(tree, e.key);
                    try self.walk(tree, e.value);
                }
            },
            .range => |r| {
                try self.walk(tree, r.start);
                try self.walk(tree, r.end);
                try self.walk(tree, r.step);
            },
            .assignment => |a| try self.walk(tree, a.value),
            .multiple_assignment => |ma| try self.walk(tree, ma.value),
            .property_assignment => |pa| {
                try self.walk(tree, pa.target);
                try self.walk(tree, pa.value);
            },
            .index_assignment => |ia| {
                try self.walk(tree, ia.target);
                try self.walk(tree, ia.index);
                try self.walk(tree, ia.value);
            },
            .unary_op => |u| try self.walk(tree, u.operand),
            .rescue_modifier => |rm| {
                try self.walk(tree, rm.expr);
                try self.walk(tree, rm.rescue_expr);
            },
            .binary_op => |b| {
                try self.walk(tree, b.left);
                try self.walk(tree, b.right);
            },
            .ternary_op => |t| {
                try self.walk(tree, t.condition);
                try self.walk(tree, t.then_branch);
                try self.walk(tree, t.else_branch);
            },
            .index_access => |ia| {
                try self.walk(tree, ia.target);
                try self.walk(tree, ia.index);
            },
            .splat_expr => |s| try self.walk(tree, s),
            .double_splat_expr => |s| try self.walk(tree, s),
            .each_expr => |e| try self.walk(tree, e),
            .method_call => |mc| {
                try self.walk(tree, mc.receiver);
                for (tree.getNamedArgs(mc.args)) |a| try self.walk(tree, a.value);
                try self.walk(tree, mc.block);
            },
            .super_call => |sc| {
                for (tree.getNamedArgs(sc.args)) |a| try self.walk(tree, a.value);
                try self.walk(tree, sc.block);
            },
            .lambda_expr => |le| try self.walk(tree, le.body),
            .import_stmt => |is| try self.walk(tree, is.attributes),
            .export_stmt => |es| try self.walk(tree, es.attributes),
            .if_stmt => |ifs| {
                try self.walk(tree, ifs.condition);
                try self.walk(tree, ifs.then_branch);
                try self.walk(tree, ifs.else_branch);
            },
            .case_stmt => |cs| {
                try self.walk(tree, cs.condition);
                for (tree.getWhenBranches(cs.when_branches)) |wb| {
                    for (tree.getNodes(wb.conditions)) |cond| try self.walk(tree, cond);
                    try self.walk(tree, wb.body);
                }
                try self.walk(tree, cs.else_branch);
            },
            .while_stmt => |ws| {
                try self.walk(tree, ws.condition);
                try self.walk(tree, ws.body);
            },
            .for_stmt => |fs| {
                for (tree.getForBindings(fs.bindings)) |b| try self.walk(tree, b.range);
                try self.walk(tree, fs.body);
            },
            .def_stmt => |ds| try self.walk(tree, ds.body),
            .class_stmt => |cs| {
                try self.walk(tree, cs.name);
                try self.walk(tree, cs.super_class);
                try self.walk(tree, cs.body);
            },
            .module_stmt => |ms| try self.walk(tree, ms.body),
            .begin_stmt => |bs| {
                try self.walk(tree, bs.body);
                for (tree.getRescueClauses(bs.rescues)) |r| try self.walk(tree, r.body);
                try self.walk(tree, bs.ensure_body);
            },
            .return_stmt => |r| try self.walk(tree, r),
            .yield_stmt => |span| for (tree.getNodes(span)) |expr| try self.walk(tree, expr),
            .break_stmt => |b| try self.walk(tree, b),
            .next_stmt => |n| try self.walk(tree, n),
            .block => |b| for (tree.getNodes(b.stmts)) |s| try self.walk(tree, s),
        }
    }
};
