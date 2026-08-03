const std = @import("std");
const ast = @import("../../core/ast.zig");
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");

pub const DocstringParser = struct {
    allocator: std.mem.Allocator,
    b: *ast.Builder,

    pub fn parse(self: *DocstringParser, raw: []const u8, loc: ast.Location) !*ast.ParamDoc {
        // Normalize the text (remove '#' and compress spaces, but PRESERVE newlines)
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
            return self.b.box(ast.ParamDoc, .{ .tag_name = try self.b.intern("") });
        }

        var doc = ast.ParamDoc{ .tag_name = "" };

        // Extract options `{ ... }` at the end
        var desc_end: usize = text.len;
        if (text[text.len - 1] == '}') {
            if (std.mem.lastIndexOfScalar(u8, text, '{')) |brace_idx| {
                const options_str = text[brace_idx..];
                desc_end = brace_idx;

                // Spin up the KupCAD parser to natively parse the options hash
                var lexer = lexer_mod.Lexer.init(options_str, loc.file_id);
                var parser = parser_mod.Parser.init(&lexer, self.allocator);
                parser.b = self.b.*; // Clone builder so they share the StringPool and Allocator

                if (parser.parseExpression(.none)) |node| {
                    doc.options_expr = node;
                } else |_| {}
                parser.diagnostics.deinit(); // Clean up sub-parser errors
            }
        }

        // Tokenize the remaining string, splitting by spaces OR newlines to extract tags safely
        const header_str = std.mem.trim(u8, text[0..desc_end], " \n\r\t");
        var iter = std.mem.tokenizeAny(u8, header_str, " \n\r\t");

        if (iter.next()) |tag| {
            doc.tag_name = try self.b.intern(tag[1..]); // skip '@'
        }

        // Only @param and @option have a target variable name
        if (std.mem.eql(u8, doc.tag_name, "param") or std.mem.eql(u8, doc.tag_name, "option")) {
            if (iter.next()) |name| {
                doc.target_name = try self.b.intern(name);
            }
        }

        // Check for Type `[Type]` and Description
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

        return self.b.box(ast.ParamDoc, doc);
    }
};
