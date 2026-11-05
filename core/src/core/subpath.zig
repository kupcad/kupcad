//! `under`: whether a path is inside a folder, and its path from there. Each place that
//! confines a path (the native file system, the language server's folders, a `file:`
//! package) tested it its own way: one took `/a/bc` for a path in `/a/b` unless it checked
//! the separator, and some knew only `/` or only the system's own separator.

const std = @import("std");

/// What `path` is from `folder` when it is inside it: the rest after `folder` and the
/// separator that follows it, `/` or `\` on any system (a URI's path and a Windows path mix
/// them). Null when it isn't inside, `folder` itself included. The two are compared as
/// text: both must be absolute and normalized alike (real paths, or two of the editor's).
pub fn under(path: []const u8, folder: []const u8) ?[]const u8 {
    if (folder.len == 0 or !std.mem.startsWith(u8, path, folder)) return null;
    // A folder that ends in its separator is a root: `/`, `C:\`
    const rest = if (isSeparator(folder[folder.len - 1]))
        path[folder.len..]
    else if (path.len > folder.len and isSeparator(path[folder.len]))
        path[folder.len + 1 ..]
    else
        return null;
    return if (rest.len > 0) rest else null;
}

fn isSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}
