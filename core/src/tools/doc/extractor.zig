const std = @import("std");
const ast = @import("../../core/ast.zig");
const Document = @import("../../core/document.zig").Document;

pub const ParamMetadata = struct {
    key: []const u8,
    label: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
    default_val: ?f64 = null,
};

pub fn extractParameters(allocator: std.mem.Allocator, doc: *const Document) ![]ParamMetadata {
    var params: std.ArrayListUnmanaged(ParamMetadata) = .empty;
    errdefer params.deinit(allocator);

    if (doc.tree.root == .none) return params.toOwnedSlice(allocator);
    const root_node = doc.tree.getNode(doc.tree.root) orelse return params.toOwnedSlice(allocator);

    // Ensure root is a block
    if (root_node.tag != .block) return params.toOwnedSlice(allocator);
    const block_payload = doc.tree.block(root_node);
    const stmts = doc.tree.getNodes(block_payload.stmts);

    for (stmts) |stmt_idx| {
        const stmt_node = doc.tree.getNode(stmt_idx) orelse continue;

        // Look for Method Calls
        if (stmt_node.tag == .method_call) {
            const mc = doc.tree.methodCall(stmt_node);
            const method_name = doc.tree.getString(mc.method_name);

            // Isolate "param" calls that have no receiver (global method)
            if (std.mem.eql(u8, method_name, "param") and mc.receiver == .none) {
                var meta = ParamMetadata{ .key = "" };

                // Extract Parameter Key (first argument)
                const args = doc.tree.getNamedArgs(mc.args);
                if (args.len > 0) {
                    const key_node = doc.tree.getNode(args[0].value).?;
                    if (key_node.tag == .symbol or key_node.tag == .string) {
                        meta.key = doc.tree.getString(@as(ast.StringId, @enumFromInt(key_node.data)));
                    }
                }

                // Extract Default value (from kwargs)
                for (args) |arg| {
                    if (arg.name != .none) {
                        const arg_name = doc.tree.getString(arg.name);
                        if (std.mem.eql(u8, arg_name, "default")) {
                            const val_node = doc.tree.getNode(arg.value).?;
                            if (val_node.tag == .number) {
                                meta.default_val = doc.tree.number(val_node);
                            }
                        }
                    }
                }

                // Extract Comments (scan backwards from the `param` token)
                const param_line = doc.line_index.getLine(doc.tokens.starts[stmt_node.main_token]);

                var current_line = param_line;
                while (current_line > 0) {
                    current_line -= 1;
                    const comment_opt = getCommentOnLine(doc, current_line);
                    if (comment_opt) |comment_text| {
                        if (std.mem.indexOf(u8, comment_text, "# @label")) |idx| {
                            meta.label = std.mem.trim(u8, comment_text[idx + 8 ..], " \t\r\n");
                        } else if (std.mem.indexOf(u8, comment_text, "# @tooltip")) |idx| {
                            meta.tooltip = std.mem.trim(u8, comment_text[idx + 10 ..], " \t\r\n");
                        }
                    } else {
                        break; // Stop scanning if we hit a blank line or non-comment code
                    }
                }

                try params.append(allocator, meta);
            }
        }
    }

    return params.toOwnedSlice(allocator);
}

// Helper function to extract a comment string given a line index.
fn getCommentOnLine(doc: *const Document, target_line: u32) ?[]const u8 {
    for (doc.comments) |comment| {
        const c_line = doc.line_index.getLine(comment.loc.offset);
        if (c_line == target_line) return comment.lexeme;
    }
    return null;
}
