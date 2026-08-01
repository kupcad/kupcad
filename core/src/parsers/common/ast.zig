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
    exponent, // **
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

pub const Node = struct {
    kind: Kind,
    loc: Location,

    pub const Kind = union(enum) {
        // Literals
        number: f64,
        string: []const u8,
        symbol: []const u8,
        boolean: bool,
        nil,
        array_literal: []const *Node,
        hash_literal: []const HashEntry,

        // Range: `start..end`
        range: struct {
            start: *Node,
            end: *Node,
        },

        // Variable lookup
        identifier: []const u8,

        // Assignment: `target = expr`
        assignment: struct {
            name: []const u8,
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

        // Method / Function Call: `obj.method(x: 10) do |a| ... end` or `cube(10)`
        method_call: struct {
            receiver: ?*Node,
            method_name: []const u8,
            args: []const NamedArg,
            block: ?*Node = null,
        },

        // Statement Constructs
        import_stmt: struct {
            symbols: []const []const u8,
            path: []const u8,
        },

        if_stmt: struct {
            condition: *Node,
            then_branch: *Node,
            else_branch: ?*Node = null,
            is_unless: bool = false,
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
            body: *Node,
        },

        return_stmt: ?*Node,
        yield_stmt: ?*Node,
        break_stmt: ?*Node,

        param_doc: []const u8,

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
