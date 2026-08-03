const std = @import("std");
const ast = @import("../core/ast.zig");
const token = @import("../core/token.zig");

pub const Formatter = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayList(u8),
    comments: []const token.Comment,
    comment_idx: usize = 0,
    indent_level: usize = 0,

    pub fn init(allocator: std.mem.Allocator, comments: []const token.Comment) Formatter {
        return .{
            .allocator = allocator,
            .out = .empty,
            .comments = comments,
        };
    }

    pub fn deinit(self: *Formatter) void {
        self.out.deinit(self.allocator);
    }

    fn writeIndent(self: *Formatter) !void {
        try self.out.appendNTimes(self.allocator, ' ', self.indent_level * 2);
    }

    pub fn format(self: *Formatter, root: *ast.Node) ![]const u8 {
        try self.formatNode(root);
        try self.flushComments(std.math.maxInt(u32));
        return try self.out.toOwnedSlice(self.allocator);
    }

    fn flushComments(self: *Formatter, up_to_line: u32) !void {
        while (self.comment_idx < self.comments.len) {
            const c = self.comments[self.comment_idx];
            if (c.loc.line <= up_to_line) {
                if (c.loc.col == 1) try self.writeIndent();

                // Directly append the comment and newline
                try self.out.appendSlice(self.allocator, c.lexeme);
                try self.out.append(self.allocator, '\n');

                self.comment_idx += 1;
            } else {
                break;
            }
        }
    }

    fn formatNode(self: *Formatter, node: *ast.Node) !void {
        try self.flushComments(node.loc.line - 1);

        switch (node.kind) {
            .block => |b| {
                for (b.stmts) |stmt| {
                    try self.writeIndent();
                    try self.formatNode(stmt);
                    try self.out.append(self.allocator, '\n');
                }
            },
            .assignment => |a| {
                // Directly append the variable name and space
                try self.out.appendSlice(self.allocator, a.name);
                try self.out.append(self.allocator, ' ');

                if (a.op) |_| {
                    try self.out.appendSlice(self.allocator, "= ");
                } else {
                    try self.out.appendSlice(self.allocator, "= ");
                }
                try self.formatNode(a.value);
            },
            .binary_op => |b| {
                try self.formatNode(b.left);
                try self.out.appendSlice(self.allocator, " + ");
                try self.formatNode(b.right);
            },
            .number => |n| {
                // Format the number safely into a tiny stack buffer, then append
                var buf: [64]u8 = undefined;
                const str = try std.fmt.bufPrint(&buf, "{d}", .{n});
                try self.out.appendSlice(self.allocator, str);
            },
            .identifier => |i| {
                try self.out.appendSlice(self.allocator, i);
            },
            else => {
                try self.out.appendSlice(self.allocator, "/* unformatted node */");
            },
        }

        try self.flushComments(node.loc.line);
    }
};
