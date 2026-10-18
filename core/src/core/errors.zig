//! Syntax errors: `ParseError`, and the `Diagnostic` list (`Diagnostics`) the parser and
//! the resolver add located messages to; and `Code`, the stable name of each syntax and
//! compile error.

const std = @import("std");
const token = @import("token.zig");
const LineIndex = @import("line_index.zig").LineIndex;

pub const ParseError = error{
    AstTooDeep,
    UnexpectedToken,
    InvalidExpression,
    OutOfMemory,
};

/// A syntax or compile error's stable name, shown after its message (`[unexpected-token]`)
/// and sent as an editor diagnostic's code, as a lint finding shows its rule: a message
/// may be reworded in any release, a code stays, so it is what a user searches the docs
/// for and what tooling matches on. Named like the lint rules; docs/README.md lists each
/// (a test checks it does). A runtime error has its kind (`ArgumentError`) instead.
pub const Code = enum {
    // Reading the source
    @"invalid-utf8",
    @"unexpected-character",
    @"unterminated-string",
    @"unterminated-heredoc",
    @"runs-into-heredoc",
    @"invalid-escape",
    @"invalid-number",
    // The structure of the code
    @"unexpected-token",
    @"invalid-expression",
    @"nesting-too-deep",
    @"misplaced-import",
    @"import-without-from",
    @"misplaced-do",
    @"spaced-parentheses",
    @"invalid-parameter",
    @"unexpected-block",
    @"misplaced-splat",
    @"outside-loop",
    @"outside-method",
    @"builtin-redefined",
    @"import-collision",
    // A limit of the bytecode
    @"too-many-parameters",
    @"too-many-arguments",
    @"too-many-variables",
    @"too-many-constants",
    @"too-many-calls",
    @"too-many-global-uses",
    // Not the script's fault
    @"out-of-memory",
    @"internal-error",

    pub fn name(self: Code) []const u8 {
        return @tagName(self);
    }

    /// One sentence on what the code means, for SARIF's rule list.
    pub fn description(self: Code) []const u8 {
        return switch (self) {
            .@"invalid-utf8" => "The source isn't valid UTF-8.",
            .@"unexpected-character" => "A character that starts no token, outside a string or comment.",
            .@"unterminated-string" => "A string, symbol or %-literal never closed before the end of the file.",
            .@"unterminated-heredoc" => "A heredoc whose closing line never comes.",
            .@"runs-into-heredoc" => "A line that runs on into the body of a heredoc it opened.",
            .@"invalid-escape" => "A backslash in a string that starts no valid escape, or a \\u escape that names no character.",
            .@"invalid-number" => "A malformed number, or one beyond the largest (1.8e308).",
            .@"unexpected-token" => "Something other than what the syntax needs here, such as an unclosed parenthesis.",
            .@"invalid-expression" => "A token that can't start an expression.",
            .@"nesting-too-deep" => "Code, or interpolation in a string, nested deeper than the limit.",
            .@"misplaced-import" => "An import or export inside a method, class or block; they belong at the top level.",
            .@"import-without-from" => "An import without its 'from' path.",
            .@"misplaced-do" => "A 'do' after a while, until or for header, which ends at the line break.",
            .@"spaced-parentheses" => "Several arguments in parentheses with a space before them, which hold one value.",
            .@"invalid-parameter" => "A parameter, block parameter or loop variable that can't be one: an instance, class or global variable, a second splat, a block for a block parameter.",
            .@"unexpected-block" => "A call given two blocks (a &block argument and a do or { } block), or yield given one.",
            .@"misplaced-splat" => "A * or ** outside an array, a hash or a call's arguments.",
            .@"outside-loop" => "A break or next outside a loop or block.",
            .@"outside-method" => "A yield, block_given? or super outside a method.",
            .@"builtin-redefined" => "A built-in, such as cube, assigned or redefined.",
            .@"import-collision" => "An import named like a variable of the file.",
            .@"too-many-parameters" => "A method or block with more parameters than the limit.",
            .@"too-many-arguments" => "A call with more arguments than the limit.",
            .@"too-many-variables" => "A function with more variables, or more captured from outside, than the limit.",
            .@"too-many-constants" => "A function with more literals and names than the limit, or a map literal with more entries.",
            .@"too-many-calls" => "A script with more method calls than the limit.",
            .@"too-many-global-uses" => "A script with more uses of top-level variables than the limit.",
            .@"out-of-memory" => "Memory ran out while compiling.",
            .@"internal-error" => "A bug in KupCAD's compiler; please report it with the script.",
        };
    }
};

pub const Diagnostic = struct {
    loc: token.Location,
    code: Code,
    message: []const u8,

    /// "line:col: message [code]", the one-line form for where there is no room for a caret.
    pub fn formatLine(self: Diagnostic, allocator: std.mem.Allocator, line_index: *const LineIndex) ![]u8 {
        const line = line_index.getLine(self.loc.offset) + 1;
        const col = line_index.getUtf8Column(self.loc.offset) + 1;
        return allocator.print("{d}:{d}: {s} [{s}]", .{ line, col, self.message, self.code.name() });
    }
};

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayListUnmanaged(Diagnostic) = .empty,
    /// A diagnostic could not be stored (out of memory). `add` is called where errors
    /// can't propagate, so the owner checks this instead: a dropped syntax error must
    /// not let the source pass as valid.
    dropped: bool = false,

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.list.items) |d| {
            self.allocator.free(d.message);
        }
        self.list.deinit(self.allocator);
    }

    pub fn add(self: *Diagnostics, loc: token.Location, code: Code, comptime fmt: []const u8, args: anytype) void {
        const msg = self.allocator.print(fmt, args) catch {
            self.dropped = true;
            return;
        };
        self.list.append(self.allocator, .{ .loc = loc, .code = code, .message = msg }) catch {
            self.allocator.free(msg);
            self.dropped = true;
        };
    }
};
