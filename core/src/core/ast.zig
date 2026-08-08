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

// --- Thin Node (16 bytes) ---
pub const Node = struct {
    tag: Tag, // 1 byte
    loc: Location, // 8 bytes (assuming line, col, offset, length, file_id)
    main_token: u32, // 4 bytes
    data: u32, // 4 bytes (Index into the respective payload array or direct value)
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
            .tree = .{},
        };
    }

    pub fn deinit(self: *Builder) void {
        self.tree.deinit(self.allocator);
    }

    pub fn intern(self: *Builder, str: []const u8) !StringId {
        if (self.tree.string_indices.get(str)) |id| return id;

        const duped = try self.allocator.dupe(u8, str);
        const index = self.tree.strings.items.len;
        try self.tree.strings.append(self.allocator, duped);

        const id = @as(StringId, @enumFromInt(index));
        try self.tree.string_indices.put(self.allocator, duped, id);
        return id;
    }

    pub fn createNode(self: *Builder, tag: Tag, loc: Location, data: u32) !NodeIndex {
        const index = self.tree.nodes.items.len;
        try self.tree.nodes.append(self.allocator, .{
            .tag = tag,
            .loc = loc,
            .main_token = 0,
            .data = data,
        });
        return @as(NodeIndex, @enumFromInt(index));
    }

    // --- Primitive / Direct-Value Nodes ---

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

        const data_idx: u32 = @intCast(self.tree.numbers.items.len);
        try self.tree.numbers.append(self.allocator, val);
        return self.createNode(.number, final_loc, data_idx);
    }

    pub fn stringNode(self: *Builder, lexeme: []const u8, loc: Location) !NodeIndex {
        var final_loc = loc;
        if (final_loc.length == 0) final_loc.length = @as(u32, @intCast(lexeme.len));
        const str_id = try self.intern(lexeme);
        return self.createNode(.string, final_loc, @intFromEnum(str_id));
    }

    pub fn symbolNode(self: *Builder, lexeme: []const u8, loc: Location) !NodeIndex {
        var final_loc = loc;
        if (final_loc.length == 0) final_loc.length = @as(u32, @intCast(lexeme.len));
        const str_id = try self.intern(lexeme);
        return self.createNode(.symbol, final_loc, @intFromEnum(str_id));
    }

    pub fn identifierNode(self: *Builder, lexeme: []const u8, loc: Location) !NodeIndex {
        var final_loc = loc;
        if (final_loc.length == 0) final_loc.length = @as(u32, @intCast(lexeme.len));
        const str_id = try self.intern(lexeme);
        return self.createNode(.identifier, final_loc, @intFromEnum(str_id));
    }

    pub fn booleanNode(self: *Builder, val: bool, loc: Location) !NodeIndex {
        return self.createNode(.boolean, loc, if (val) 1 else 0);
    }

    pub fn nilNode(self: *Builder, loc: Location) !NodeIndex {
        return self.createNode(.nil, loc, 0);
    }

    pub fn undefNode(self: *Builder, loc: Location) !NodeIndex {
        return self.createNode(.undef, loc, 0);
    }

    pub fn selfExprNode(self: *Builder, loc: Location) !NodeIndex {
        return self.createNode(.self_expr, loc, 0);
    }

    // --- Span-Only Data Nodes (Array Literals, Hash Literals, Interpolated Strings) ---
    // These store their generic span inside the `spans` pool, and pass the span index to `data`.

    pub fn arrayLiteral(self: *Builder, elements: Span, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.spans.items.len);
        try self.tree.spans.append(self.allocator, elements);
        return self.createNode(.array_literal, loc, data_idx);
    }

    pub fn hashLiteral(self: *Builder, entries: Span, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.spans.items.len);
        try self.tree.spans.append(self.allocator, entries);
        return self.createNode(.hash_literal, loc, data_idx);
    }

    pub fn namespaceAccess(self: *Builder, path: Span, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.spans.items.len);
        try self.tree.spans.append(self.allocator, path);
        return self.createNode(.namespace_access, loc, data_idx);
    }

    pub fn yieldStmt(self: *Builder, args: Span, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.spans.items.len);
        try self.tree.spans.append(self.allocator, args);
        return self.createNode(.yield_stmt, loc, data_idx);
    }

    pub fn interpolatedString(self: *Builder, parts: Span, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.spans.items.len);
        try self.tree.spans.append(self.allocator, parts);
        return self.createNode(.interpolated_string, loc, data_idx);
    }

    // --- Complex Nodes (Backed by Payload Struct Pools) ---

    pub fn binary(self: *Builder, op: BinaryOp, left: NodeIndex, right: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.binary_exprs.items.len);
        try self.tree.binary_exprs.append(self.allocator, .{ .op = op, .left = left, .right = right });
        return self.createNode(.binary_op, loc, data_idx);
    }

    pub fn unary(self: *Builder, op: UnaryOp, operand: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.unary_exprs.items.len);
        try self.tree.unary_exprs.append(self.allocator, .{ .op = op, .operand = operand });
        return self.createNode(.unary_op, loc, data_idx);
    }

    pub fn ternary(self: *Builder, condition: NodeIndex, then_branch: NodeIndex, else_branch: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.ternary_exprs.items.len);
        try self.tree.ternary_exprs.append(self.allocator, .{ .condition = condition, .then_branch = then_branch, .else_branch = else_branch });
        return self.createNode(.ternary_op, loc, data_idx);
    }

    pub fn assignment(self: *Builder, name: StringId, op: ?BinaryOp, value: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.assignments.items.len);
        try self.tree.assignments.append(self.allocator, .{ .name = name, .op = op, .value = value });
        return self.createNode(.assignment, loc, data_idx);
    }

    pub fn multipleAssignment(self: *Builder, lhs: Span, op: ?BinaryOp, value: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.multiple_assignments.items.len);
        try self.tree.multiple_assignments.append(self.allocator, .{ .lhs = lhs, .op = op, .value = value });
        return self.createNode(.multiple_assignment, loc, data_idx);
    }

    pub fn propertyAssignment(self: *Builder, target: NodeIndex, property: StringId, op: ?BinaryOp, value: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.property_assignments.items.len);
        try self.tree.property_assignments.append(self.allocator, .{ .target = target, .property = property, .op = op, .value = value });
        return self.createNode(.property_assignment, loc, data_idx);
    }

    pub fn indexAssignment(self: *Builder, target: NodeIndex, index: NodeIndex, op: ?BinaryOp, value: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.index_assignments.items.len);
        try self.tree.index_assignments.append(self.allocator, .{ .target = target, .index = index, .op = op, .value = value });
        return self.createNode(.index_assignment, loc, data_idx);
    }

    pub fn methodCall(self: *Builder, receiver: NodeIndex, method_name: StringId, args: Span, block_node: NodeIndex, is_safe: bool, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.method_calls.items.len);
        try self.tree.method_calls.append(self.allocator, .{
            .receiver = receiver,
            .method_name = method_name,
            .args = args,
            .block = block_node,
            .is_safe = is_safe,
        });
        return self.createNode(.method_call, loc, data_idx);
    }

    pub fn superCall(self: *Builder, args: Span, block_node: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.super_calls.items.len);
        try self.tree.super_calls.append(self.allocator, .{ .args = args, .block = block_node });
        return self.createNode(.super_call, loc, data_idx);
    }

    pub fn lambdaExpr(self: *Builder, params: Span, body: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.lambda_exprs.items.len);
        try self.tree.lambda_exprs.append(self.allocator, .{ .params = params, .body = body });
        return self.createNode(.lambda_expr, loc, data_idx);
    }

    pub fn importStmt(self: *Builder, symbols: Span, path: StringId, attributes: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.import_stmts.items.len);
        try self.tree.import_stmts.append(self.allocator, .{ .symbols = symbols, .path = path, .attributes = attributes });
        return self.createNode(.import_stmt, loc, data_idx);
    }

    pub fn exportStmt(self: *Builder, symbols: Span, path: StringId, attributes: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.export_stmts.items.len);
        try self.tree.export_stmts.append(self.allocator, .{ .symbols = symbols, .path = path, .attributes = attributes });
        return self.createNode(.export_stmt, loc, data_idx);
    }

    pub fn ifStmt(self: *Builder, condition: NodeIndex, then_branch: NodeIndex, else_branch: NodeIndex, is_unless: bool, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.if_stmts.items.len);
        try self.tree.if_stmts.append(self.allocator, .{ .condition = condition, .then_branch = then_branch, .else_branch = else_branch, .is_unless = is_unless });
        return self.createNode(.if_stmt, loc, data_idx);
    }

    pub fn whileStmt(self: *Builder, condition: NodeIndex, body: NodeIndex, is_until: bool, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.while_stmts.items.len);
        try self.tree.while_stmts.append(self.allocator, .{ .condition = condition, .body = body, .is_until = is_until });
        return self.createNode(.while_stmt, loc, data_idx);
    }

    pub fn forStmt(self: *Builder, bindings: Span, body: NodeIndex, is_intersection: bool, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.for_stmts.items.len);
        try self.tree.for_stmts.append(self.allocator, .{ .bindings = bindings, .body = body, .is_intersection = is_intersection });
        return self.createNode(.for_stmt, loc, data_idx);
    }

    pub fn caseStmt(self: *Builder, condition: NodeIndex, when_branches: Span, else_branch: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.case_stmts.items.len);
        try self.tree.case_stmts.append(self.allocator, .{ .condition = condition, .when_branches = when_branches, .else_branch = else_branch });
        return self.createNode(.case_stmt, loc, data_idx);
    }

    pub fn defStmt(self: *Builder, name: StringId, params: Span, body: NodeIndex, is_class_method: bool, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.def_stmts.items.len);
        try self.tree.def_stmts.append(self.allocator, .{ .name = name, .params = params, .body = body, .is_class_method = is_class_method });
        return self.createNode(.def_stmt, loc, data_idx);
    }

    pub fn classStmt(self: *Builder, name: NodeIndex, super_class: NodeIndex, body: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.class_stmts.items.len);
        try self.tree.class_stmts.append(self.allocator, .{ .name = name, .super_class = super_class, .body = body });
        return self.createNode(.class_stmt, loc, data_idx);
    }

    pub fn moduleStmt(self: *Builder, name: StringId, params: Span, body: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.module_stmts.items.len);
        try self.tree.module_stmts.append(self.allocator, .{ .name = name, .params = params, .body = body });
        return self.createNode(.module_stmt, loc, data_idx);
    }

    pub fn beginStmt(self: *Builder, body: NodeIndex, rescues: Span, ensure_body: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.begin_stmts.items.len);
        try self.tree.begin_stmts.append(self.allocator, .{ .body = body, .rescues = rescues, .ensure_body = ensure_body });
        return self.createNode(.begin_stmt, loc, data_idx);
    }

    pub fn block(self: *Builder, params: []const NodeIndex, stmts: []const NodeIndex, loc: Location) !NodeIndex {
        const params_span = try self.addNodes(params);
        const stmts_span = try self.addNodes(stmts);
        const data_idx: u32 = @intCast(self.tree.blocks.items.len);
        try self.tree.blocks.append(self.allocator, .{ .params = params_span, .stmts = stmts_span });
        return self.createNode(.block, loc, data_idx);
    }

    pub fn range(self: *Builder, start: NodeIndex, end: NodeIndex, step: NodeIndex, is_exclusive: bool, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.ranges.items.len);
        try self.tree.ranges.append(self.allocator, .{ .start = start, .end = end, .step = step, .is_exclusive = is_exclusive });
        return self.createNode(.range, loc, data_idx);
    }

    pub fn indexAccess(self: *Builder, target: NodeIndex, index: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.index_accesses.items.len);
        try self.tree.index_accesses.append(self.allocator, .{ .target = target, .index = index });
        return self.createNode(.index_access, loc, data_idx);
    }

    pub fn rescueModifier(self: *Builder, expr: NodeIndex, rescue_expr: NodeIndex, loc: Location) !NodeIndex {
        const data_idx: u32 = @intCast(self.tree.rescue_modifiers.items.len);
        try self.tree.rescue_modifiers.append(self.allocator, .{ .expr = expr, .rescue_expr = rescue_expr });
        return self.createNode(.rescue_modifier, loc, data_idx);
    }

    // --- Embedded Direct-Value Nodes (Store NodeIndex directly in `data`) ---

    pub fn returnStmt(self: *Builder, value: NodeIndex, loc: Location) !NodeIndex {
        return self.createNode(.return_stmt, loc, @intFromEnum(value));
    }

    pub fn breakStmt(self: *Builder, value: NodeIndex, loc: Location) !NodeIndex {
        return self.createNode(.break_stmt, loc, @intFromEnum(value));
    }

    pub fn nextStmt(self: *Builder, value: NodeIndex, loc: Location) !NodeIndex {
        return self.createNode(.next_stmt, loc, @intFromEnum(value));
    }

    pub fn splatExpr(self: *Builder, expr: NodeIndex, loc: Location) !NodeIndex {
        return self.createNode(.splat_expr, loc, @intFromEnum(expr));
    }

    pub fn doubleSplatExpr(self: *Builder, expr: NodeIndex, loc: Location) !NodeIndex {
        return self.createNode(.double_splat_expr, loc, @intFromEnum(expr));
    }

    pub fn eachExpr(self: *Builder, expr: NodeIndex, loc: Location) !NodeIndex {
        return self.createNode(.each_expr, loc, @intFromEnum(expr));
    }

    // --- Helper Appenders ---

    pub fn addNodes(self: *Builder, nodes: []const NodeIndex) !Span {
        const start: u32 = @intCast(self.tree.extra_node_indices.items.len);
        try self.tree.extra_node_indices.appendSlice(self.allocator, nodes);
        return Span{ .start = start, .end = start + @as(u32, @intCast(nodes.len)) };
    }

    pub fn addStringLists(self: *Builder, strings: []const StringId) !Span {
        const start: u32 = @intCast(self.tree.extra_string_indices.items.len);
        try self.tree.extra_string_indices.appendSlice(self.allocator, strings);
        return Span{ .start = start, .end = start + @as(u32, @intCast(strings.len)) };
    }

    pub fn addNamedArgs(self: *Builder, args: []const NamedArg) !Span {
        const start: u32 = @intCast(self.tree.named_args.items.len);
        try self.tree.named_args.appendSlice(self.allocator, args);
        return Span{ .start = start, .end = start + @as(u32, @intCast(args.len)) };
    }

    pub fn addParams(self: *Builder, params: []const Param) !Span {
        const start: u32 = @intCast(self.tree.params.items.len);
        try self.tree.params.appendSlice(self.allocator, params);
        return Span{ .start = start, .end = start + @as(u32, @intCast(params.len)) };
    }

    pub fn addHashEntries(self: *Builder, entries: []const HashEntry) !Span {
        const start: u32 = @intCast(self.tree.hash_entries.items.len);
        try self.tree.hash_entries.appendSlice(self.allocator, entries);
        return Span{ .start = start, .end = start + @as(u32, @intCast(entries.len)) };
    }

    pub fn addForBindings(self: *Builder, bindings: []const ForBinding) !Span {
        const start: u32 = @intCast(self.tree.for_bindings.items.len);
        try self.tree.for_bindings.appendSlice(self.allocator, bindings);
        return Span{ .start = start, .end = start + @as(u32, @intCast(bindings.len)) };
    }

    pub fn addWhenBranches(self: *Builder, branches: []const WhenBranch) !Span {
        const start: u32 = @intCast(self.tree.when_branches.items.len);
        try self.tree.when_branches.appendSlice(self.allocator, branches);
        return Span{ .start = start, .end = start + @as(u32, @intCast(branches.len)) };
    }

    pub fn addLhsExprs(self: *Builder, exprs: []const LhsExpr) !Span {
        const start: u32 = @intCast(self.tree.lhs_exprs.items.len);
        try self.tree.lhs_exprs.appendSlice(self.allocator, exprs);
        return Span{ .start = start, .end = start + @as(u32, @intCast(exprs.len)) };
    }

    pub fn addRescueClauses(self: *Builder, clauses: []const RescueClause) !Span {
        const start: u32 = @intCast(self.tree.rescue_clauses.items.len);
        try self.tree.rescue_clauses.appendSlice(self.allocator, clauses);
        return Span{ .start = start, .end = start + @as(u32, @intCast(clauses.len)) };
    }

    pub fn addParamDoc(self: *Builder, doc: ParamDoc) !u32 {
        const idx = self.tree.param_docs.items.len;
        try self.tree.param_docs.append(self.allocator, doc);
        return @intCast(idx);
    }
};
