//! The UTF-8 byte order mark some editors start a text file with (Notepad, PowerShell's
//! `Out-File`): no part of the text. A script's lexer and line index read past it, and so does
//! each reader of a text format a script imports (JSON, OBJ, DXF), which took it for the
//! start of the first token.

const std = @import("std");

pub const UTF8 = "\xEF\xBB\xBF";

/// `text` past the byte order mark it starts with, if it does.
pub fn skip(text: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, text, UTF8)) text[UTF8.len..] else text;
}
