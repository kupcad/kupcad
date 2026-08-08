const std = @import("std");
const ast = @import("../../core/ast.zig");
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");

pub const DocstringParser = struct {
    allocator: std.mem.Allocator,
    b: *ast.Builder,

    pub fn parse(self: *DocstringParser, raw: []const u8, main_token: u24) !ast.NodeIndex {
        var clean_text: std.ArrayListUnmanaged(u8) = .empty;
        defer clean_text.deinit(self.allocator);
        var lines = std.mem.splitScalar(u8, raw, '\n');
        var is_first_line = true;
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r#");
            if (trimmed.len > 0) {
                if (!is_first_line) {
                    try clean_text.append(self.allocator, '\n');
                }
                try clean_text.appendSlice(self.allocator, trimmed);
                is_first_line = false;
            }
        }
        const text = std.mem.trim(u8, clean_text.items, " \n");
        if (text.len == 0 or text[0] != '@') {
            const empty_doc_idx = try self.b.addParamDoc(.{
                .tag_name = try self.b.intern(""),
                .target_name = .none,
                .type_name = .none,
                .description = try self.b.intern(""),
                .options_expr = .none,
            });
            return self.b.createNode(.param_doc, main_token, empty_doc_idx);
        }
        var doc = ast.ParamDoc{
            .tag_name = .none,
            .target_name = .none,
            .type_name = .none,
            .description = try self.b.intern(""),
            .options_expr = .none,
        };
        var desc_end: usize = text.len;
        if (text[text.len - 1] == '}') {
            if (std.mem.lastIndexOfScalar(u8, text, '{')) |brace_idx| {
                const options_str = text[brace_idx..];
                desc_end = brace_idx;
                var lexer = lexer_mod.Lexer.init(options_str, 0);
                // Lex AOT - Declared as `var` so it can be mutated by deinit
                var tokens = try lexer.lexAll(self.allocator);
                // Initialize with tokens
                var parser = parser_mod.Parser.init(tokens, options_str, self.allocator);
                parser.b = self.b.*;
                if (parser.parseExpression(.none)) |node_idx| {
                    doc.options_expr = node_idx;
                } else |_| {}
                self.b.* = parser.b;
                parser.diagnostics.deinit();
                // We must free the docstring tokens immediately since they aren't arena-backed here
                tokens.deinit(self.allocator);
            }
        }
        const header_str = std.mem.trim(u8, text[0..desc_end], " \n\r\t");
        var iter = std.mem.tokenizeAny(u8, header_str, " \n\r\t");
        if (iter.next()) |tag| {
            doc.tag_name = try self.b.intern(tag[1..]);
        }
        const tag_str = self.b.tree.getString(doc.tag_name);
        if (std.mem.eql(u8, tag_str, "param") or std.mem.eql(u8, tag_str, "option")) {
            if (iter.next()) |name| {
                doc.target_name = try self.b.intern(name);
            }
        }
        const rest = iter.rest();
        const trimmed_rest = std.mem.trim(u8, rest, " \n\r\t");
        if (trimmed_rest.len > 0 and trimmed_rest[0] == '[') {
            if (std.mem.indexOfScalar(u8, trimmed_rest, ']')) |close_idx| {
                doc.type_name = try self.b.intern(trimmed_rest[1..close_idx]);
                doc.description = try self.b.intern(std.mem.trim(u8, trimmed_rest[close_idx + 1 ..], " \n\r\t"));
            } else {
                doc.description = try self.b.intern(trimmed_rest);
            }
        } else {
            doc.description = try self.b.intern(trimmed_rest);
        }
        const final_doc_idx = try self.b.addParamDoc(doc);
        return self.b.createNode(.param_doc, main_token, final_doc_idx);
    }
};
