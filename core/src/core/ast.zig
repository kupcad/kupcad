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

pub const ArgModifier = enum {
    splat, // *
    double_splat, // **
    block, // &
};

pub const NodeIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};

pub const TokenIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,
};

pub const Param = struct {
    name: []const u8,
    default_value: NodeIndex = .none,
    modifier: ?ArgModifier = null,
    is_keyword: bool = false,
};

pub const NamedArg = struct {
    name: []const u8,
    value: NodeIndex,
    modifier: ?ArgModifier = null,
};

pub const HashEntry = struct {
    key: NodeIndex,
    value: NodeIndex,
};

pub const ForBinding = struct {
    name: []const u8,
    range: NodeIndex,
};

pub const WhenBranch = struct {
    conditions: []const NodeIndex,
    body: NodeIndex,
};

pub const LhsExpr = struct {
    name: []const u8,
    modifier: ?ArgModifier = null,
};

pub const RescueClause = struct {
    errors: []const []const u8,
    variable: ?[]const u8,
    body: NodeIndex,
};

pub const Range = struct {
    start: NodeIndex,
    end: NodeIndex,
    step: NodeIndex = .none,
    is_exclusive: bool = false,
};

pub const Assignment = struct {
    name: []const u8,
    op: ?BinaryOp = null,
    value: NodeIndex,
};

pub const MultipleAssignment = struct {
    lhs: []const LhsExpr,
    op: ?BinaryOp = null,
    value: NodeIndex,
};

pub const PropertyAssignment = struct {
    target: NodeIndex,
    property: []const u8,
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
    method_name: []const u8,
    args: []const NamedArg = &.{},
    block: NodeIndex = .none,
    is_safe: bool = false,
};

pub const SuperCall = struct {
    args: []const NamedArg = &.{},
    block: NodeIndex = .none,
};

pub const LambdaExpr = struct {
    params: []const Param,
    body: NodeIndex,
};

pub const ImportStmt = struct {
    symbols: []const []const u8 = &.{},
    path: []const u8,
    attributes: NodeIndex = .none,
};

pub const ExportStmt = struct {
    symbols: []const []const u8 = &.{},
    path: []const u8,
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
    when_branches: []const WhenBranch = &.{},
    else_branch: NodeIndex = .none,
};

pub const WhileStmt = struct {
    condition: NodeIndex,
    body: NodeIndex,
    is_until: bool = false,
};

pub const ForStmt = struct {
    bindings: []const ForBinding,
    body: NodeIndex,
    is_intersection: bool = false,
};

pub const DefStmt = struct {
    name: []const u8,
    params: []const Param = &.{},
    body: NodeIndex,
    is_class_method: bool = false,
};

pub const ClassStmt = struct {
    name: NodeIndex,
    super_class: NodeIndex = .none,
    body: NodeIndex,
};

pub const ModuleStmt = struct {
    name: []const u8,
    params: []const Param = &.{},
    body: NodeIndex,
};

pub const BeginStmt = struct {
    body: NodeIndex,
    rescues: []const RescueClause = &.{},
    ensure_body: NodeIndex = .none,
};

pub const Block = struct {
    params: []const NodeIndex = &.{},
    stmts: []const NodeIndex,
};

pub const ParamDoc = struct {
    tag_name: []const u8,
    target_name: ?[]const u8 = null,
    type_name: ?[]const u8 = null,
    description: []const u8 = "",
    options_expr: NodeIndex = .none,
};

pub const NodeKind = union(enum) {
    // Literals
    number: f64,
    string: []const u8,
    interpolated_string: []const NodeIndex,
    symbol: []const u8,
    boolean: bool,
    nil,
    undef,
    self_expr,
    array_literal: []const NodeIndex,
    hash_literal: []const HashEntry,
    // Range
    range: Range,
    // Variable lookup & Namespace Resolution
    identifier: []const u8,
    namespace_access: struct {
        path: []const []const u8,
    },
    // Assignments
    assignment: Assignment,
    multiple_assignment: MultipleAssignment,
    property_assignment: PropertyAssignment,
    index_assignment: IndexAssignment,
    // Unary
    unary_op: struct {
        op: UnaryOp,
        operand: NodeIndex,
    },
    rescue_modifier: struct {
        expr: NodeIndex,
        rescue_expr: NodeIndex,
    },
    // Binary & Ternary
    binary_op: BinaryExpr,
    ternary_op: TernaryExpr,
    // Index Access
    index_access: struct {
        target: NodeIndex,
        index: NodeIndex,
    },
    splat_expr: NodeIndex,
    double_splat_expr: NodeIndex,
    each_expr: NodeIndex,
    // Calls
    method_call: MethodCall,
    super_call: SuperCall,
    lambda_expr: LambdaExpr,
    // Statement Constructs
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
    yield_stmt: []const NodeIndex,
    break_stmt: NodeIndex,
    next_stmt: NodeIndex,
    param_doc: ParamDoc,
    comment: []const u8,
    // Block Scope
    block: Block,
};

pub const Node = struct {
    kind: NodeKind,
    loc: Location,
};

pub const Tree = struct {
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    extra_data: std.ArrayListUnmanaged(u32) = .empty,
    root: NodeIndex = .none,

    pub fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.extra_data.deinit(allocator);
    }

    pub inline fn getNode(self: *const Tree, index: NodeIndex) ?*const Node {
        if (index == .none) return null;
        const idx = @intFromEnum(index);
        if (idx >= self.nodes.items.len) return null;
        return &self.nodes.items[idx];
    }
};

pub const StringPool = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *StringPool, allocator: std.mem.Allocator) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        self.map.deinit(allocator);
    }

    pub fn intern(self: *StringPool, allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
        if (self.map.get(str)) |existing| {
            return existing;
        }
        const duped = try allocator.dupe(u8, str);
        errdefer allocator.free(duped);
        try self.map.put(allocator, duped, duped);
        return duped;
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    pool: StringPool = .{},
    tree: Tree = .{},

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        self.pool.deinit(self.allocator);
        self.tree.deinit(self.allocator);
    }

    pub fn intern(self: *Builder, str: []const u8) ![]const u8 {
        return self.pool.intern(self.allocator, str);
    }

    pub fn createNode(self: *Builder, kind: NodeKind, loc: Location) !NodeIndex {
        const idx: u32 = @intCast(self.tree.nodes.items.len);
        try self.tree.nodes.append(self.allocator, .{ .kind = kind, .loc = loc });
        return @enumFromInt(idx);
    }

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
        return self.createNode(.{ .block = .{ .params = params, .stmts = stmts } }, loc);
    }

    pub fn assignment(self: *Builder, name: []const u8, op: ?BinaryOp, value: NodeIndex, loc: Location) !NodeIndex {
        return self.createNode(.{ .assignment = .{ .name = name, .op = op, .value = value } }, loc);
    }

    pub fn methodCall(self: *Builder, receiver: NodeIndex, method_name: []const u8, args: []const NamedArg, block_node: NodeIndex, is_safe: bool, loc: Location) !NodeIndex {
        return self.createNode(.{ .method_call = .{ .receiver = receiver, .method_name = method_name, .args = args, .block = block_node, .is_safe = is_safe } }, loc);
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
    /// Return true to automatically traverse children, false to skip standard traversal
    visitFn: *const fn (ptr: *anyopaque, tree: *const Tree, node_idx: NodeIndex) anyerror!bool,

    pub fn walk(self: Visitor, tree: *const Tree, node_idx: NodeIndex) anyerror!void {
        if (node_idx == .none) return;
        const node = tree.getNode(node_idx) orelse return;

        const traverse_children = try self.visitFn(self.ptr, tree, node_idx);
        if (!traverse_children) return;

        switch (node.kind) {
            .number, .string, .symbol, .boolean, .nil, .undef, .self_expr, .identifier, .comment, .param_doc, .namespace_access => {},
            .interpolated_string => |parts| for (parts) |p| try self.walk(tree, p),
            .array_literal => |arr| for (arr) |elem| try self.walk(tree, elem),
            .hash_literal => |entries| {
                for (entries) |e| {
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
                for (mc.args) |a| try self.walk(tree, a.value);
                try self.walk(tree, mc.block);
            },
            .super_call => |sc| {
                for (sc.args) |a| try self.walk(tree, a.value);
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
                for (cs.when_branches) |wb| {
                    for (wb.conditions) |cond| try self.walk(tree, cond);
                    try self.walk(tree, wb.body);
                }
                try self.walk(tree, cs.else_branch);
            },
            .while_stmt => |ws| {
                try self.walk(tree, ws.condition);
                try self.walk(tree, ws.body);
            },
            .for_stmt => |fs| {
                for (fs.bindings) |b| try self.walk(tree, b.range);
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
                for (bs.rescues) |r| try self.walk(tree, r.body);
                try self.walk(tree, bs.ensure_body);
            },
            .return_stmt => |r| try self.walk(tree, r),
            .yield_stmt => |y| for (y) |expr| try self.walk(tree, expr),
            .break_stmt => |b| try self.walk(tree, b),
            .next_stmt => |n| try self.walk(tree, n),
            .block => |b| for (b.stmts) |s| try self.walk(tree, s),
        }
    }
};
