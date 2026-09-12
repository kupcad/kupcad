const std = @import("std");
const testing = std.testing;
const VM = @import("vm.zig").VM;
const chunk = @import("chunk.zig");
const Document = @import("../core/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

test "VM: op_import correctly evaluates and destructures modules" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    const pkg_source =
        \\module MathPkg
        \\  def self.add(x, y) x + y end
        \\end
        \\export MathPkg
    ;
    try mem_vfs.vfs().writeFile("./math_pkg.kup", pkg_source);

    const main_source =
        \\import { MathPkg } from "./math_pkg.kup"
        \\result = MathPkg.add(10, 5)
    ;

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);

    const result_val = vm.globals.get("result") orelse return error.MissingResult;
    try testing.expectEqual(@as(f64, 15.0), result_val.asNumber());
}

test "VM: op_import resolves transitive dependencies securely via Modules" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // Module B
    const mod_b_source =
        \\module MathHelper
        \\  def self.double(x) x * 2 end
        \\end
        \\export MathHelper
    ;
    try mem_vfs.vfs().writeFile("./mod_b.kup", mod_b_source);

    // Module A
    const mod_a_source =
        \\import { MathHelper } from "./mod_b.kup"
        \\module Calculator
        \\  def self.quadruple(x) MathHelper.double(MathHelper.double(x)) end
        \\end
        \\export Calculator
    ;
    try mem_vfs.vfs().writeFile("./mod_a.kup", mod_a_source);

    // Main Script
    const main_source =
        \\import { Calculator } from "./mod_a.kup"
        \\result = Calculator.quadruple(5)
    ;

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);

    const result_val = vm.globals.get("result") orelse return error.MissingResult;
    try testing.expectEqual(@as(f64, 20.0), result_val.asNumber());
}

test "VM: op_import caches evaluated modules to prevent redundant execution" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    const pkg_source =
        \\def get_value() 99 end
        \\export get_value
    ;
    try mem_vfs.vfs().writeFile("./shared_pkg.kup", pkg_source);

    const main_source =
        \\import { get_value } from "./shared_pkg.kup"
        \\import { get_value } from "./shared_pkg.kup"
        \\result = get_value()
    ;

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);
    try testing.expectEqual(@as(usize, 1), vm.modules.count());
}

test "VM: op_import safely halts on package runtime errors" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    try mem_vfs.vfs().writeFile("./crash_pkg.kup", "raise(ArgumentError)");

    const main_source =
        \\import "./crash_pkg.kup"
        \\success = true
    ;

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    vm.mute_errors = true;
    const res = vm.interpret(&out_chunk);

    try testing.expectEqual(.runtime_error, res);
    try testing.expect(!vm.globals.contains("success"));
}

test "VM: op_import safely returns empty modules for blank files" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    try mem_vfs.vfs().writeFile("./empty_pkg.kup", "");

    const main_source =
        \\import "./empty_pkg.kup"
        \\success = true
    ;

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);
}

test "VM: op_import destructuring throws RuntimeError for missing exports" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    try mem_vfs.vfs().writeFile("./pkg.kup", "export func_a");

    const main_source = "import { func_b } from \"./pkg.kup\"";

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    vm.mute_errors = true;
    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.runtime_error, res);
}
