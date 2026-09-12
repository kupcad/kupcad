const std = @import("std");
const testing = std.testing;
const VM = @import("vm.zig").VM;
const chunk = @import("chunk.zig");
const Document = @import("../core/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

test "VM: op_import strictly encapsulates package globals" {
    // 1. Setup isolated in-memory file system
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // 2. Seed a mock package that has both public and private state
    const pkg_source =
        \\def internal_helper(x)
        \\  x * 2
        \\end
        \\
        \\secret_val = 42
        \\
        \\def public_api(y)
        \\  y + 1
        \\end
        \\
        \\export public_api
    ;
    // Bind to local path natively
    try mem_vfs.vfs().writeFile("./math_pkg.kup", pkg_source);

    // 3. Seed the main script that imports the package
    const main_source =
        \\import { public_api } from "./math_pkg.kup"
        \\
        \\result = public_api(10)
    ;

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // Wire the VM to use our mock VFS instead of the native disk
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    // 4. Execute the script
    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);

    // 5. Verify the exported function was successfully imported and executed
    const result_val = vm.globals.get("result") orelse return error.MissingResult;
    try testing.expectEqual(@as(f64, 11.0), result_val.asNumber());

    // 6. Verify Strict Encapsulation
    // The parent's global scope MUST NOT contain the package's internal state
    try testing.expect(!vm.globals.contains("secret_val"));
    try testing.expect(!vm.globals.contains("internal_helper"));
}
