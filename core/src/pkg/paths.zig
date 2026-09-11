const std = @import("std");
const builtin = @import("builtin");

pub const PathError = error{
    HomeNotFound,
} || std.mem.Allocator.Error;

pub fn getHomeDir(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) PathError![]const u8 {
    if (builtin.os.tag == .windows) {
        const funcs = struct {
            extern "shell32" fn SHGetKnownFolderPath(
                rfid: *const std.os.windows.GUID,
                dwFlags: std.os.windows.DWORD,
                hToken: ?std.os.windows.HANDLE,
                ppszPathL: *std.os.windows.PWSTR,
            ) callconv(.winapi) c_long;
            extern "ole32" fn CoTaskMemFree(pv: std.os.windows.LPVOID) callconv(.winapi) void;
        };

        // FOLDERID_Profile
        const guid = comptime std.os.windows.GUID.parse("{5E6C858F-0E22-4760-9AFE-EA3317B67173}");
        var dir_path_ptr: [*:0]u16 = undefined;

        if (funcs.SHGetKnownFolderPath(&guid, 32768, null, &dir_path_ptr) == 0) {
            defer funcs.CoTaskMemFree(@ptrCast(dir_path_ptr));
            if (std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(dir_path_ptr))) |path| {
                return path;
            } else |_| {}
        }

        // Windows Fallback
        if (env_map.get("USERPROFILE")) |val| {
            return try allocator.dupe(u8, val);
        }
    } else {
        // POSIX / WASI Native
        if (env_map.get("HOME")) |val| {
            return try allocator.dupe(u8, val);
        }
    }

    return error.HomeNotFound;
}
