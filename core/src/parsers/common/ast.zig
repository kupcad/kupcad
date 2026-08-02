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

pub const Comprehension = struct {
    clauses: []const *Node = &.{},
    yield_expr: *Node,
};

pub const LetExpr = struct {
    assignments: []const *Node,
    yield_expr: *Node,
};

pub const AssertExpr = struct {
    args: []const NamedArg,
    yield_expr: *Node,
};

pub const EchoExpr = struct {
    args: []const NamedArg,
    yield_expr: *Node,
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

pub const ModifierCall = struct {
    modifier: []const u8,
    child: *Node,
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

pub const IncludeStmt = struct {
    path: []const u8,
    is_use: bool = false,
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

pub const CForStmt = struct {
    init: []const *Node,
    condition: ?*Node = null,
    update: []const *Node,
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

pub const OpenScadKind = union(enum) {
    // Literals
    number: f64,
    string: []const u8,
    boolean: bool,
    undef,
    array_literal: []const *Node,

    // Range
    range: *Range,

    // Variable lookup
    identifier: []const u8,

    // Assignments
    assignment: *Assignment,

    // Unary
    unary_op: struct {
        op: UnaryOp,
        operand: *Node,
    },

    // Binary & Ternary
    binary_op: *BinaryExpr,
    ternary_op: *TernaryExpr,

    // Index Access
    index_access: struct {
        target: *Node,
        index: *Node,
    },

    // List Comprehension & Let
    comprehension: *Comprehension,
    let_expr: *LetExpr,
    each_expr: *Node,

    // Modifiers
    assert_expr: *AssertExpr,
    echo_expr: *EchoExpr,

    // Calls
    method_call: *MethodCall,
    lambda_expr: *LambdaExpr,
    modifier_call: *ModifierCall,

    // Statement Constructs
    include_stmt: *IncludeStmt,
    if_stmt: *IfStmt,
    for_stmt: *ForStmt,
    c_for_stmt: *CForStmt,
    def_stmt: *DefStmt,
    module_stmt: *ModuleStmt,

    // Block Scope
    block: *Block,
};

pub const KupCadKind = union(enum) {
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
    kind: Kind,
    loc: Location,

    pub const Kind = union(enum) {
        openscad: OpenScadKind,
        kupcad: KupCadKind,
    };
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

pub const Dialect = enum { openscad, kupcad };

pub const Builder = struct {
    allocator: std.mem.Allocator,
    pool: StringPool = .{},
    dialect: Dialect,

    pub fn init(allocator: std.mem.Allocator, dialect: Dialect) Builder {
        return .{ .allocator = allocator, .dialect = dialect };
    }

    pub fn deinit(self: *Builder) void {
        self.pool.deinit(self.allocator);
    }

    pub fn intern(self: *Builder, str: []const u8) ![]const u8 {
        return self.pool.intern(self.allocator, str);
    }

    pub fn createOpenScad(self: *const Builder, kind: OpenScadKind, loc: Location) !*Node {
        const n = try self.allocator.create(Node);
        n.* = .{ .kind = .{ .openscad = kind }, .loc = loc };
        return n;
    }

    pub fn createKupCad(self: *const Builder, kind: KupCadKind, loc: Location) !*Node {
        const n = try self.allocator.create(Node);
        n.* = .{ .kind = .{ .kupcad = kind }, .loc = loc };
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

        if (self.dialect == .openscad) {
            return self.createOpenScad(.{ .number = val }, loc);
        } else {
            return self.createKupCad(.{ .number = val }, loc);
        }
    }

    pub fn undefNode(self: *const Builder, loc: Location) !*Node {
        if (self.dialect == .openscad) {
            return self.createOpenScad(.undef, loc);
        } else {
            return self.createKupCad(.undef, loc);
        }
    }

    pub fn booleanNode(self: *const Builder, val: bool, loc: Location) !*Node {
        if (self.dialect == .openscad) {
            return self.createOpenScad(.{ .boolean = val }, loc);
        } else {
            return self.createKupCad(.{ .boolean = val }, loc);
        }
    }

    pub fn identifierNode(self: *Builder, name: []const u8, loc: Location) !*Node {
        const interned = try self.intern(name);
        if (self.dialect == .openscad) {
            return self.createOpenScad(.{ .identifier = interned }, loc);
        } else {
            return self.createKupCad(.{ .identifier = interned }, loc);
        }
    }

    pub fn stringNode(self: *Builder, str: []const u8, loc: Location) !*Node {
        const interned = try self.intern(str);
        if (self.dialect == .openscad) {
            return self.createOpenScad(.{ .string = interned }, loc);
        } else {
            return self.createKupCad(.{ .string = interned }, loc);
        }
    }

    pub fn symbolNode(self: *Builder, sym: []const u8, loc: Location) !*Node {
        const interned = try self.intern(sym);
        return self.createKupCad(.{ .symbol = interned }, loc);
    }
};
