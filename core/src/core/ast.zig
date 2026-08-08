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

/// A memory-efficient slice pointing to the contiguous string_bytes buffer
pub const StringSpan = struct {
    offset: u32,
    length: u32,
};

// --- Node Tag ---
pub const Tag = enum(u8) {
    invalid,
    number,
    string,
    boolean,
    identifier,
    symbol,
    nil,
    undef,
    self_expr,
    assignment,
    multiple_assignment,
    property_assignment,
    index_assignment,
    binary_op,
    unary_op,
    ternary_op,
    method_call,
    super_call,
    lambda_expr,
    import_stmt,
    export_stmt,
    if_stmt,
    while_stmt,
    for_stmt,
    case_stmt,
    def_stmt,
    class_stmt,
    module_stmt,
    begin_stmt,
    return_stmt,
    yield_stmt,
    break_stmt,
    next_stmt,
    param_doc,
    block,
    range,
    array_literal,
    hash_literal,
    namespace_access,
    index_access,
    splat_expr,
    double_splat_expr,
    each_expr,
    rescue_modifier,
    interpolated_string,
};

// --- Thin Node (8 bytes) ---
pub const Node = packed struct {
    tag: Tag, // 1 byte (up to 256 tags)
    main_token: u24, // 3 bytes (Index into the SoA TokenList)
    data: u32, // 4 bytes (Index into the extra_data arrays)
};

// --- Node Payloads (Reconstructed from extra_data) ---
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

pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: NodeIndex,
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
    end_token: u32 = 0,
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
    end_token: u32 = 0,
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

pub const CaseStmt = struct {
    condition: NodeIndex = .none,
    when_branches: Span, // Span of WhenBranch
    else_branch: NodeIndex = .none,
};

pub const DefStmt = struct {
    name: StringId,
    params: Span, // Span of Param
    body: NodeIndex,
    is_class_method: bool = false,
    end_token: u32 = 0,
};

pub const ClassStmt = struct {
    name: NodeIndex,
    super_class: NodeIndex = .none,
    body: NodeIndex,
    end_token: u32 = 0,
};

pub const ModuleStmt = struct {
    name: StringId,
    params: Span, // Span of Param
    body: NodeIndex,
    end_token: u32 = 0,
};

pub const BeginStmt = struct {
    body: NodeIndex,
    rescues: Span, // Span of RescueClause
    ensure_body: NodeIndex = .none,
};

pub const ParamDoc = struct {
    tag_name: StringId,
    target_name: StringId = .none,
    type_name: StringId = .none,
    description: StringId,
    options_expr: NodeIndex = .none,
};

pub const Block = struct {
    params: Span, // Span of NodeIndex
    stmts: Span, // Span of NodeIndex
    end_token: u32 = 0,
};

pub const ArrayLiteral = struct {
    span: Span, // Span of NodeIndex
    end_token: u32 = 0,
};

pub const IndexAccess = struct {
    target: NodeIndex,
    index: NodeIndex,
};

pub const RescueModifier = struct {
    expr: NodeIndex,
    rescue_expr: NodeIndex,
};

// --- Tree Structure ---
pub const Tree = struct {
    root: NodeIndex = .none,

    // Core node storage
    nodes: std.ArrayListUnmanaged(Node) = .empty,

    // Unified DoD Storage for all AST Payloads
    extra_data: std.ArrayListUnmanaged(u32) = .empty,

    // Contiguous String Interner Pool
    string_bytes: std.ArrayListUnmanaged(u8) = .empty,
    string_spans: std.ArrayListUnmanaged(StringSpan) = .empty,

    // Specific typed pools for precision arrays
    numbers: std.ArrayListUnmanaged(f64) = .empty,

    // Auxiliary typed lists for spans
    extra_node_indices: std.ArrayListUnmanaged(NodeIndex) = .empty,
    extra_string_indices: std.ArrayListUnmanaged(StringId) = .empty,
    named_args: std.ArrayListUnmanaged(NamedArg) = .empty,
    params: std.ArrayListUnmanaged(Param) = .empty,
    hash_entries: std.ArrayListUnmanaged(HashEntry) = .empty,
    for_bindings: std.ArrayListUnmanaged(ForBinding) = .empty,
    when_branches: std.ArrayListUnmanaged(WhenBranch) = .empty,
    lhs_exprs: std.ArrayListUnmanaged(LhsExpr) = .empty,
    rescue_clauses: std.ArrayListUnmanaged(RescueClause) = .empty,

    pub fn init(allocator: std.mem.Allocator) Tree {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.extra_data.deinit(allocator);

        self.string_bytes.deinit(allocator);
        self.string_spans.deinit(allocator);

        self.numbers.deinit(allocator);
        self.extra_node_indices.deinit(allocator);
        self.extra_string_indices.deinit(allocator);
        self.named_args.deinit(allocator);
        self.params.deinit(allocator);
        self.hash_entries.deinit(allocator);
        self.for_bindings.deinit(allocator);
        self.when_branches.deinit(allocator);
        self.lhs_exprs.deinit(allocator);
        self.rescue_clauses.deinit(allocator);
    }

    // --- Accessor Helpers ---
    pub fn getNode(self: *const Tree, index: NodeIndex) ?*const Node {
        if (index == .none) return null;
        return &self.nodes.items[@intFromEnum(index)];
    }

    pub fn getString(self: *const Tree, id: StringId) []const u8 {
        if (id == .none) return "";
        const span = self.string_spans.items[@intFromEnum(id)];
        return self.string_bytes.items[span.offset .. span.offset + span.length];
    }

    pub fn getNodes(self: *const Tree, span: Span) []const NodeIndex {
        return self.extra_node_indices.items[span.start..span.end];
    }

    pub fn getStringLists(self: *const Tree, span: Span) []const StringId {
        return self.extra_string_indices.items[span.start..span.end];
    }

    pub fn getNamedArgs(self: *const Tree, span: Span) []const NamedArg {
        return self.named_args.items[span.start..span.end];
    }

    pub fn getParams(self: *const Tree, span: Span) []const Param {
        return self.params.items[span.start..span.end];
    }

    pub fn getHashEntries(self: *const Tree, span: Span) []const HashEntry {
        return self.hash_entries.items[span.start..span.end];
    }

    pub fn getForBindings(self: *const Tree, span: Span) []const ForBinding {
        return self.for_bindings.items[span.start..span.end];
    }

    pub fn getWhenBranches(self: *const Tree, span: Span) []const WhenBranch {
        return self.when_branches.items[span.start..span.end];
    }

    pub fn getLhsExprs(self: *const Tree, span: Span) []const LhsExpr {
        return self.lhs_exprs.items[span.start..span.end];
    }

    pub fn getRescueClauses(self: *const Tree, span: Span) []const RescueClause {
        return self.rescue_clauses.items[span.start..span.end];
    }

    // --- Dynamic Payload Reconstructors ---

    pub fn number(self: *const Tree, node: *const Node) f64 {
        return self.numbers.items[node.data];
    }

    pub fn boolean(self: *const Tree, node: *const Node) bool {
        _ = self;
        return node.data != 0;
    }

    pub fn nodeIndex(self: *const Tree, node: *const Node) NodeIndex {
        _ = self;
        return @enumFromInt(node.data);
    }

    pub fn nodeSpan(self: *const Tree, node: *const Node) Span {
        const base = node.data;
        return .{
            .start = self.extra_data.items[base],
            .end = self.extra_data.items[base + 1],
        };
    }

    pub fn assignment(self: *const Tree, node: *const Node) Assignment {
        const base = node.data;
        const op_val = self.extra_data.items[base + 1];
        return .{
            .name = @enumFromInt(self.extra_data.items[base]),
            .op = if (op_val == std.math.maxInt(u32)) null else @enumFromInt(op_val),
            .value = @enumFromInt(self.extra_data.items[base + 2]),
        };
    }

    pub fn multipleAssignment(self: *const Tree, node: *const Node) MultipleAssignment {
        const base = node.data;
        const op_val = self.extra_data.items[base + 2];
        return .{
            .lhs = .{ .start = self.extra_data.items[base], .end = self.extra_data.items[base + 1] },
            .op = if (op_val == std.math.maxInt(u32)) null else @enumFromInt(op_val),
            .value = @enumFromInt(self.extra_data.items[base + 3]),
        };
    }

    pub fn propertyAssignment(self: *const Tree, node: *const Node) PropertyAssignment {
        const base = node.data;
        const op_val = self.extra_data.items[base + 2];
        return .{
            .target = @enumFromInt(self.extra_data.items[base]),
            .property = @enumFromInt(self.extra_data.items[base + 1]),
            .op = if (op_val == std.math.maxInt(u32)) null else @enumFromInt(op_val),
            .value = @enumFromInt(self.extra_data.items[base + 3]),
        };
    }

    pub fn indexAssignment(self: *const Tree, node: *const Node) IndexAssignment {
        const base = node.data;
        const op_val = self.extra_data.items[base + 2];
        return .{
            .target = @enumFromInt(self.extra_data.items[base]),
            .index = @enumFromInt(self.extra_data.items[base + 1]),
            .op = if (op_val == std.math.maxInt(u32)) null else @enumFromInt(op_val),
            .value = @enumFromInt(self.extra_data.items[base + 3]),
        };
    }

    pub fn binaryExpr(self: *const Tree, node: *const Node) BinaryExpr {
        const base = node.data;
        return .{
            .op = @enumFromInt(self.extra_data.items[base]),
            .left = @enumFromInt(self.extra_data.items[base + 1]),
            .right = @enumFromInt(self.extra_data.items[base + 2]),
        };
    }

    pub fn unaryExpr(self: *const Tree, node: *const Node) UnaryExpr {
        const base = node.data;
        return .{
            .op = @enumFromInt(self.extra_data.items[base]),
            .operand = @enumFromInt(self.extra_data.items[base + 1]),
        };
    }

    pub fn ternaryExpr(self: *const Tree, node: *const Node) TernaryExpr {
        const base = node.data;
        return .{
            .condition = @enumFromInt(self.extra_data.items[base]),
            .then_branch = @enumFromInt(self.extra_data.items[base + 1]),
            .else_branch = @enumFromInt(self.extra_data.items[base + 2]),
        };
    }

    pub fn methodCall(self: *const Tree, node: *const Node) MethodCall {
        const base = node.data;
        return .{
            .receiver = @enumFromInt(self.extra_data.items[base]),
            .method_name = @enumFromInt(self.extra_data.items[base + 1]),
            .args = .{ .start = self.extra_data.items[base + 2], .end = self.extra_data.items[base + 3] },
            .block = @enumFromInt(self.extra_data.items[base + 4]),
            .is_safe = self.extra_data.items[base + 5] != 0,
            .end_token = self.extra_data.items[base + 6],
        };
    }

    pub fn superCall(self: *const Tree, node: *const Node) SuperCall {
        const base = node.data;
        return .{
            .args = .{ .start = self.extra_data.items[base], .end = self.extra_data.items[base + 1] },
            .block = @enumFromInt(self.extra_data.items[base + 2]),
        };
    }

    pub fn lambdaExpr(self: *const Tree, node: *const Node) LambdaExpr {
        const base = node.data;
        return .{
            .params = .{ .start = self.extra_data.items[base], .end = self.extra_data.items[base + 1] },
            .body = @enumFromInt(self.extra_data.items[base + 2]),
        };
    }

    pub fn importStmt(self: *const Tree, node: *const Node) ImportStmt {
        const base = node.data;
        return .{
            .symbols = .{ .start = self.extra_data.items[base], .end = self.extra_data.items[base + 1] },
            .path = @enumFromInt(self.extra_data.items[base + 2]),
            .attributes = @enumFromInt(self.extra_data.items[base + 3]),
        };
    }

    pub fn exportStmt(self: *const Tree, node: *const Node) ExportStmt {
        const base = node.data;
        return .{
            .symbols = .{ .start = self.extra_data.items[base], .end = self.extra_data.items[base + 1] },
            .path = @enumFromInt(self.extra_data.items[base + 2]),
            .attributes = @enumFromInt(self.extra_data.items[base + 3]),
        };
    }

    pub fn ifStmt(self: *const Tree, node: *const Node) IfStmt {
        const base = node.data;
        return .{
            .condition = @enumFromInt(self.extra_data.items[base]),
            .then_branch = @enumFromInt(self.extra_data.items[base + 1]),
            .else_branch = @enumFromInt(self.extra_data.items[base + 2]),
            .is_unless = self.extra_data.items[base + 3] != 0,
            .end_token = self.extra_data.items[base + 4],
        };
    }

    pub fn whileStmt(self: *const Tree, node: *const Node) WhileStmt {
        const base = node.data;
        return .{
            .condition = @enumFromInt(self.extra_data.items[base]),
            .body = @enumFromInt(self.extra_data.items[base + 1]),
            .is_until = self.extra_data.items[base + 2] != 0,
        };
    }

    pub fn forStmt(self: *const Tree, node: *const Node) ForStmt {
        const base = node.data;
        return .{
            .bindings = .{ .start = self.extra_data.items[base], .end = self.extra_data.items[base + 1] },
            .body = @enumFromInt(self.extra_data.items[base + 2]),
            .is_intersection = self.extra_data.items[base + 3] != 0,
        };
    }

    pub fn caseStmt(self: *const Tree, node: *const Node) CaseStmt {
        const base = node.data;
        return .{
            .condition = @enumFromInt(self.extra_data.items[base]),
            .when_branches = .{ .start = self.extra_data.items[base + 1], .end = self.extra_data.items[base + 2] },
            .else_branch = @enumFromInt(self.extra_data.items[base + 3]),
        };
    }

    pub fn defStmt(self: *const Tree, node: *const Node) DefStmt {
        const base = node.data;
        return .{
            .name = @enumFromInt(self.extra_data.items[base]),
            .params = .{ .start = self.extra_data.items[base + 1], .end = self.extra_data.items[base + 2] },
            .body = @enumFromInt(self.extra_data.items[base + 3]),
            .is_class_method = self.extra_data.items[base + 4] != 0,
            .end_token = self.extra_data.items[base + 5],
        };
    }

    pub fn classStmt(self: *const Tree, node: *const Node) ClassStmt {
        const base = node.data;
        return .{
            .name = @enumFromInt(self.extra_data.items[base]),
            .super_class = @enumFromInt(self.extra_data.items[base + 1]),
            .body = @enumFromInt(self.extra_data.items[base + 2]),
            .end_token = self.extra_data.items[base + 3],
        };
    }

    pub fn moduleStmt(self: *const Tree, node: *const Node) ModuleStmt {
        const base = node.data;
        return .{
            .name = @enumFromInt(self.extra_data.items[base]),
            .params = .{ .start = self.extra_data.items[base + 1], .end = self.extra_data.items[base + 2] },
            .body = @enumFromInt(self.extra_data.items[base + 3]),
            .end_token = self.extra_data.items[base + 4],
        };
    }

    pub fn beginStmt(self: *const Tree, node: *const Node) BeginStmt {
        const base = node.data;
        return .{
            .body = @enumFromInt(self.extra_data.items[base]),
            .rescues = .{ .start = self.extra_data.items[base + 1], .end = self.extra_data.items[base + 2] },
            .ensure_body = @enumFromInt(self.extra_data.items[base + 3]),
        };
    }

    pub fn paramDoc(self: *const Tree, node: *const Node) ParamDoc {
        const base = node.data;
        return .{
            .tag_name = @enumFromInt(self.extra_data.items[base]),
            .target_name = @enumFromInt(self.extra_data.items[base + 1]),
            .type_name = @enumFromInt(self.extra_data.items[base + 2]),
            .description = @enumFromInt(self.extra_data.items[base + 3]),
            .options_expr = @enumFromInt(self.extra_data.items[base + 4]),
        };
    }

    pub fn block(self: *const Tree, node: *const Node) Block {
        const base = node.data;
        return .{
            .params = .{ .start = self.extra_data.items[base], .end = self.extra_data.items[base + 1] },
            .stmts = .{ .start = self.extra_data.items[base + 2], .end = self.extra_data.items[base + 3] },
            .end_token = self.extra_data.items[base + 4],
        };
    }

    pub fn arrayLiteral(self: *const Tree, node: *const Node) ArrayLiteral {
        const base = node.data;
        return .{
            .span = .{ .start = self.extra_data.items[base], .end = self.extra_data.items[base + 1] },
            .end_token = self.extra_data.items[base + 2],
        };
    }

    pub fn range(self: *const Tree, node: *const Node) Range {
        const base = node.data;
        return .{
            .start = @enumFromInt(self.extra_data.items[base]),
            .end = @enumFromInt(self.extra_data.items[base + 1]),
            .step = @enumFromInt(self.extra_data.items[base + 2]),
            .is_exclusive = self.extra_data.items[base + 3] != 0,
        };
    }

    pub fn indexAccess(self: *const Tree, node: *const Node) IndexAccess {
        const base = node.data;
        return .{
            .target = @enumFromInt(self.extra_data.items[base]),
            .index = @enumFromInt(self.extra_data.items[base + 1]),
        };
    }

    pub fn rescueModifier(self: *const Tree, node: *const Node) RescueModifier {
        const base = node.data;
        return .{
            .expr = @enumFromInt(self.extra_data.items[base]),
            .rescue_expr = @enumFromInt(self.extra_data.items[base + 1]),
        };
    }
};

// --- AST Builder ---
pub const Builder = struct {
    allocator: std.mem.Allocator,
    tree: Tree,
    number_map: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    intern_map: std.HashMapUnmanaged(StringId, void, InternContext, std.hash_map.default_max_load_percentage) = .empty,

    // The Map Context (Used when the hash map resizes and moves StringIds around)
    const InternContext = struct {
        tree: *const Tree,

        pub fn hash(self: InternContext, key: StringId) u64 {
            return std.hash_map.hashString(self.tree.getString(key));
        }

        pub fn eql(self: InternContext, a: StringId, b: StringId) bool {
            return std.mem.eql(u8, self.tree.getString(a), self.tree.getString(b));
        }
    };

    // The Adapter Context (Used when looking up a raw []const u8 slice against stored StringIds)
    const StringAdapter = struct {
        tree: *const Tree,

        pub fn hash(self: StringAdapter, adapted_key: []const u8) u64 {
            _ = self;
            return std.hash_map.hashString(adapted_key);
        }

        pub fn eql(self: StringAdapter, adapted_key: []const u8, key: StringId) bool {
            return std.mem.eql(u8, adapted_key, self.tree.getString(key));
        }
    };

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .tree = Tree.init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.number_map.deinit(self.allocator);
        self.intern_map.deinit(self.allocator);
        self.tree.deinit(self.allocator);
    }

    /// Pre-allocates memory for the AST to prevent dynamic resizing during parsing.
    pub fn ensureTotalCapacity(self: *Builder, allocator: std.mem.Allocator, node_capacity: usize) !void {
        try self.tree.nodes.ensureTotalCapacity(allocator, node_capacity);
        try self.tree.extra_data.ensureTotalCapacity(allocator, node_capacity * 2);
        try self.tree.string_bytes.ensureTotalCapacity(allocator, node_capacity * 8);
        try self.tree.string_spans.ensureTotalCapacity(allocator, node_capacity);
        // Pre-allocate the number map. (We assume ~1/4 of nodes are numbers)
        try self.number_map.ensureTotalCapacity(allocator, @intCast(node_capacity / 4));
    }

    /// Core allocation method for the 8-byte Tiny Node
    pub fn createNode(self: *Builder, tag: Tag, main_token: u24, data: u32) !NodeIndex {
        const index = @as(u32, @intCast(self.tree.nodes.items.len));
        try self.tree.nodes.append(self.allocator, .{
            .tag = tag,
            .main_token = main_token,
            .data = data,
        });
        return @as(NodeIndex, @enumFromInt(index));
    }

    pub fn intern(self: *Builder, str: []const u8) !StringId {
        if (str.len == 0) return .none;

        const map_ctx = InternContext{ .tree = &self.tree };
        const adapter = StringAdapter{ .tree = &self.tree };

        const gop = try self.intern_map.getOrPutContextAdapted(self.allocator, str, adapter, map_ctx);
        if (gop.found_existing) {
            return gop.key_ptr.*;
        }

        const offset: u32 = @intCast(self.tree.string_bytes.items.len);
        try self.tree.string_bytes.appendSlice(self.allocator, str);
        const id = @as(StringId, @enumFromInt(self.tree.string_spans.items.len));
        try self.tree.string_spans.append(self.allocator, .{
            .offset = offset,
            .length = @intCast(str.len),
        });
        gop.key_ptr.* = id;
        return id;
    }

    /// Serializes payloads sequentially into the global DoD extra_data array
    fn addExtra(self: *Builder, items: anytype) !u32 {
        const start = @as(u32, @intCast(self.tree.extra_data.items.len));
        inline for (items) |item| {
            const T = @TypeOf(item);
            if (T == u32) {
                try self.tree.extra_data.append(self.allocator, item);
            } else if (T == bool) {
                try self.tree.extra_data.append(self.allocator, if (item) 1 else 0);
            } else if (T == Span) {
                try self.tree.extra_data.append(self.allocator, item.start);
                try self.tree.extra_data.append(self.allocator, item.end);
            } else if (@typeInfo(T) == .optional) {
                if (item) |v| {
                    try self.tree.extra_data.append(self.allocator, @intFromEnum(v));
                } else {
                    try self.tree.extra_data.append(self.allocator, std.math.maxInt(u32));
                }
            } else if (@typeInfo(T) == .@"enum") {
                try self.tree.extra_data.append(self.allocator, @intFromEnum(item));
            } else {
                @compileError("Unsupported type for addExtra: " ++ @typeName(T));
            }
        }
        return start;
    }

    // --- Span Generators (Side-Table Arrays) ---

    pub fn addNodes(self: *Builder, items: []const NodeIndex) !Span {
        const start = @as(u32, @intCast(self.tree.extra_node_indices.items.len));
        try self.tree.extra_node_indices.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addStringLists(self: *Builder, items: []const StringId) !Span {
        const start = @as(u32, @intCast(self.tree.extra_string_indices.items.len));
        try self.tree.extra_string_indices.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addNamedArgs(self: *Builder, items: []const NamedArg) !Span {
        const start = @as(u32, @intCast(self.tree.named_args.items.len));
        try self.tree.named_args.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addParams(self: *Builder, items: []const Param) !Span {
        const start = @as(u32, @intCast(self.tree.params.items.len));
        try self.tree.params.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addLhsExprs(self: *Builder, items: []const LhsExpr) !Span {
        const start = @as(u32, @intCast(self.tree.lhs_exprs.items.len));
        try self.tree.lhs_exprs.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addWhenBranches(self: *Builder, items: []const WhenBranch) !Span {
        const start = @as(u32, @intCast(self.tree.when_branches.items.len));
        try self.tree.when_branches.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addRescueClauses(self: *Builder, items: []const RescueClause) !Span {
        const start = @as(u32, @intCast(self.tree.rescue_clauses.items.len));
        try self.tree.rescue_clauses.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addForBindings(self: *Builder, items: []const ForBinding) !Span {
        const start = @as(u32, @intCast(self.tree.for_bindings.items.len));
        try self.tree.for_bindings.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addHashEntries(self: *Builder, items: []const HashEntry) !Span {
        const start = @as(u32, @intCast(self.tree.hash_entries.items.len));
        try self.tree.hash_entries.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    // --- AST Node Constructors ---

    pub fn invalidNode(self: *Builder, main_token: u24) !NodeIndex {
        return self.createNode(.invalid, main_token, 0);
    }

    pub fn number(self: *Builder, lexeme_str: []const u8, main_token: u24) !NodeIndex {
        var clean_buf: [128]u8 = undefined;
        var clean_len: usize = 0;
        for (lexeme_str) |c| {
            if (c != '_') {
                if (clean_len < clean_buf.len) {
                    clean_buf[clean_len] = c;
                    clean_len += 1;
                }
            }
        }
        const cleaned = clean_buf[0..clean_len];

        var val: f64 = 0.0;
        if (std.mem.startsWith(u8, cleaned, "0x") or std.mem.startsWith(u8, cleaned, "0X")) {
            val = @as(f64, @floatFromInt(std.fmt.parseInt(i64, cleaned[2..], 16) catch 0));
        } else if (std.mem.startsWith(u8, cleaned, "0b") or std.mem.startsWith(u8, cleaned, "0B")) {
            val = @as(f64, @floatFromInt(std.fmt.parseInt(i64, cleaned[2..], 2) catch 0));
        } else if (std.mem.startsWith(u8, cleaned, "0o") or std.mem.startsWith(u8, cleaned, "0O")) {
            val = @as(f64, @floatFromInt(std.fmt.parseInt(i64, cleaned[2..], 8) catch 0));
        } else {
            val = std.fmt.parseFloat(f64, cleaned) catch 0.0;
        }

        // --- Float Deduplication Logic ---
        const bits: u64 = @bitCast(val);
        const gop = try self.number_map.getOrPut(self.allocator, bits);
        if (!gop.found_existing) {
            // It's a new unique number, append it to the tree
            gop.value_ptr.* = @as(u32, @intCast(self.tree.numbers.items.len));
            try self.tree.numbers.append(self.allocator, val);
        }

        // Return the node pointing to the shared index
        return self.createNode(.number, main_token, gop.value_ptr.*);
    }

    pub fn stringNode(self: *Builder, lexeme_str: []const u8, main_token: u24) !NodeIndex {
        const str_id = try self.intern(lexeme_str);
        return self.createNode(.string, main_token, @intFromEnum(str_id));
    }

    pub fn symbolNode(self: *Builder, lexeme_str: []const u8, main_token: u24) !NodeIndex {
        const str_id = try self.intern(lexeme_str);
        return self.createNode(.symbol, main_token, @intFromEnum(str_id));
    }

    pub fn identifierNode(self: *Builder, lexeme_str: []const u8, main_token: u24) !NodeIndex {
        const str_id = try self.intern(lexeme_str);
        return self.createNode(.identifier, main_token, @intFromEnum(str_id));
    }

    pub fn booleanNode(self: *Builder, val: bool, main_token: u24) !NodeIndex {
        return self.createNode(.boolean, main_token, if (val) 1 else 0);
    }

    pub fn nilNode(self: *Builder, main_token: u24) !NodeIndex {
        return self.createNode(.nil, main_token, 0);
    }

    pub fn undefNode(self: *Builder, main_token: u24) !NodeIndex {
        return self.createNode(.undef, main_token, 0);
    }

    pub fn selfExprNode(self: *Builder, main_token: u24) !NodeIndex {
        return self.createNode(.self_expr, main_token, 0);
    }

    pub fn assignment(self: *Builder, name: StringId, op: ?BinaryOp, val: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ name, op, val });
        return self.createNode(.assignment, main_token, data_idx);
    }

    pub fn multipleAssignment(self: *Builder, lhs: Span, op: ?BinaryOp, val: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ lhs, op, val });
        return self.createNode(.multiple_assignment, main_token, data_idx);
    }

    pub fn propertyAssignment(self: *Builder, target: NodeIndex, prop: StringId, op: ?BinaryOp, val: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ target, prop, op, val });
        return self.createNode(.property_assignment, main_token, data_idx);
    }

    pub fn indexAssignment(self: *Builder, target: NodeIndex, index: NodeIndex, op: ?BinaryOp, val: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ target, index, op, val });
        return self.createNode(.index_assignment, main_token, data_idx);
    }

    pub fn binary(self: *Builder, op: BinaryOp, left: NodeIndex, right: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ op, left, right });
        return self.createNode(.binary_op, main_token, data_idx);
    }

    pub fn unary(self: *Builder, op: UnaryOp, operand: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ op, operand });
        return self.createNode(.unary_op, main_token, data_idx);
    }

    pub fn ternary(self: *Builder, cond: NodeIndex, then_b: NodeIndex, else_b: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ cond, then_b, else_b });
        return self.createNode(.ternary_op, main_token, data_idx);
    }

    pub fn methodCall(self: *Builder, receiver: NodeIndex, name: StringId, args: Span, block_idx: NodeIndex, is_safe: bool, end_token: u32, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ receiver, name, args, block_idx, is_safe, end_token });
        return self.createNode(.method_call, main_token, data_idx);
    }

    pub fn superCall(self: *Builder, args: Span, block_idx: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ args, block_idx });
        return self.createNode(.super_call, main_token, data_idx);
    }

    pub fn lambdaExpr(self: *Builder, params: Span, body: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ params, body });
        return self.createNode(.lambda_expr, main_token, data_idx);
    }

    pub fn importStmt(self: *Builder, symbols: Span, path: StringId, attrs: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ symbols, path, attrs });
        return self.createNode(.import_stmt, main_token, data_idx);
    }

    pub fn exportStmt(self: *Builder, symbols: Span, path: StringId, attrs: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ symbols, path, attrs });
        return self.createNode(.export_stmt, main_token, data_idx);
    }

    pub fn ifStmt(self: *Builder, cond: NodeIndex, then_b: NodeIndex, else_b: NodeIndex, is_unless: bool, end_token: u32, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ cond, then_b, else_b, is_unless, end_token });
        return self.createNode(.if_stmt, main_token, data_idx);
    }

    pub fn whileStmt(self: *Builder, cond: NodeIndex, body: NodeIndex, is_until: bool, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ cond, body, is_until });
        return self.createNode(.while_stmt, main_token, data_idx);
    }

    pub fn forStmt(self: *Builder, bindings: Span, body: NodeIndex, is_intersection: bool, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ bindings, body, is_intersection });
        return self.createNode(.for_stmt, main_token, data_idx);
    }

    pub fn caseStmt(self: *Builder, cond: NodeIndex, branches: Span, else_b: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ cond, branches, else_b });
        return self.createNode(.case_stmt, main_token, data_idx);
    }

    pub fn defStmt(self: *Builder, name: StringId, params: Span, body: NodeIndex, is_class_method: bool, end_token: u32, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ name, params, body, is_class_method, end_token });
        return self.createNode(.def_stmt, main_token, data_idx);
    }

    pub fn classStmt(self: *Builder, name: NodeIndex, super_class: NodeIndex, body: NodeIndex, end_token: u32, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ name, super_class, body, end_token });
        return self.createNode(.class_stmt, main_token, data_idx);
    }

    pub fn moduleStmt(self: *Builder, name: StringId, params: Span, body: NodeIndex, end_token: u32, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ name, params, body, end_token });
        return self.createNode(.module_stmt, main_token, data_idx);
    }

    pub fn beginStmt(self: *Builder, body: NodeIndex, rescues: Span, ensure_body: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ body, rescues, ensure_body });
        return self.createNode(.begin_stmt, main_token, data_idx);
    }

    pub fn block(self: *Builder, params: []const NodeIndex, stmts: []const NodeIndex, end_token: u32, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ try self.addNodes(params), try self.addNodes(stmts), end_token });
        return self.createNode(.block, main_token, data_idx);
    }

    pub fn arrayLiteral(self: *Builder, span: Span, end_token: u32, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ span, end_token });
        return self.createNode(.array_literal, main_token, data_idx);
    }

    pub fn range(self: *Builder, start: NodeIndex, end: NodeIndex, step: NodeIndex, is_excl: bool, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ start, end, step, is_excl });
        return self.createNode(.range, main_token, data_idx);
    }

    pub fn indexAccess(self: *Builder, target: NodeIndex, idx: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ target, idx });
        return self.createNode(.index_access, main_token, data_idx);
    }

    pub fn rescueModifier(self: *Builder, expr: NodeIndex, rescue_expr: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{ expr, rescue_expr });
        return self.createNode(.rescue_modifier, main_token, data_idx);
    }

    pub fn hashLiteral(self: *Builder, entries: Span, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{entries});
        return self.createNode(.hash_literal, main_token, data_idx);
    }

    pub fn namespaceAccess(self: *Builder, path: Span, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{path});
        return self.createNode(.namespace_access, main_token, data_idx);
    }

    pub fn interpolatedString(self: *Builder, parts: Span, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{parts});
        return self.createNode(.interpolated_string, main_token, data_idx);
    }

    pub fn yieldStmt(self: *Builder, args: Span, main_token: u24) !NodeIndex {
        const data_idx = try self.addExtra(.{args});
        return self.createNode(.yield_stmt, main_token, data_idx);
    }

    pub fn returnStmt(self: *Builder, val: NodeIndex, main_token: u24) !NodeIndex {
        return self.createNode(.return_stmt, main_token, @intFromEnum(val));
    }

    pub fn breakStmt(self: *Builder, val: NodeIndex, main_token: u24) !NodeIndex {
        return self.createNode(.break_stmt, main_token, @intFromEnum(val));
    }

    pub fn nextStmt(self: *Builder, val: NodeIndex, main_token: u24) !NodeIndex {
        return self.createNode(.next_stmt, main_token, @intFromEnum(val));
    }

    pub fn splatExpr(self: *Builder, expr: NodeIndex, main_token: u24) !NodeIndex {
        return self.createNode(.splat_expr, main_token, @intFromEnum(expr));
    }

    pub fn doubleSplatExpr(self: *Builder, expr: NodeIndex, main_token: u24) !NodeIndex {
        return self.createNode(.double_splat_expr, main_token, @intFromEnum(expr));
    }

    pub fn eachExpr(self: *Builder, expr: NodeIndex, main_token: u24) !NodeIndex {
        return self.createNode(.each_expr, main_token, @intFromEnum(expr));
    }

    pub fn addParamDoc(self: *Builder, doc: ParamDoc) !u32 {
        return try self.addExtra(.{ doc.tag_name, doc.target_name, doc.type_name, doc.description, doc.options_expr });
    }
};
