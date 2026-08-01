const std = @import("std");
const Location = @import("token.zig").Location;

pub const BinaryOp = enum {
    add, // +
    subtract, // -
    intersect, // &
    multiply, // *
    divide, // /
};

pub const Node = struct {
    kind: Kind,
    loc: Location,

    pub const Kind = union(enum) {
        // Values
        number: f64,
        string: []const u8,
        identifier: []const u8,

        // CSG / Math Operations
        binary_op: struct {
            op: BinaryOp,
            left: *Node,
            right: *Node,
        },

        // Geometry Primitives (Universal representation of Box, Cylinder, etc.)
        geometry_call: struct {
            primitive_type: PrimitiveType,
            args: []const NamedArg,
        },

        // Block / Module scopes
        block: []const Node,
    };
};

pub const PrimitiveType = enum {
    cube,
    cylinder,
    sphere,
};

pub const NamedArg = struct {
    name: []const u8,
    value: *Node,
};
