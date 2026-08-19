const std = @import("std");
const ast = @import("../../core/ast.zig");
const Document = @import("../../core/document.zig").Document;

/// Structure representing metadata extracted for a script parameter.
pub const ParamMetadata = struct {
    key: []const u8,
    label: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
    default_val: ?f64 = null,
};

/// Scans a parsed Document's AST to extract parameter metadata (`param(:key, default: val)`)
/// along with preceding AST `.docstring` nodes (`# @label`, `# @tooltip`).
/// If a parameter with the same key is encountered multiple times, subsequent definitions
/// will override and merge into the previous metadata entry.
pub fn extractParameters(allocator: std.mem.Allocator, doc: *const Document) ![]ParamMetadata {
    var params: std.ArrayListUnmanaged(ParamMetadata) = .empty;
    errdefer params.deinit(allocator);

    // Return empty slice if the document AST is empty
    if (doc.tree.root == .none) return params.toOwnedSlice(allocator);
    const root_node = doc.tree.getNode(doc.tree.root) orelse return params.toOwnedSlice(allocator);

    // Parameter declarations are top-level statements inside the root block
    if (root_node.tag != .block) return params.toOwnedSlice(allocator);
    const block_payload = doc.tree.block(root_node);
    const stmts = doc.tree.getNodes(block_payload.stmts);

    var pending_label: ?[]const u8 = null;
    var pending_tooltip: ?[]const u8 = null;

    for (stmts) |stmt_idx| {
        const stmt_node = doc.tree.getNode(stmt_idx) orelse continue;

        // Collect Docstring AST Nodes preceding a statement
        if (stmt_node.tag == .docstring) {
            const doc_data = doc.tree.docString(stmt_node);
            const tag_name = doc.tree.getString(doc_data.tag_name);
            const content = doc.tree.getString(doc_data.content);

            if (std.mem.eql(u8, tag_name, "label")) {
                pending_label = content;
            } else if (std.mem.eql(u8, tag_name, "tooltip")) {
                pending_tooltip = content;
            }
            continue;
        }

        // Process Global `param(...)` Method Calls
        if (stmt_node.tag == .method_call) {
            const mc = doc.tree.methodCall(stmt_node);
            const method_name = doc.tree.getString(mc.method_name);

            // Isolate standalone "param" function calls with no receiver
            if (std.mem.eql(u8, method_name, "param") and mc.receiver == .none) {
                var meta = ParamMetadata{
                    .key = "",
                    .label = pending_label,
                    .tooltip = pending_tooltip,
                };

                // Extract Parameter Key (First positional argument)
                const args = doc.tree.getNamedArgs(mc.args);
                if (args.len > 0) {
                    const key_node = doc.tree.getNode(args[0].value).?;
                    if (key_node.tag == .symbol or key_node.tag == .string) {
                        meta.key = doc.tree.getString(@as(ast.StringId, @enumFromInt(key_node.data)));
                    }
                }

                // Process only valid parameter calls with a non-empty key
                if (meta.key.len > 0) {
                    // Extract Default Value (From keyword argument `default: ...`)
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

                    // Key Overriding / Merging Logic
                    // If the parameter key was already declared earlier, update its values
                    var existing_found = false;
                    for (params.items) |*existing| {
                        if (std.mem.eql(u8, existing.key, meta.key)) {
                            if (meta.label) |l| existing.label = l;
                            if (meta.tooltip) |t| existing.tooltip = t;
                            if (meta.default_val) |d| existing.default_val = d;
                            existing_found = true;
                            break;
                        }
                    }

                    // Append as a new parameter entry if it hasn't been seen yet
                    if (!existing_found) {
                        try params.append(allocator, meta);
                    }
                }
            }
        }

        // Reset pending docstrings after hitting any non-docstring statement
        pending_label = null;
        pending_tooltip = null;
    }

    return params.toOwnedSlice(allocator);
}
