const std = @import("std");
const ast = @import("../../core/ast.zig");

pub const DocstringParser = struct {
    allocator: std.mem.Allocator,
    b: *ast.Builder,

    pub fn parse(self: *DocstringParser, raw: []const u8, main_token: u24) !ast.NodeIndex {
        var clean_text: std.ArrayListUnmanaged(u8) = .empty;
        defer clean_text.deinit(self.allocator);

        var lines = std.mem.splitScalar(u8, raw, '\n');
        var is_first_line = true;

        while (lines.next()) |line| {
            var i: usize = 0;
            // Skip leading whitespace before the '#'
            while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\r')) {
                i += 1;
            }

            if (i < line.len and line[i] == '#') {
                i += 1; // Consume '#'

                if (is_first_line) {
                    // First line: consume exactly 1 space if present
                    if (i < line.len and line[i] == ' ') i += 1;

                    var end = line.len;
                    while (end > i and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r')) {
                        end -= 1;
                    }
                    try clean_text.appendSlice(self.allocator, line[i..end]);
                    is_first_line = false;
                } else {
                    // YARD Continuation Rule: must have an indent (>= 2 spaces after '#')
                    var space_idx = i;
                    var indent_count: usize = 0;
                    while (space_idx < line.len and (line[space_idx] == ' ' or line[space_idx] == '\t')) {
                        indent_count += if (line[space_idx] == '\t') 3 else 1;
                        space_idx += 1;
                    }

                    if (indent_count < 2) {
                        // If there is no indentation, it is NOT a continuation. Break out.
                        break;
                    }

                    // It is a continuation. Consume up to 3 spaces (1 base + 2 indent)
                    // to preserve any deeper, intentional indentation.
                    var consumed: usize = 0;
                    while (i < line.len and consumed < 3) {
                        if (line[i] == ' ') {
                            consumed += 1;
                            i += 1;
                        } else if (line[i] == '\t') {
                            consumed += 3;
                            i += 1;
                        } else {
                            break;
                        }
                    }

                    var end = line.len;
                    while (end > i and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r')) {
                        end -= 1;
                    }
                    try clean_text.append(self.allocator, '\n');
                    try clean_text.appendSlice(self.allocator, line[i..end]);
                }
            }
        }

        const text = std.mem.trim(u8, clean_text.items, " \n\r\t");

        if (text.len == 0 or text[0] != '@') {
            const empty_doc_idx = try self.b.addDocString(.{
                .tag_name = try self.b.intern(""),
                .content = try self.b.intern(""),
            });
            return self.b.createNode(.docstring, main_token, empty_doc_idx);
        }

        var doc = ast.DocString{
            .tag_name = .none,
            .content = .none,
        };

        // Extract the tag name (e.g., "@label" -> "label")
        var iter = std.mem.tokenizeAny(u8, text, " \n\r\t");
        var tag_name: []const u8 = "";
        if (iter.next()) |tag| {
            tag_name = tag;
            doc.tag_name = try self.b.intern(tag[1..]);
        }

        // The content is everything after the tag.
        const content_start = tag_name.len;
        if (content_start < text.len) {
            var content = text[content_start..];
            // Strip leading spaces from the first line's content only.
            var c_idx: usize = 0;
            while (c_idx < content.len and (content[c_idx] == ' ' or content[c_idx] == '\t')) {
                c_idx += 1;
            }
            var end = content.len;
            while (end > c_idx and (content[end - 1] == ' ' or content[end - 1] == '\t' or content[end - 1] == '\n' or content[end - 1] == '\r')) {
                end -= 1;
            }
            doc.content = try self.b.intern(content[c_idx..end]);
        } else {
            doc.content = try self.b.intern("");
        }

        const final_doc_idx = try self.b.addDocString(doc);
        return self.b.createNode(.docstring, main_token, final_doc_idx);
    }
};
