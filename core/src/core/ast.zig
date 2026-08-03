const std = @import("std");

pub const Location = @import("../parsers/common/token.zig").Location;

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

pub const Param = struct {
    name: []const u8,
    default_value: ?*Node = null,
    modifier: ?ArgModifier = null,
    is_keyword: bool = false,
};

pub const NamedArg = struct {
    name: []const u8,
    value: *Node,
    modifier: ?ArgModifier = null,
};

pub const HashEntry = struct {
    key: *Node,
    value: *Node,
};

pub const ForBinding = struct {
    name: []const u8,
    range: *Node,
};

pub const WhenBranch = struct {
    conditions: []const *Node,
    body: *Node,
};

pub const LhsExpr = struct {
    name: []const u8,
    modifier: ?ArgModifier = null,
};

pub const RescueClause = struct {
    errors: []const []const u8,
    variable: ?[]const u8,
    body: *Node,
};

// --- STANDALONE BOXED AST PAYLOADS ---

pub const Range = struct {
    start: *Node,
    end: *Node,
    step: ?*Node = null,
    is_exclusive: bool = false,
};

pub const Assignment = struct {
    name: []const u8,
    op: ?BinaryOp = null,
    value: *Node,
};

pub const MultipleAssignment = struct {
    lhs: []const LhsExpr,
    op: ?BinaryOp = null,
    value: *Node,
};

pub const PropertyAssignment = struct {
    target: *Node,
    property: []const u8,
    op: ?BinaryOp = null,
    value: *Node,
};

pub const IndexAssignment = struct {
    target: *Node,
    index: *Node,
    op: ?BinaryOp = null,
    value: *Node,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    left: *Node,
    right: *Node,
};

pub const TernaryExpr = struct {
    condition: *Node,
    then_branch: *Node,
    else_branch: *Node,
};

pub const MethodCall = struct {
    receiver: ?*Node = null,
    method_name: []const u8,
    args: []const NamedArg = &.{},
    block: ?*Node = null,
    is_safe: bool = false,
};

pub const SuperCall = struct {
    args: []const NamedArg = &.{},
    block: ?*Node = null,
};

pub const LambdaExpr = struct {
    params: []const Param,
    body: *Node,
};

pub const ImportStmt = struct {
    symbols: []const []const u8 = &.{},
    path: []const u8,
    attributes: ?*Node = null,
};

pub const ExportStmt = struct {
    symbols: []const []const u8 = &.{},
    path: []const u8,
    attributes: ?*Node = null,
};

pub const IfStmt = struct {
    condition: *Node,
    then_branch: *Node,
    else_branch: ?*Node = null,
    is_unless: bool = false,
};

pub const CaseStmt = struct {
    condition: ?*Node = null,
    when_branches: []const WhenBranch = &.{},
    else_branch: ?*Node = null,
};

pub const WhileStmt = struct {
    condition: *Node,
    body: *Node,
    is_until: bool = false,
};

pub const ForStmt = struct {
    bindings: []const ForBinding,
    body: *Node,
    is_intersection: bool = false,
};

pub const DefStmt = struct {
    name: []const u8,
    params: []const Param = &.{},
    body: *Node,
    is_class_method: bool = false,
};

pub const ClassStmt = struct {
    name: *Node,
    super_class: ?*Node = null,
    body: *Node,
};

pub const ModuleStmt = struct {
    name: []const u8,
    params: []const Param = &.{},
    body: *Node,
};

pub const BeginStmt = struct {
    body: *Node,
    rescues: []const RescueClause = &.{},
    ensure_body: ?*Node = null,
};

pub const Block = struct {
    params: []const *Node = &.{},
    stmts: []const *Node,
};

pub const NodeKind = union(enum) {
    // Literals
    number: f64,
    string: []const u8,
    interpolated_string: []const *Node,
    symbol: []const u8,
    boolean: bool,
    nil,
    undef,
    self_expr,
    array_literal: []const *Node,
    hash_literal: []const HashEntry,

    // Range
    range: *Range,

    // Variable lookup & Namespace Resolution
    identifier: []const u8,
    namespace_access: struct {
        path: []const []const u8,
    },

    // Assignments
    assignment: *Assignment,
    multiple_assignment: *MultipleAssignment,
    property_assignment: *PropertyAssignment,
    index_assignment: *IndexAssignment,

    // Unary
    unary_op: struct {
        op: UnaryOp,
        operand: *Node,
    },
    rescue_modifier: struct {
        expr: *Node,
        rescue_expr: *Node,
    },

    // Binary & Ternary
    binary_op: *BinaryExpr,
    ternary_op: *TernaryExpr,

    // Index Access
    index_access: struct {
        target: *Node,
        index: *Node,
    },
    splat_expr: *Node,
    double_splat_expr: *Node,
    each_expr: *Node,

    // Calls
    method_call: *MethodCall,
    super_call: *SuperCall,
    lambda_expr: *LambdaExpr,

    // Statement Constructs
    import_stmt: *ImportStmt,
    export_stmt: *ExportStmt,
    if_stmt: *IfStmt,
    case_stmt: *CaseStmt,
    while_stmt: *WhileStmt,
    for_stmt: *ForStmt,
    def_stmt: *DefStmt,
    class_stmt: *ClassStmt,
    module_stmt: *ModuleStmt,
    begin_stmt: *BeginStmt,

    return_stmt: ?*Node,
    yield_stmt: []const *Node,
    break_stmt: ?*Node,
    next_stmt: ?*Node,

    param_doc: []const u8,
    comment: []const u8,

    // Block Scope
    block: *Block,
};

pub const Node = struct {
    kind: NodeKind,
    loc: Location,
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

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        self.pool.deinit(self.allocator);
    }

    pub fn intern(self: *Builder, str: []const u8) ![]const u8 {
        return self.pool.intern(self.allocator, str);
    }

    pub fn createNode(self: *const Builder, kind: NodeKind, loc: Location) !*Node {
        const n = try self.allocator.create(Node);
        n.* = .{ .kind = kind, .loc = loc };
        return n;
    }

    pub fn box(self: *const Builder, comptime T: type, val: T) !*T {
        const ptr = try self.allocator.create(T);
        ptr.* = val;
        return ptr;
    }

    pub fn number(self: *const Builder, lexeme: []const u8, loc: Location) !*Node {
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

        return self.createNode(.{ .number = val }, loc);
    }

    pub fn undefNode(self: *const Builder, loc: Location) !*Node {
        return self.createNode(.undef, loc);
    }

    pub fn booleanNode(self: *const Builder, val: bool, loc: Location) !*Node {
        return self.createNode(.{ .boolean = val }, loc);
    }

    pub fn identifierNode(self: *Builder, name: []const u8, loc: Location) !*Node {
        const interned = try self.intern(name);
        return self.createNode(.{ .identifier = interned }, loc);
    }

    pub fn stringNode(self: *Builder, str: []const u8, loc: Location) !*Node {
        const interned = try self.intern(str);
        return self.createNode(.{ .string = interned }, loc);
    }

    pub fn symbolNode(self: *Builder, sym: []const u8, loc: Location) !*Node {
        const interned = try self.intern(sym);
        return self.createNode(.{ .symbol = interned }, loc);
    }
};
