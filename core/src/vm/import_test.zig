const std = @import("std");
const testing = std.testing;
const VM = @import("vm.zig").VM;
const InterpretResult = @import("vm.zig").InterpretResult;
const chunk = @import("chunk.zig");
const value = @import("../core/value.zig");
const registry = @import("../stdlib/registry.zig");
const Document = @import("../core/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const module_compiler = @import("../compiler/module_compiler.zig");

const LIB_C =
    \\c = 3
    \\def lib_fn
    \\  c
    \\end
    \\export lib_fn
;

test "VM: op_import correctly evaluates and destructures modules" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    const pkg_source =
        \\module MathPkg
        \\  def self.add(x, y) x + y end
        \\end
        \\export MathPkg
    ;
    try mem_vfs.vfs().writeFile("math_pkg.kup", pkg_source);

    const main_source =
        \\import { MathPkg } from "./math_pkg.kup"
        \\result = MathPkg.add(10, 5)
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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
    try mem_vfs.vfs().writeFile("mod_b.kup", mod_b_source);

    // Module A
    const mod_a_source =
        \\import { MathHelper } from "./mod_b.kup"
        \\module Calculator
        \\  def self.quadruple(x) MathHelper.double(MathHelper.double(x)) end
        \\end
        \\export Calculator
    ;
    try mem_vfs.vfs().writeFile("mod_a.kup", mod_a_source);

    // Main Script
    const main_source =
        \\import { Calculator } from "./mod_a.kup"
        \\result = Calculator.quadruple(5)
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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
    try mem_vfs.vfs().writeFile("shared_pkg.kup", pkg_source);

    // Removed the destructuring on the second import to prevent VariableAlreadyDeclared
    const main_source =
        \\import { get_value } from "./shared_pkg.kup"
        \\import "./shared_pkg.kup"
        \\result = get_value
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);
    try testing.expectEqual(@as(usize, 1), vm.modules.count());
}

test "VM: op_import safely halts on package runtime errors" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    try mem_vfs.vfs().writeFile("crash_pkg.kup", "raise(ArgumentError)");

    const main_source =
        \\import "./crash_pkg.kup"
        \\success = true
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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

    try mem_vfs.vfs().writeFile("empty_pkg.kup", "");

    const main_source =
        \\import "./empty_pkg.kup"
        \\success = true
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);
}

test "VM: op_import destructuring throws RuntimeError for missing exports" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    try mem_vfs.vfs().writeFile("pkg.kup", "export func_a");

    const main_source = "import { func_b } from \"./pkg.kup\"";

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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
    try mem_vfs.vfs().writeFile("prim.kup", "export 42");

    // Parent attempts to destructure the number, which lacks properties
    const main_source = "import { x } from \"./prim.kup\"";

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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
    try mem_vfs.vfs().writeFile("ping.kup", "import \"./pong.kup\"");
    try mem_vfs.vfs().writeFile("pong.kup", "import \"./ping.kup\"");

    const main_source = "import \"./ping.kup\"";

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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
    try mem_vfs.vfs().writeFile("state.kup", state_source);

    // Mutator Module modifies the array by reference
    const mutator_source =
        \\import { shared_list } from "./state.kup"
        \\shared_list[0] = 99
    ;
    try mem_vfs.vfs().writeFile("mutator.kup", mutator_source);

    // Main script verifies the mutation persisted across the cache
    const main_source =
        \\import "./mutator.kup"
        \\import { shared_list } from "./state.kup"
        \\result = shared_list[0]
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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
    try mem_vfs.vfs().writeFile("multi.kup", pkg_source);

    // Destructuring imports DO use braces
    const main_source =
        \\import { func_one, func_two } from "./multi.kup"
        \\result = func_one() + func_two()
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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
    try mem_vfs.vfs().writeFile("complex_pkg.kup", pkg_source);

    const main_source =
        \\import { CustomBox, MathUtils } from "./complex_pkg.kup"
        \\
        \\box = CustomBox.new
        \\result = box.build + MathUtils.pi
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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
    try mem_vfs.vfs().writeFile("stateful_pkg.kup", pkg_source);

    const main_source =
        \\import { increment } from "./stateful_pkg.kup"
        \\
        \\result = increment + increment # Invoked without ()
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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
    try mem_vfs.vfs().writeFile("seq_pkg.kup", pkg_source);

    const main_source =
        \\import { m1, m2 } from "./seq_pkg.kup"
        \\result = m1 + m2
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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
    try mem_vfs.vfs().writeFile("alias_pkg.kup", pkg_source);

    const main_source =
        \\import { my_list, app_name } from "./alias_pkg.kup"
        \\
        \\list_val = my_list[1]
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    // Register a mock `import_stl` kernel function with `*anyopaque`
    const mock_import_stl = struct {
        fn call(v_ptr: *anyopaque, args: value.NativeArgs) !value.Value {
            _ = v_ptr;
            _ = args;
            return value.Value.initNumber(777.0); // Mock Mesh Object ID
        }
    }.call;

    try vm.defineNative("import_stl", mock_import_stl);

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
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
    try mem_vfs.vfs().writeFile("core_math.kup", core_source);

    // Facade file re-exporting Core
    const facade_source =
        \\import { Core } from "./core_math.kup"
        \\export Core
    ;
    try mem_vfs.vfs().writeFile("facade.kup", facade_source);

    // Consumer file importing Core from Facade
    const main_source =
        \\import { Core } from "./facade.kup"
        \\ver = Core.version
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);

    const ver_val = vm.globals.get("ver") orelse return error.MissingResult;
    try testing.expectEqualStrings("1.0.0", ver_val.asString().chars);
}

test "VM: op_import detects multi-level circular dependencies (A -> B -> C -> A)" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // 3-way cyclic dependency loop
    try mem_vfs.vfs().writeFile("a.kup", "import \"./b.kup\"");
    try mem_vfs.vfs().writeFile("b.kup", "import \"./c.kup\"");
    try mem_vfs.vfs().writeFile("c.kup", "import \"./a.kup\"");

    const main_source = "import \"./a.kup\"";

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    vm.mute_errors = true;
    const res = vm.interpret(&out_chunk);

    // Sentinel must catch the cycle gracefully across arbitrary depth
    try testing.expect(res == .runtime_error or res == .execution_limit_exceeded);
}

test "VM: op_import supports cross-file class inheritance hierarchy" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // Base shape library
    const base_source =
        \\class Shape
        \\  def area
        \\    0
        \\  end
        \\end
        \\export Shape
    ;
    try mem_vfs.vfs().writeFile("shape.kup", base_source);

    // Child shape library extending imported base class
    const square_source =
        \\import { Shape } from "./shape.kup"
        \\class Square < Shape
        \\  def area
        \\    16
        \\  end
        \\end
        \\export Square
    ;
    try mem_vfs.vfs().writeFile("square.kup", square_source);

    const main_source =
        \\import { Square } from "./square.kup"
        \\sq = Square.new
        \\result = sq.area
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);

    const result_val = vm.globals.get("result") orelse return error.MissingResult;
    try testing.expectEqual(@as(f64, 16.0), result_val.asNumber());
}

test "VM: op_import supports barrel re-exports from multiple files" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    try mem_vfs.vfs().writeFile("part1.kup", "def val1()\n 10\nend\nexport val1");
    try mem_vfs.vfs().writeFile("part2.kup", "def val2()\n 20\nend\nexport val2");

    // Barrel index file bundling multiple sub-modules
    const index_source =
        \\import { val1 } from "./part1.kup"
        \\import { val2 } from "./part2.kup"
        \\export val1, val2
    ;
    try mem_vfs.vfs().writeFile("index.kup", index_source);

    const main_source =
        \\import { val1, val2 } from "./index.kup"
        \\result = val1 + val2
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);

    const result_val = vm.globals.get("result") orelse return error.MissingResult;
    try testing.expectEqual(@as(f64, 30.0), result_val.asNumber());
}

test "VM: op_import supports symbol aliasing via 'as'" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    try mem_vfs.vfs().writeFile("pkg.kup", "def val() 10 end\nexport val");

    const main_source =
        \\import { val as external_val } from "./pkg.kup"
        \\result = external_val
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);

    const result_val = vm.globals.get("result").?;
    try testing.expectEqual(@as(f64, 10.0), result_val.asNumber());
}

test "Compiler: op_import rejects symbol collisions" {
    const main_source =
        \\import { val } from "./a.kup"
        \\import { val } from "./b.kup"
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    // Compilation MUST fail natively with the new VariableAlreadyDeclared error
    const result = comp.compile(doc.tree.root);
    try testing.expectError(error.VariableAlreadyDeclared, result);
}

test "VM: op_import catches self-import cycles gracefully" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    // File imports itself
    try mem_vfs.vfs().writeFile("self.kup", "import \"./self.kup\"");

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, "import \"./self.kup\"");
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    vm.mute_errors = true;
    const res = vm.interpret(&out_chunk);

    // Sentinel stops infinite loop and evaluates to nil, cascading into a Circular Dependency RuntimeError
    try testing.expectEqual(.runtime_error, res);
}

test "VM: op_import supports aliased exports (export { internal as public })" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    const pkg_source =
        \\def internal_func() 42 end
        \\export { internal_func as public_func }
    ;
    try mem_vfs.vfs().writeFile("aliased_export.kup", pkg_source);

    const main_source =
        \\import { public_func } from "./aliased_export.kup"
        \\result = public_func
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);

    const result_val = vm.globals.get("result") orelse return error.MissingResult;
    try testing.expectEqual(@as(f64, 42.0), result_val.asNumber());
}

test "VM: op_import supports multiple aliases in a single import statement" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    const pkg_source =
        \\def fn_a() 10 end
        \\def fn_b() 20 end
        \\export fn_a, fn_b
    ;
    try mem_vfs.vfs().writeFile("multi_pkg.kup", pkg_source);

    const main_source =
        \\import { fn_a as x, fn_b as y } from "./multi_pkg.kup"
        \\result = x + y
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);

    const result_val = vm.globals.get("result") orelse return error.MissingResult;
    try testing.expectEqual(@as(f64, 30.0), result_val.asNumber());
}

test "Compiler: op_import rejects symbol collisions in top-level scope" {
    const main_source =
        \\local_var = 100
        \\import { val as local_var } from "./pkg.kup"
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();

    const result = comp.compile(doc.tree.root);
    try testing.expectError(error.VariableAlreadyDeclared, result);
}

test "VM: op_import supports chained aliased re-exports across modules" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();

    try mem_vfs.vfs().writeFile("base.kup", "def raw_val() 100 end\nexport raw_val");

    const pkg2_source =
        \\import { raw_val as middle_val } from "./base.kup"
        \\export { middle_val as final_val }
    ;
    try mem_vfs.vfs().writeFile("middle.kup", pkg2_source);

    const main_source =
        \\import { final_val } from "./middle.kup"
        \\result = final_val
    ;

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    const res = vm.interpret(&out_chunk);
    try testing.expectEqual(.ok, res);

    const result_val = vm.globals.get("result") orelse return error.MissingResult;
    try testing.expectEqual(@as(f64, 100.0), result_val.asNumber());
}

// --- op_import rooting, cache marking, chunk leak (Oct 2026 audit) ---

/// Parses + compiles `source` into `out_chunk` and interprets it.
fn compileAndRun(vm: *VM, out_chunk: *chunk.Chunk, source: []const u8) !InterpretResult {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);

    var comp = Compiler.forDocument(testing.allocator, &doc, out_chunk, vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
    return vm.interpret(out_chunk);
}

fn expectGlobalString(vm: *VM, name: []const u8, expected: []const u8) !void {
    const val = vm.globals.get(name) orelse return error.MissingGlobal;
    try testing.expect(val.isString());
    try testing.expectEqualStrings(expected, val.asString().chars);
}

test "VM: op_import cached module results survive GC and re-import" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    try mem_vfs.vfs().writeFile("mod.kup", "Payload = [\"payload\", \"more\"]\nexport Payload");

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.vfs = mem_vfs.vfs();
    vm.mute_errors = true;

    var first_chunk = chunk.Chunk.init();
    defer first_chunk.free(testing.allocator);
    // Stress GC also covers allocateClosure collecting the module's unrooted function
    vm.gc.stress = true;
    try testing.expectEqual(.ok, try compileAndRun(&vm, &first_chunk, "import \"./mod.kup\"\nnil"));

    // The export module is now referenced only by the import cache
    vm.gc.collectGarbage(&vm, false);
    vm.gc.stress = false;

    var second_chunk = chunk.Chunk.init();
    defer second_chunk.free(testing.allocator);
    try testing.expectEqual(.ok, try compileAndRun(&vm, &second_chunk, "import { Payload } from \"./mod.kup\"\nresult = Payload[0]"));
    try expectGlobalString(&vm, "result", "payload");
    // A cache hit, not a re-import: the key must not borrow the (swept) path constant
    try testing.expectEqual(@as(u32, 1), vm.modules.count());
}

test "VM: op_import exception raised inside an imported module is rescued by the importer" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    try mem_vfs.vfs().writeFile("boom.kup", "raise \"module failed\"");

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.vfs = mem_vfs.vfs();
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    // The `begin` sits at the import's stack slot, so a rescued unwind leaves exactly
    // one value above the module closure's base, the same shape as a normal return.
    // The import must still be seen as failed: not cached, and raising again when retried.
    const source =
        \\first = begin
        \\  import "./boom.kup"
        \\  "not rescued"
        \\rescue => e
        \\  e.message
        \\end
        \\second = begin
        \\  import "./boom.kup"
        \\  "served from cache"
        \\rescue => e
        \\  e.message
        \\end
        \\after = "continued"
    ;
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
    try expectGlobalString(&vm, "first", "module failed");
    try expectGlobalString(&vm, "second", "module failed");
    try expectGlobalString(&vm, "after", "continued");
    try testing.expectEqual(@as(u32, 0), vm.modules.count());
}

test "VM: op_import of a module that fails to compile does not leak its chunk" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    // Parses cleanly but fails to compile (assigning to the protected intrinsic `cube`)
    try mem_vfs.vfs().writeFile("bad.kup", "x = \"keep\"\ncube = 1");

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.vfs = mem_vfs.vfs();
    vm.mute_errors = true;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    const source =
        \\result = begin
        \\  import "./bad.kup"
        \\  "imported"
        \\rescue ImportError => e
        \\  e.message
        \\end
    ;
    // testing.allocator reports the heap chunk as leaked if it is not freed
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, source));
    const msg = vm.globals.get("result") orelse return error.MissingGlobal;
    try testing.expect(std.mem.startsWith(u8, msg.asString().chars, "could not compile 'bad.kup': "));
}

// --- Module isolation: each imported module has its own top-level scope ---

const ModuleFile = struct { path: []const u8, source: []const u8 };

/// Writes `files` into a fresh MemoryVfs, runs `main` and returns the number left in `r`.
fn runWithModules(files: []const ModuleFile, main: []const u8) !f64 {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    for (files) |f| try mem_vfs.vfs().writeFile(f.path, f.source);

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;
    vm.vfs = mem_vfs.vfs();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, main));
    const r = vm.globals.get("r") orelse return error.MissingGlobal;
    return r.asNumber();
}

test "VM: imported modules keep their top-level names to themselves" {
    // Before, every module wrote into the importer's globals: the importer could read a
    // library's private variables and silently change what the library computed.
    const cases = [_]struct { files: []const ModuleFile, main: []const u8, expected: f64 }{
        // The importer can't change a module's variable...
        .{ .files = &.{.{ .path = "lib.kup", .source = LIB_C }}, .main = "import { lib_fn } from \"./lib.kup\"\nc = 1000\nr = lib_fn()", .expected = 3 },
        // ...or see it, or the hidden __exports__ object.
        .{ .files = &.{.{ .path = "lib.kup", .source = LIB_C }}, .main = "import { lib_fn } from \"./lib.kup\"\nr = defined?(c) ? 1 : 0", .expected = 0 },
        .{ .files = &.{.{ .path = "lib.kup", .source = LIB_C }}, .main = "import { lib_fn } from \"./lib.kup\"\nr = defined?(__exports__) ? 1 : 0", .expected = 0 },
        // A module can't read the importer's variables either.
        .{ .files = &.{.{ .path = "w.kup", .source = "def get_width\n  width\nend\nexport get_width" }}, .main = "width = 7\nimport { get_width } from \"./w.kup\"\nr = begin\n  get_width()\nrescue => e\n  -1\nend", .expected = -1 },
        // Module functions see module variables defined later in the file.
        .{ .files = &.{.{ .path = "area.kup", .source = "def area\n  side * side\nend\nside = 4\nexport area" }}, .main = "side = 100\nimport { area } from \"./area.kup\"\nr = area()", .expected = 16 },
        // Methods of an exported class keep the module's scope when called from outside.
        .{ .files = &.{.{ .path = "plate.kup", .source = "k = 3\nclass Plate\n  def scaled(x)\n    x * k\n  end\nend\nexport Plate" }}, .main = "k = 50\nimport { Plate } from \"./plate.kup\"\nr = Plate.new.scaled(2)", .expected = 6 },
        // Two modules may use the same top-level name without clobbering each other.
        .{
            .files = &.{
                .{ .path = "a.kup", .source = "v = 1\ndef get_a\n  v\nend\nexport get_a" },
                .{ .path = "b.kup", .source = "v = 2\ndef get_b\n  v\nend\nexport get_b" },
            },
            .main = "import { get_a } from \"./a.kup\"\nimport { get_b } from \"./b.kup\"\nr = get_a() * 10 + get_b()",
            .expected = 12,
        },
        // Builtins stay reachable from module code.
        .{ .files = &.{.{ .path = "mk.kup", .source = "def make\n  cube(2).volume\nend\nexport make" }}, .main = "import { make } from \"./mk.kup\"\nr = make()", .expected = 8 },
        // A module importing another sees only what it imported, not the inner module's privates.
        .{
            .files = &.{
                .{ .path = "inner.kup", .source = "secret = 9\ndef twice(x)\n  x * 2\nend\nexport twice" },
                .{ .path = "outer.kup", .source = "import { twice } from \"./inner.kup\"\ndef go\n  r = twice(5)\n  r + (defined?(secret) ? 100 : 0)\nend\nexport go" },
            },
            .main = "import { go } from \"./outer.kup\"\nr = go()",
            .expected = 10,
        },
    };
    for (cases) |case| {
        errdefer std.debug.print("main:\n{s}\n", .{case.main});
        try testing.expectEqual(case.expected, try runWithModules(case.files, case.main));
    }
}

test "VM: a module still sees a builtin the main script shadowed" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    try mem_vfs.vfs().writeFile("lib.kup", "def read\n  helper_val\nend\nexport read");

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.vfs = mem_vfs.vfs();
    // A host-registered global, like the stdlib's builtins.
    try vm.globals.put(vm.allocator, "helper_val", value.Value.initNumber(42));

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, "helper_val = 5\nimport { read } from \"./lib.kup\"\nr = read() * 100 + helper_val"));
    const r = vm.globals.get("r") orelse return error.MissingGlobal;
    try testing.expectEqual(@as(f64, 4205), r.asNumber());
}

test "VM: module namespace values survive GC" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    try mem_vfs.vfs().writeFile("lib.kup", "s = \"str\" + \"ing\"\nparts = [s, s + \"!\"]\ndef get\n  parts[1]\nend\nexport get");

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.vfs = mem_vfs.vfs();
    // Collect on every allocation: values held only by a module namespace must be roots.
    vm.gc.stress = true;
    defer vm.gc.stress = false;

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    try testing.expectEqual(.ok, try compileAndRun(&vm, &out_chunk, "import { get } from \"./lib.kup\"\nx = [1, 2, 3].map { |i| i.to_s }\nr = get()"));
    try expectGlobalString(&vm, "r", "string!");
}

test "VM: importing a module that fails to compile names where and why" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    try mem_vfs.vfs().writeFile("bad.kup", "x = 1\ncube = 5\nexport x");

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();
    vm.mute_errors = true;
    try registry.registerStandardLibrary(&vm);

    const main_source =
        \\r = begin
        \\  import { x } from "./bad.kup"
        \\  "imported"
        \\rescue ImportError => e
        \\  e.message
        \\end
    ;
    var doc = try Document.parse(testing.allocator, main_source);
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
    try testing.expectEqual(.ok, vm.interpret(&out_chunk));

    // It used to say only "Compilation failed for './bad.kup'".
    const r = vm.globals.get("r") orelse return error.MissingResult;
    try testing.expectEqualStrings("could not compile 'bad.kup': 2:1: 'cube' is a built-in and can't be assigned", r.asString().chars);
}

test "VM: a relative import is read next to the file that imports it" {
    // Relative imports were read from the project root, so `kupcad build parts/main.kup`
    // couldn't import parts/hw.kup, and a module couldn't import its own neighbours.
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    try mem_vfs.vfs().writeFile("parts/hw.kup", "import { unit } from \"../lib/units.kup\"\ndef bolt\n  unit * 3\nend\nexport bolt");
    try mem_vfs.vfs().writeFile("lib/units.kup", "unit = 2\nexport unit");

    var vm = try VM.init(testing.allocator, testing.io);

    vm.host.compile_module = module_compiler.compileModule; // as the standard library registers it
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    vm.mute_errors = true;
    vm.vfs = mem_vfs.vfs();

    var doc = try Document.parse(testing.allocator, "import { bolt } from \"./hw.kup\"\nr = bolt()");
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    comp.module_path = "parts/main.kup";
    try comp.compile(doc.tree.root);
    try testing.expectEqual(.ok, vm.interpret(&out_chunk));
    try testing.expectEqual(@as(f64, 6), vm.globals.get("r").?.asNumber());
}

test "VM: a host that registered no module compiler refuses an import by name" {
    var mem_vfs = MemoryVfs.init(testing.allocator);
    defer mem_vfs.deinit();
    try mem_vfs.vfs().writeFile("lib.kup", "x = 1\n");
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.vfs = mem_vfs.vfs();
    vm.mute_errors = true;

    var doc = try Document.parse(testing.allocator, "import \"./lib.kup\"\n");
    defer doc.deinit();
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
    try testing.expectEqual(.runtime_error, vm.interpret(&out_chunk));
    // A bare VM has no error classes, so the kind reads as a RuntimeError; the words are the point.
    try testing.expect(std.mem.endsWith(u8, vm.last_error.?, "this host can't compile modules, so 'lib.kup' can't be imported"));
}
