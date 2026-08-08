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

// --- Node Tag ---
pub const Tag = enum(u8) {
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
};

pub const IndexAccess = struct {
    target: NodeIndex,
    index: NodeIndex,
};

pub const RescueModifier = struct {
    expr: NodeIndex,
    rescue_expr: NodeIndex,
};

/// Struct-of-Arrays (SoA) for Tokens.
/// Drastically improves cache locality during parsing and lookahead.
pub fn TokenList(comptime TagType: type) type {
    return struct {
        tags: []TagType,
        starts: []u32,
        lengths: []u32,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.tags);
            allocator.free(self.starts);
            allocator.free(self.lengths);
        }

        /// Helper to extract the exact lexeme on demand
        pub fn lexeme(self: @This(), source: []const u8, index: usize) []const u8 {
            if (index >= self.starts.len) return "";
            const start = self.starts[index];
            return source[start .. start + self.lengths[index]];
        }
    };
}

// --- Tree Structure ---
pub const Tree = struct {
    root: NodeIndex = .none,

    // Core node storage
    nodes: std.ArrayListUnmanaged(Node) = .empty,

    // String interning pool (storing slices backed by arena)
    strings: std.ArrayListUnmanaged([]const u8) = .empty,
    string_indices: std.StringHashMapUnmanaged(StringId) = .empty,

    // Generic span storage (for ArrayLiterals, HashLiterals, NamespaceAccess, etc.)
    spans: std.ArrayListUnmanaged(Span) = .empty,

    // Auxiliary lists for spans
    extra_node_indices: std.ArrayListUnmanaged(NodeIndex) = .empty,
    extra_string_indices: std.ArrayListUnmanaged(StringId) = .empty,

    // ---- Payload Pools ----
    numbers: std.ArrayListUnmanaged(f64) = .empty,
    assignments: std.ArrayListUnmanaged(Assignment) = .empty,
    multiple_assignments: std.ArrayListUnmanaged(MultipleAssignment) = .empty,
    property_assignments: std.ArrayListUnmanaged(PropertyAssignment) = .empty,
    index_assignments: std.ArrayListUnmanaged(IndexAssignment) = .empty,
    binary_exprs: std.ArrayListUnmanaged(BinaryExpr) = .empty,
    unary_exprs: std.ArrayListUnmanaged(UnaryExpr) = .empty,
    ternary_exprs: std.ArrayListUnmanaged(TernaryExpr) = .empty,
    method_calls: std.ArrayListUnmanaged(MethodCall) = .empty,
    super_calls: std.ArrayListUnmanaged(SuperCall) = .empty,
    lambda_exprs: std.ArrayListUnmanaged(LambdaExpr) = .empty,
    import_stmts: std.ArrayListUnmanaged(ImportStmt) = .empty,
    export_stmts: std.ArrayListUnmanaged(ExportStmt) = .empty,
    if_stmts: std.ArrayListUnmanaged(IfStmt) = .empty,
    while_stmts: std.ArrayListUnmanaged(WhileStmt) = .empty,
    for_stmts: std.ArrayListUnmanaged(ForStmt) = .empty,
    case_stmts: std.ArrayListUnmanaged(CaseStmt) = .empty,
    def_stmts: std.ArrayListUnmanaged(DefStmt) = .empty,
    class_stmts: std.ArrayListUnmanaged(ClassStmt) = .empty,
    module_stmts: std.ArrayListUnmanaged(ModuleStmt) = .empty,
    begin_stmts: std.ArrayListUnmanaged(BeginStmt) = .empty,
    param_docs: std.ArrayListUnmanaged(ParamDoc) = .empty,
    blocks: std.ArrayListUnmanaged(Block) = .empty,
    ranges: std.ArrayListUnmanaged(Range) = .empty,
    index_accesses: std.ArrayListUnmanaged(IndexAccess) = .empty,
    rescue_modifiers: std.ArrayListUnmanaged(RescueModifier) = .empty,

    // Auxiliary sub-struct pools (used via Spans)
    named_args: std.ArrayListUnmanaged(NamedArg) = .empty,
    params: std.ArrayListUnmanaged(Param) = .empty,
    hash_entries: std.ArrayListUnmanaged(HashEntry) = .empty,
    for_bindings: std.ArrayListUnmanaged(ForBinding) = .empty,
    when_branches: std.ArrayListUnmanaged(WhenBranch) = .empty,
    lhs_exprs: std.ArrayListUnmanaged(LhsExpr) = .empty,
    rescue_clauses: std.ArrayListUnmanaged(RescueClause) = .empty,

    // --- Accessor Helpers ---
    pub fn getNode(self: *const Tree, index: NodeIndex) ?*const Node {
        if (index == .none) return null;
        return &self.nodes.items[@intFromEnum(index)];
    }

    pub fn getString(self: *const Tree, id: StringId) []const u8 {
        if (id == .none) return "";
        return self.strings.items[@intFromEnum(id)];
    }

    pub fn getSpan(self: *const Tree, index: u32) Span {
        return self.spans.items[index];
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

    // Typed Data Extractors
    pub fn binaryExpr(self: *const Tree, node: *const Node) *const BinaryExpr {
        std.debug.assert(node.tag == .binary_op);
        return &self.binary_exprs.items[node.data];
    }

    pub fn unaryExpr(self: *const Tree, node: *const Node) *const UnaryExpr {
        std.debug.assert(node.tag == .unary_op);
        return &self.unary_exprs.items[node.data];
    }

    pub fn ifStmt(self: *const Tree, node: *const Node) *const IfStmt {
        std.debug.assert(node.tag == .if_stmt);
        return &self.if_stmts.items[node.data];
    }

    pub fn methodCall(self: *const Tree, node: *const Node) *const MethodCall {
        std.debug.assert(node.tag == .method_call);
        return &self.method_calls.items[node.data];
    }

    pub fn assignment(self: *const Tree, node: *const Node) *const Assignment {
        std.debug.assert(node.tag == .assignment);
        return &self.assignments.items[node.data];
    }

    pub fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);

        // Free the dynamically allocated interned string slices
        for (self.strings.items) |str| {
            allocator.free(str);
        }

        self.strings.deinit(allocator);
        self.string_indices.deinit(allocator);
        self.spans.deinit(allocator);
        self.extra_node_indices.deinit(allocator);
        self.extra_string_indices.deinit(allocator);

        self.numbers.deinit(allocator);
        self.assignments.deinit(allocator);
        self.multiple_assignments.deinit(allocator);
        self.property_assignments.deinit(allocator);
        self.index_assignments.deinit(allocator);
        self.binary_exprs.deinit(allocator);
        self.unary_exprs.deinit(allocator);
        self.ternary_exprs.deinit(allocator);
        self.method_calls.deinit(allocator);
        self.super_calls.deinit(allocator);
        self.lambda_exprs.deinit(allocator);
        self.import_stmts.deinit(allocator);
        self.export_stmts.deinit(allocator);
        self.if_stmts.deinit(allocator);
        self.while_stmts.deinit(allocator);
        self.for_stmts.deinit(allocator);
        self.case_stmts.deinit(allocator);
        self.def_stmts.deinit(allocator);
        self.class_stmts.deinit(allocator);
        self.module_stmts.deinit(allocator);
        self.begin_stmts.deinit(allocator);
        self.param_docs.deinit(allocator);
        self.blocks.deinit(allocator);
        self.ranges.deinit(allocator);
        self.index_accesses.deinit(allocator);
        self.rescue_modifiers.deinit(allocator);

        self.named_args.deinit(allocator);
        self.params.deinit(allocator);
        self.hash_entries.deinit(allocator);
        self.for_bindings.deinit(allocator);
        self.when_branches.deinit(allocator);
        self.lhs_exprs.deinit(allocator);
        self.rescue_clauses.deinit(allocator);
    }
};

// --- AST Builder ---
pub const Builder = struct {
    allocator: std.mem.Allocator,
    tree: Tree,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .tree = Tree.init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.tree.deinit(self.allocator);
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
        return self.tree.intern(self.allocator, str);
    }

    // --- Span Generators (Side-Table Arrays) ---

    pub fn addNodes(self: *Builder, items: []const NodeIndex) !Span {
        const start = @as(u32, @intCast(self.tree.extra_node_indices.items.len));
        try self.tree.extra_node_indices.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addStringLists(self: *Builder, items: []const StringId) !Span {
        const start = @as(u32, @intCast(self.tree.extra_string_ids.items.len));
        try self.tree.extra_string_ids.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addNamedArgs(self: *Builder, items: []const NamedArg) !Span {
        const start = @as(u32, @intCast(self.tree.extra_named_args.items.len));
        try self.tree.extra_named_args.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addParams(self: *Builder, items: []const Param) !Span {
        const start = @as(u32, @intCast(self.tree.extra_params.items.len));
        try self.tree.extra_params.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addLhsExprs(self: *Builder, items: []const LhsExpr) !Span {
        const start = @as(u32, @intCast(self.tree.extra_lhs_exprs.items.len));
        try self.tree.extra_lhs_exprs.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addWhenBranches(self: *Builder, items: []const WhenBranch) !Span {
        const start = @as(u32, @intCast(self.tree.extra_when_branches.items.len));
        try self.tree.extra_when_branches.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addRescueClauses(self: *Builder, items: []const RescueClause) !Span {
        const start = @as(u32, @intCast(self.tree.extra_rescue_clauses.items.len));
        try self.tree.extra_rescue_clauses.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addForBindings(self: *Builder, items: []const ForBinding) !Span {
        const start = @as(u32, @intCast(self.tree.extra_for_bindings.items.len));
        try self.tree.extra_for_bindings.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    pub fn addHashEntries(self: *Builder, items: []const HashEntry) !Span {
        const start = @as(u32, @intCast(self.tree.extra_hash_entries.items.len));
        try self.tree.extra_hash_entries.appendSlice(self.allocator, items);
        return Span{ .start = start, .end = start + @as(u32, @intCast(items.len)) };
    }

    // --- AST Node Constructors ---

    pub fn number(self: *Builder, lexeme_str: []const u8, main_token: u24) !NodeIndex {
        // Strip underscores for numeric parsing (e.g. 1_000_000)
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

        const data_idx = @as(u32, @intCast(self.tree.numbers.items.len));
        try self.tree.numbers.append(self.allocator, val);
        return self.createNode(.number, main_token, data_idx);
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
        const data_idx = @as(u32, @intCast(self.tree.assignments.items.len));
        try self.tree.assignments.append(self.allocator, .{ .name = name, .op = op, .value = val });
        return self.createNode(.assignment, main_token, data_idx);
    }

    pub fn multipleAssignment(self: *Builder, lhs: Span, op: ?BinaryOp, val: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.multiple_assignments.items.len));
        try self.tree.multiple_assignments.append(self.allocator, .{ .lhs = lhs, .op = op, .value = val });
        return self.createNode(.multiple_assignment, main_token, data_idx);
    }

    pub fn propertyAssignment(self: *Builder, target: NodeIndex, prop: StringId, op: ?BinaryOp, val: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.property_assignments.items.len));
        try self.tree.property_assignments.append(self.allocator, .{ .target = target, .property = prop, .op = op, .value = val });
        return self.createNode(.property_assignment, main_token, data_idx);
    }

    pub fn indexAssignment(self: *Builder, target: NodeIndex, index: NodeIndex, op: ?BinaryOp, val: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.index_assignments.items.len));
        try self.tree.index_assignments.append(self.allocator, .{ .target = target, .index = index, .op = op, .value = val });
        return self.createNode(.index_assignment, main_token, data_idx);
    }

    pub fn binary(self: *Builder, op: BinaryOp, left: NodeIndex, right: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.binary_exprs.items.len));
        try self.tree.binary_exprs.append(self.allocator, .{ .op = op, .left = left, .right = right });
        return self.createNode(.binary_op, main_token, data_idx);
    }

    pub fn unary(self: *Builder, op: UnaryOp, operand: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.unary_exprs.items.len));
        try self.tree.unary_exprs.append(self.allocator, .{ .op = op, .operand = operand });
        return self.createNode(.unary_op, main_token, data_idx);
    }

    pub fn ternary(self: *Builder, cond: NodeIndex, then_b: NodeIndex, else_b: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.ternary_exprs.items.len));
        try self.tree.ternary_exprs.append(self.allocator, .{ .condition = cond, .then_branch = then_b, .else_branch = else_b });
        return self.createNode(.ternary_op, main_token, data_idx);
    }

    pub fn methodCall(self: *Builder, receiver: NodeIndex, name: StringId, args: Span, block_idx: NodeIndex, is_safe: bool, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.method_calls.items.len));
        try self.tree.method_calls.append(self.allocator, .{
            .receiver = receiver,
            .method_name = name,
            .args = args,
            .block = block_idx,
            .is_safe = is_safe,
        });
        return self.createNode(.method_call, main_token, data_idx);
    }

    pub fn superCall(self: *Builder, args: Span, block_idx: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.super_calls.items.len));
        try self.tree.super_calls.append(self.allocator, .{ .args = args, .block = block_idx });
        return self.createNode(.super_call, main_token, data_idx);
    }

    pub fn lambdaExpr(self: *Builder, params: Span, body: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.lambda_exprs.items.len));
        try self.tree.lambda_exprs.append(self.allocator, .{ .params = params, .body = body });
        return self.createNode(.lambda_expr, main_token, data_idx);
    }

    pub fn importStmt(self: *Builder, symbols: Span, path: StringId, attrs: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.import_stmts.items.len));
        try self.tree.import_stmts.append(self.allocator, .{ .symbols = symbols, .path = path, .attributes = attrs });
        return self.createNode(.import_stmt, main_token, data_idx);
    }

    pub fn exportStmt(self: *Builder, symbols: Span, path: StringId, attrs: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.export_stmts.items.len));
        try self.tree.export_stmts.append(self.allocator, .{ .symbols = symbols, .path = path, .attributes = attrs });
        return self.createNode(.export_stmt, main_token, data_idx);
    }

    pub fn ifStmt(self: *Builder, cond: NodeIndex, then_b: NodeIndex, else_b: NodeIndex, is_unless: bool, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.if_stmts.items.len));
        try self.tree.if_stmts.append(self.allocator, .{ .condition = cond, .then_branch = then_b, .else_branch = else_b, .is_unless = is_unless });
        return self.createNode(.if_stmt, main_token, data_idx);
    }

    pub fn whileStmt(self: *Builder, cond: NodeIndex, body: NodeIndex, is_until: bool, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.while_stmts.items.len));
        try self.tree.while_stmts.append(self.allocator, .{ .condition = cond, .body = body, .is_until = is_until });
        return self.createNode(.while_stmt, main_token, data_idx);
    }

    pub fn forStmt(self: *Builder, bindings: Span, body: NodeIndex, is_intersection: bool, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.for_stmts.items.len));
        try self.tree.for_stmts.append(self.allocator, .{ .bindings = bindings, .body = body, .is_intersection = is_intersection });
        return self.createNode(.for_stmt, main_token, data_idx);
    }

    pub fn caseStmt(self: *Builder, cond: NodeIndex, branches: Span, else_b: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.case_stmts.items.len));
        try self.tree.case_stmts.append(self.allocator, .{ .condition = cond, .when_branches = branches, .else_branch = else_b });
        return self.createNode(.case_stmt, main_token, data_idx);
    }

    pub fn defStmt(self: *Builder, name: StringId, params: Span, body: NodeIndex, is_class_method: bool, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.def_stmts.items.len));
        try self.tree.def_stmts.append(self.allocator, .{ .name = name, .params = params, .body = body, .is_class_method = is_class_method });
        return self.createNode(.def_stmt, main_token, data_idx);
    }

    pub fn classStmt(self: *Builder, name: NodeIndex, super_class: NodeIndex, body: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.class_stmts.items.len));
        try self.tree.class_stmts.append(self.allocator, .{ .name = name, .super_class = super_class, .body = body });
        return self.createNode(.class_stmt, main_token, data_idx);
    }

    pub fn moduleStmt(self: *Builder, name: StringId, params: Span, body: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.module_stmts.items.len));
        try self.tree.module_stmts.append(self.allocator, .{ .name = name, .params = params, .body = body });
        return self.createNode(.module_stmt, main_token, data_idx);
    }

    pub fn beginStmt(self: *Builder, body: NodeIndex, rescues: Span, ensure_body: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.begin_stmts.items.len));
        try self.tree.begin_stmts.append(self.allocator, .{ .body = body, .rescues = rescues, .ensure_body = ensure_body });
        return self.createNode(.begin_stmt, main_token, data_idx);
    }

    pub fn block(self: *Builder, params: []const NodeIndex, stmts: []const NodeIndex, main_token: u24) !NodeIndex {
        const payload_idx = @as(u32, @intCast(self.tree.blocks.items.len));
        try self.tree.blocks.append(self.allocator, .{
            .params = try self.addNodes(params),
            .stmts = try self.addNodes(stmts),
        });
        return self.createNode(.block, main_token, payload_idx);
    }

    pub fn range(self: *Builder, start: NodeIndex, end: NodeIndex, step: NodeIndex, is_excl: bool, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.ranges.items.len));
        try self.tree.ranges.append(self.allocator, .{ .start = start, .end = end, .step = step, .is_exclusive = is_excl });
        return self.createNode(.range, main_token, data_idx);
    }

    pub fn indexAccess(self: *Builder, target: NodeIndex, idx: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.index_accesses.items.len));
        try self.tree.index_accesses.append(self.allocator, .{ .target = target, .index = idx });
        return self.createNode(.index_access, main_token, data_idx);
    }

    pub fn rescueModifier(self: *Builder, expr: NodeIndex, rescue_expr: NodeIndex, main_token: u24) !NodeIndex {
        const data_idx = @as(u32, @intCast(self.tree.rescue_modifiers.items.len));
        try self.tree.rescue_modifiers.append(self.allocator, .{ .expr = expr, .rescue_expr = rescue_expr });
        return self.createNode(.rescue_modifier, main_token, data_idx);
    }

    pub fn arrayLiteral(self: *Builder, nodes: Span, main_token: u24) !NodeIndex {
        const span_idx = @as(u32, @intCast(self.tree.spans.items.len));
        try self.tree.spans.append(self.allocator, nodes);
        return self.createNode(.array_literal, main_token, span_idx);
    }

    pub fn hashLiteral(self: *Builder, entries: Span, main_token: u24) !NodeIndex {
        const span_idx = @as(u32, @intCast(self.tree.spans.items.len));
        try self.tree.spans.append(self.allocator, entries);
        return self.createNode(.hash_literal, main_token, span_idx);
    }

    pub fn namespaceAccess(self: *Builder, path: Span, main_token: u24) !NodeIndex {
        const span_idx = @as(u32, @intCast(self.tree.spans.items.len));
        try self.tree.spans.append(self.allocator, path);
        return self.createNode(.namespace_access, main_token, span_idx);
    }

    pub fn interpolatedString(self: *Builder, parts: Span, main_token: u24) !NodeIndex {
        const span_idx = @as(u32, @intCast(self.tree.spans.items.len));
        try self.tree.spans.append(self.allocator, parts);
        return self.createNode(.interpolated_string, main_token, span_idx);
    }

    pub fn yieldStmt(self: *Builder, args: Span, main_token: u24) !NodeIndex {
        const span_idx = @as(u32, @intCast(self.tree.spans.items.len));
        try self.tree.spans.append(self.allocator, args);
        return self.createNode(.yield_stmt, main_token, span_idx);
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

    // --- Side-Table Utilities ---

    pub fn addParamDoc(self: *Builder, doc: ParamDoc) !u32 {
        const idx = @as(u32, @intCast(self.tree.param_docs.items.len));
        try self.tree.param_docs.append(self.allocator, doc);
        return idx;
    }
};
