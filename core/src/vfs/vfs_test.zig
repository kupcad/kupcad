const std = @import("std");
const testing = std.testing;
const MemoryVfs = @import("memory.zig").MemoryVfs;
const Vfs = @import("vfs.zig").Vfs;

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

test "Vfs: none has no files and refuses every write" {
    const fs: Vfs = .none;
    // build.zig is in the working directory: none doesn't read the disk
    try testing.expectError(error.FileNotFound, fs.readFile(testing.allocator, "build.zig"));
    try testing.expectError(error.AccessDenied, fs.writeFile("out.stl", "solid"));
    try testing.expectError(error.AccessDenied, fs.makePath("out"));
    try testing.expectError(error.AccessDenied, fs.hardLink("a", "b"));
    try testing.expectError(error.AccessDenied, fs.symLink("a", "b"));
    try testing.expectError(error.OperationUnsupported, fs.hardLinkTrusted("/abs/source", "dest"));
}
