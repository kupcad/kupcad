const std = @import("std");
const testing = std.testing;
const MemoryVfs = @import("memory.zig").MemoryVfs;

// MemoryVfs/NativeVfs behavior is covered in memory_test.zig / native_test.zig.

// Backends without a physical filesystem leave hardLinkTrusted unset; callers
// (Cafs.linkBlob) rely on OperationUnsupported to fall back to copying.
test "Vfs: hardLinkTrusted is OperationUnsupported when the backend lacks it" {
    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();
    const fs = mem.vfs();

    try testing.expectError(error.OperationUnsupported, fs.hardLinkTrusted("/abs/source", "dest"));
    try testing.expectError(error.FileNotFound, fs.readFile(testing.allocator, "dest"));
}
