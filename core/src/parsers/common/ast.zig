const std = @import("std");
pub const Location = @import("token.zig").Location;

pub const UnaryOp = enum {
    negate, // -
    not, // !
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
};

pub const Param = struct {
    name: []const u8,
    default_value: ?*Node = null,
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
            names: []const []const u8,
            op: ?BinaryOp = null,
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

        // List Comprehension: `[ for (x = [0:5]) each x * 2 ]`
        comprehension: struct {
            clauses: []const *Node,
            yield_expr: *Node,
        },
        each_expr: *Node,

        // Method / Function Call: `obj.method(x: 10) do |a| ... end` or `cube(10)`
        method_call: struct {
            receiver: ?*Node,
            method_name: []const u8,
            args: []const NamedArg,
            block: ?*Node = null,
        },
        super_call: struct {
            args: []const NamedArg = &.{},
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
        },
        class_stmt: struct {
            name: []const u8,
            super_class: ?[]const u8 = null,
            body: *Node,
        },
        module_stmt: struct {
            name: []const u8,
            params: []const Param = &.{},
            body: *Node,
        },
        return_stmt: ?*Node,
        yield_stmt: ?*Node,
        break_stmt: ?*Node,
        param_doc: []const u8,
        comment: []const u8,

        // Block Scope
        block: struct {
            params: []const []const u8 = &.{},
            stmts: []const *Node,
        },
    };
};

pub const NamedArg = struct {
    name: []const u8,
    value: *Node,
};
