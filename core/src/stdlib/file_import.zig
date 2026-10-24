//! What the file imports (drawing_import.zig, mesh_import.zig) share: reading the file, an
//! ImportError naming it when it can't be read or is past its limit, and the ImportError of
//! what a reader's Diagnostic says.

const VM = @import("../vm/vm.zig").VM;
const Diagnostic = @import("../exporters/diagnostic.zig").Diagnostic;

/// The `format` file at `path`, owned by vm.allocator: an ImportError when it can't be read
/// or is past `max_bytes` (null: as large as memory allows).
pub fn read(vm: *VM, path: []const u8, comptime format: []const u8, max_bytes: ?usize) ![]u8 {
    const file = vm.readScriptFile(path) catch |err| {
        if (err == error.OutOfMemory) return err;
        return vm.fail(.ImportError, "could not read " ++ format ++ " file '{s}': {s}", .{ path, @errorName(err) });
    };
    errdefer vm.allocator.free(file);
    if (max_bytes) |max| if (file.len > max) {
        return vm.fail(.ImportError, format ++ " file '{s}' is {d} bytes; a script reads at most {d}", .{ path, file.len, max });
    };
    return file;
}

/// The ImportError of a reader's `err`, with what `diag` says of it.
pub fn unreadable(vm: *VM, err: error{ Unreadable, OutOfMemory }, path: []const u8, comptime format: []const u8, diag: *const Diagnostic) error{ RuntimeError, OutOfMemory } {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unreadable => vm.fail(.ImportError, "could not read " ++ format ++ " file '{s}': {s}", .{ path, diag.message() }),
    };
}
