const std = @import("std");
const testing = std.testing;
const VM = @import("vm.zig").VM;
const chunk = @import("chunk.zig");
const value = @import("../core/value.zig");
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

test "VM: op_import safely aborts on missing package files" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // Import a file that was never written to the VFS
    const main_source = "import \"./does_not_exist.kup\"";

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

    // Must gracefully yield a runtime error (ImportError) without panicking
    try testing.expectEqual(.runtime_error, res);
}

test "VM: op_import destructuring a primitive export throws RuntimeError" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // Package exports a raw number instead of a Module/Class
    try mem_vfs.vfs().writeFile("./prim.kup", "export 42");

    // Parent attempts to destructure the number, which lacks properties
    const main_source = "import { x } from \"./prim.kup\"";

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

test "VM: op_import safely aborts on infinite circular dependencies" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // Ping imports Pong, Pong imports Ping
    try mem_vfs.vfs().writeFile("./ping.kup", "import \"./pong.kup\"");
    try mem_vfs.vfs().writeFile("./pong.kup", "import \"./ping.kup\"");

    const main_source = "import \"./ping.kup\"";

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

    // The VM's call stack tracking or gas limit must catch the runaway recursion
    try testing.expect(res == .runtime_error or res == .execution_limit_exceeded);
}

test "VM: op_import caches by reference allowing cross-file state sharing" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // Shared State Module exports an Array (Reference Type)
    const state_source =
        \\shared_list = [1, 2, 3]
        \\export shared_list
    ;
    try mem_vfs.vfs().writeFile("./state.kup", state_source);

    // Mutator Module modifies the array by reference
    const mutator_source =
        \\import { shared_list } from "./state.kup"
        \\shared_list[0] = 99
    ;
    try mem_vfs.vfs().writeFile("./mutator.kup", mutator_source);

    // Main script verifies the mutation persisted across the cache
    const main_source =
        \\import "./mutator.kup"
        \\import { shared_list } from "./state.kup"
        \\result = shared_list[0]
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

    // If the cache works, index 0 is 99 (mutated), not 1 (original)
    const result_val = vm.globals.get("result") orelse return error.MissingResult;
    try testing.expectEqual(@as(f64, 99.0), result_val.asNumber());
}

test "VM: op_import supports destructuring multiple exports perfectly" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // Exporting local functions uses the comma-separated list syntax (no braces)
    const pkg_source =
        \\def func_one() 1 end
        \\def func_two() 2 end
        \\export func_one, func_two
    ;
    try mem_vfs.vfs().writeFile("./multi.kup", pkg_source);

    // Destructuring imports DO use braces
    const main_source =
        \\import { func_one, func_two } from "./multi.kup"
        \\result = func_one() + func_two()
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
    try testing.expectEqual(@as(f64, 3.0), result_val.asNumber());
}

test "VM: op_import supports exporting Classes and Modules securely" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // Package defines a Class and a Module
    const pkg_source =
        \\class CustomBox
        \\  def build
        \\    100
        \\  end
        \\end
        \\
        \\module MathUtils
        \\  def self.pi
        \\    3.14
        \\  end
        \\end
        \\
        \\export CustomBox, MathUtils
    ;
    try mem_vfs.vfs().writeFile("./complex_pkg.kup", pkg_source);

    const main_source =
        \\import { CustomBox, MathUtils } from "./complex_pkg.kup"
        \\
        \\box = CustomBox.new
        \\result = box.build + MathUtils.pi
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
    try testing.expectEqual(@as(f64, 103.14), result_val.asNumber());
}

test "VM: op_import closures maintain upvalues to private package state" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    const pkg_source =
        \\def create_counter
        \\  counter = 0
        \\  def inc
        \\    counter = counter + 1
        \\    counter
        \\  end
        \\  inc
        \\end
        \\
        \\increment = create_counter
        \\export increment
    ;
    try mem_vfs.vfs().writeFile("./stateful_pkg.kup", pkg_source);

    const main_source =
        \\import { increment } from "./stateful_pkg.kup"
        \\
        \\result = increment + increment # Invoked without ()
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
    try testing.expectEqual(@as(f64, 3.0), result_val.asNumber());

    try testing.expect(!vm.globals.contains("counter"));
}

test "VM: op_import merges multiple sequential export statements" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    const pkg_source =
        \\def m1
        \\ 10
        \\end
        \\
        \\def m2
        \\  20
        \\end
        \\
        \\export m1
        \\export m2
    ;
    try mem_vfs.vfs().writeFile("./seq_pkg.kup", pkg_source);

    const main_source =
        \\import { m1, m2 } from "./seq_pkg.kup"
        \\result = m1 + m2
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
    try testing.expectEqual(@as(f64, 30.0), result_val.asNumber());
}

test "VM: op_import allows exporting aliased primitives and references" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // Package dynamically reassigns and exports an array and a string
    const pkg_source =
        \\my_list = [10, 20]
        \\app_name = "KupCAD Plugin"
        \\export my_list, app_name
    ;
    try mem_vfs.vfs().writeFile("./alias_pkg.kup", pkg_source);

    const main_source =
        \\import { my_list, app_name } from "./alias_pkg.kup"
        \\
        \\list_val = my_list[1]
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

    const list_val = vm.globals.get("list_val") orelse return error.MissingResult;
    try testing.expectEqual(@as(f64, 20.0), list_val.asNumber());

    const app_name = vm.globals.get("app_name") orelse return error.MissingResult;
    try testing.expectEqualStrings("KupCAD Plugin", app_name.asString().chars);
}

test "VM: op_import resolves non-relative package imports from workspace" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // Simulated package installed at `.kupcad/pkg/cad-helpers/main.kup`
    const pkg_source =
        \\def calculate_area(w, h)
        \\  w * h
        \\end
        \\export calculate_area
    ;
    // Path matches compiler workspace path without leading ./
    try mem_vfs.vfs().writeFile(".kupcad/pkg/cad-helpers/main.kup", pkg_source);

    // Non-relative import syntax: "cad-helpers"
    const main_source =
        \\import { calculate_area } from "cad-helpers"
        \\result = calculate_area(4, 5)
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

test "VM: op_import routes STL asset imports to native handler" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    const main_source =
        \\import mesh from "./bracket.stl"
    ;

    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    // Register a mock `import_stl` kernel function with `*anyopaque`
    const mock_import_stl = struct {
        fn call(v_ptr: *anyopaque, arg_count: u8, args: [*]value.Value) !value.Value {
            _ = v_ptr;
            _ = arg_count;
            _ = args;
            return value.Value.initNumber(777.0); // Mock Mesh Object ID
        }
    }.call;

    try vm.defineNative("import_stl", mock_import_stl);

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);

    const mesh_val = vm.globals.get("mesh") orelse return error.MissingResult;
    try testing.expectEqual(@as(f64, 777.0), mesh_val.asNumber());
}

test "VM: op_import supports nested namespace re-exports" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // Core Module
    const core_source =
        \\module Core
        \\  def self.version
        \\    "1.0.0"
        \\  end
        \\end
        \\export Core
    ;
    try mem_vfs.vfs().writeFile("./core_math.kup", core_source);

    // Facade file re-exporting Core
    const facade_source =
        \\import { Core } from "./core_math.kup"
        \\export Core
    ;
    try mem_vfs.vfs().writeFile("./facade.kup", facade_source);

    // Consumer file importing Core from Facade
    const main_source =
        \\import { Core } from "./facade.kup"
        \\ver = Core.version
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

    const ver_val = vm.globals.get("ver") orelse return error.MissingResult;
    try testing.expectEqualStrings("1.0.0", ver_val.asString().chars);
}
