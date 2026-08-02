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

pub const Node = struct {
    kind: Kind,
    loc: Location,

    pub const Kind = union(enum) {
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

        // Range: `start..end` or `[start : step : end]`
        range: struct {
            start: *Node,
            end: *Node,
            step: ?*Node = null,
            is_exclusive: bool = false,
        },

        // Variable lookup & Namespace Resolution
        identifier: []const u8,
        namespace_access: struct {
            path: []const []const u8,
        },

        // Assignment: `target += expr`
        assignment: struct {
            name: []const u8,
            op: ?BinaryOp, // null means pure '='
            value: *Node,
        },
        multiple_assignment: struct {
            lhs: []const LhsExpr,
            op: ?BinaryOp = null,
            value: *Node,
        },
        property_assignment: struct {
            target: *Node,
            property: []const u8,
            op: ?BinaryOp,
            value: *Node,
        },
        index_assignment: struct {
            target: *Node,
            index: *Node,
            op: ?BinaryOp,
            value: *Node,
        },

        // Unary: `-x`, `!x`
        unary_op: struct {
            op: UnaryOp,
            operand: *Node,
        },

        rescue_modifier: struct {
            expr: *Node,
            rescue_expr: *Node,
        },

        // Binary: `a + b`, `x * y`
        binary_op: struct {
            op: BinaryOp,
            left: *Node,
            right: *Node,
        },

        // Ternary: `a ? b : c`
        ternary_op: struct {
            condition: *Node,
            then_branch: *Node,
            else_branch: *Node,
        },

        // Index Access: `target[index]`
        index_access: struct {
            target: *Node,
            index: *Node,
        },
        splat_expr: *Node,
        double_splat_expr: *Node,

        // List Comprehension: `[ for (x = [0:5]) each x * 2 ]`
        comprehension: struct {
            clauses: []const *Node,
            yield_expr: *Node,
        },
        each_expr: *Node,

        // OpenSCAD let expression: `let(a=1) a*2`
        let_expr: struct {
            assignments: []const *Node,
            yield_expr: *Node,
        },

        // OpenSCAD Expression-level modifiers
        assert_expr: struct {
            args: []const NamedArg,
            yield_expr: *Node,
        },
        echo_expr: struct {
            args: []const NamedArg,
            yield_expr: *Node,
        },

        // Method / Function Call: `obj.method(x: 10) do |a| ... end` or `cube(10)`
        method_call: struct {
            receiver: ?*Node,
            method_name: []const u8,
            args: []const NamedArg,
            block: ?*Node = null,
            is_safe: bool = false,
        },
        super_call: struct {
            args: []const NamedArg = &.{},
            block: ?*Node = null,
        },

        // Anonymous Functions: `->(x, y) { ... }`
        lambda_expr: struct {
            params: []const Param,
            body: *Node,
        },

        // Geometry Modifier: `#cube(10);` or `!sphere(5);`
        modifier_call: struct {
            modifier: []const u8,
            child: *Node,
        },

        // Statement Constructs
        import_stmt: struct {
            symbols: []const []const u8,
            path: []const u8,
        },
        include_stmt: struct {
            path: []const u8,
            is_use: bool = false,
        },
        if_stmt: struct {
            condition: *Node,
            then_branch: *Node,
            else_branch: ?*Node = null,
            is_unless: bool = false,
        },
        case_stmt: struct {
            condition: ?*Node,
            when_branches: []const WhenBranch,
            else_branch: ?*Node = null,
        },
        while_stmt: struct {
            condition: *Node,
            body: *Node,
            is_until: bool = false,
        },
        for_stmt: struct {
            bindings: []const ForBinding,
            body: *Node,
            is_intersection: bool = false,
        },
        def_stmt: struct {
            name: []const u8,
            params: []const Param,
            body: *Node,
            is_class_method: bool = false,
        },
        class_stmt: struct {
            name: *Node,
            super_class: ?*Node = null,
            body: *Node,
        },
        module_stmt: struct {
            name: []const u8,
            params: []const Param = &.{},
            body: *Node,
        },
        return_stmt: ?*Node,
        yield_stmt: []const *Node,
        break_stmt: ?*Node,
        next_stmt: ?*Node,
        begin_stmt: struct {
            body: *Node,
            rescues: []const RescueClause,
            ensure_body: ?*Node,
        },
        param_doc: []const u8,
        comment: []const u8,

        // Block Scope
        block: struct {
            params: []const *Node = &.{},
            stmts: []const *Node,
        },
    };
};

pub const Builder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn create(self: Builder, kind: Node.Kind, loc: Location) !*Node {
        // Shared node allocation logic
        const n = try self.allocator.create(Node);
        n.* = .{ .kind = kind, .loc = loc };
        return n;
    }

    pub fn number(self: Builder, lexeme: []const u8, loc: Location) !*Node {
        // Shared float conversion logic
        const val = std.fmt.parseFloat(f64, lexeme) catch return error.InvalidExpression;
        return self.create(.{ .number = val }, loc);
    }

    pub fn undefNode(self: Builder, loc: Location) !*Node {
        return self.create(.undef, loc);
    }

    pub fn booleanNode(self: Builder, val: bool, loc: Location) !*Node {
        return self.create(.{ .boolean = val }, loc);
    }

    pub fn identifierNode(self: Builder, name: []const u8, loc: Location) !*Node {
        return self.create(.{ .identifier = name }, loc);
    }

    pub fn stringNode(self: Builder, str: []const u8, loc: Location) !*Node {
        return self.create(.{ .string = str }, loc);
    }
};
