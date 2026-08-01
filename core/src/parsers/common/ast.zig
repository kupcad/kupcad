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

        // Method Call: `obj.method(x: 10) do |a| ... end`
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
        },

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
