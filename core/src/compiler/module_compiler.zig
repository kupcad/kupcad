//! Compiles an imported module's source for the VM, which calls it through
//! `Host.compile_module` (the standard library registers it): parsing and compiling were in
//! the VM's `op_import`, so the VM imported the compiler and the compiler the VM.

const value = @import("../core/value.zig");
const chunk = @import("../vm/chunk.zig");
const VM = @import("../vm/vm.zig").VM;
const Document = @import("../core/document.zig").Document;
const Compiler = @import("compiler.zig").Compiler;

/// The bytecode of the module at `path` (its text is `source`), compiled into `namespace`,
/// the module's own top-level scope, and owned by the caller. A module that doesn't parse or
/// compile raises an ImportError and fails with error.RuntimeError, as a native does.
pub fn compileModule(vm: *VM, path: []const u8, source: []const u8, namespace: *value.Namespace) anyerror!*chunk.Chunk {
    var doc = Document.parse(vm.allocator, source) catch return vm.fail(.ImportError, "Parse error in '{s}'", .{path});
    defer doc.deinit();
    if (doc.diagnostics.len > 0) return vm.fail(.ImportError, "Syntax errors in '{s}'", .{path});

    const module_chunk = try vm.allocator.create(chunk.Chunk);
    module_chunk.* = chunk.Chunk.init();
    errdefer {
        module_chunk.free(vm.allocator);
        vm.allocator.destroy(module_chunk);
    }

    var comp = Compiler.forDocument(vm.allocator, &doc, module_chunk, vm);
    defer comp.deinit();
    comp.module_namespace = namespace;
    comp.module_path = path; // its own imports are its neighbours
    comp.compile(doc.tree.root) catch |err| {
        const where = if (comp.errorDiagnostic()) |d| d.formatLine(vm.allocator, &doc.line_index) catch null else null;
        defer if (where) |w| vm.allocator.free(w);
        return vm.fail(.ImportError, "could not compile '{s}': {s}", .{ path, where orelse @errorName(err) });
    };
    return module_chunk;
}
