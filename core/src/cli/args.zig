//! A command's arguments (everything after its name) as a slice. main collects them
//! first so it can answer `--help` wherever it appears; commands and their tests read
//! them one at a time with `next`.

const std = @import("std");

pub const Args = struct {
    items: []const []const u8,
    index: usize = 0,

    pub fn next(self: *Args) ?[]const u8 {
        if (self.index >= self.items.len) return null;
        defer self.index += 1;
        return self.items[self.index];
    }
};

/// `-h` or `--help`.
pub fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

/// Whether `items` ask for help anywhere, so `kupcad check file.kup --help` shows check's
/// help instead of trying to read a file named `--help`.
pub fn wantsHelp(items: []const []const u8) bool {
    for (items) |arg| {
        if (isHelp(arg)) return true;
    }
    return false;
}
