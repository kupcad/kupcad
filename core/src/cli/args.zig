//! A command's arguments (everything after its name) as a slice. main collects them
//! first so it can answer `--help` wherever it appears; commands and their tests read
//! them one at a time with `next`.

const std = @import("std");
const Reporter = @import("reporter.zig").Reporter;

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

/// The one file a command takes and nothing else (`doc`, `dev ast-dump`): null, why reported
/// with `usage`, for none, an option (which the command has none of), or a second one. They
/// took their first argument as the file, whatever it was (`doc --format p.kup` read a file
/// named `--format`), and ignored the rest.
pub fn onlyFile(args: *Args, reporter: Reporter, comptime usage: []const u8) ?[]const u8 {
    const path = args.next() orelse {
        reporter.err("Error: Missing input file path.\n\n" ++ usage, .{});
        return null;
    };
    const extra = args.next();
    for ([_]?[]const u8{ path, extra }) |arg| if (arg) |a| if (std.mem.startsWith(u8, a, "-")) {
        reporter.err("Error: Unknown option '{s}'\n\n" ++ usage, .{a});
        return null;
    };
    if (extra) |second| {
        reporter.err("Error: Expected one input file, got '{s}' and '{s}'\n\n" ++ usage, .{ path, second });
        return null;
    }
    return path;
}
