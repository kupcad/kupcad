const std = @import("std");
const testing = std.testing;
const ReadOnlyVfs = @import("readonly.zig").ReadOnlyVfs;
const MemoryVfs = @import("memory.zig").MemoryVfs;
const NativeVfs = @import("native.zig").NativeVfs;
const VM = @import("../vm/vm.zig").VM;
const chunk = @import("../vm/chunk.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const registry = @import("../stdlib/registry.zig");
const api = @import("../api.zig");

// LSP VMs run on a ReadOnlyVfs: reads see open buffers then the jailed workspace,
// every write is discarded.

test "ReadOnlyVfs: prefers open buffers and discards every mutating call" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "lib.kup", .data = "on disk" });

    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();
    try mem.vfs().writeFile("lib.kup", "unsaved buffer");
    var disk_ro = NativeVfs.init(testing.io, tmp.dir);
    var sandbox = ReadOnlyVfs.init(mem.vfs(), disk_ro.vfs());
    const v = sandbox.vfs();

    const lib = try v.readFile(testing.allocator, "lib.kup");
    defer testing.allocator.free(lib);
    try testing.expectEqualStrings("unsaved buffer", lib);

    try v.makePath("made/dir");
    try v.writeFile("written.txt", "x");
    try v.hardLink("lib.kup", "hard.kup");
    try v.symLink("lib.kup", "sym.kup");
    try testing.expectError(error.OperationUnsupported, v.hardLinkTrusted("/etc/hosts", "trusted.kup"));
    try testing.expectEqual(@as(usize, 4), sandbox.discarded_writes);

    var it = tmp.dir.iterate();
    var entries: usize = 0;
    while (try it.next(testing.io)) |_| entries += 1;
    try testing.expectEqual(@as(usize, 1), entries); // only lib.kup
}

fn runScript(vm: *VM, source: []const u8) !void {
    var doc = try api.Document.parse(testing.allocator, source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
    if (vm.interpret(&out_chunk) != .ok) return error.RuntimeError;
}

test "ReadOnlyVfs: sandboxed VM cannot write files via export_stl but can read workspace imports" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "victim.stl", .data = "original" });

    var mem = MemoryVfs.init(testing.allocator);
    defer mem.deinit();
    var disk_ro = NativeVfs.init(testing.io, tmp.dir);
    var sandbox = ReadOnlyVfs.init(mem.vfs(), disk_ro.vfs());

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.vfs = sandbox.vfs();
    try registry.registerStandardLibrary(&vm);

    try runScript(&vm, "cube(1).export_stl(\"victim.stl\")\ncube(1).export_stl(\"new.stl\")");

    // Nothing touched on disk (and nothing leaked into the buffer layer either).
    const victim = try tmp.dir.readFileAlloc(testing.io, "victim.stl", testing.allocator, .limited(1024));
    defer testing.allocator.free(victim);
    try testing.expectEqualStrings("original", victim);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "new.stl", .{}));
    try testing.expectError(error.FileNotFound, sandbox.vfs().readFile(testing.allocator, "new.stl"));
    try testing.expectEqual(@as(usize, 2), sandbox.discarded_writes);

    // Reads fall through to the jailed workspace view (read-only imports).
    const read_back = try sandbox.vfs().readFile(testing.allocator, "victim.stl");
    defer testing.allocator.free(read_back);
    try testing.expectEqualStrings("original", read_back);
}
