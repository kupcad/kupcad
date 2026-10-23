//! `import_stl` and `import_obj`: a mesh file's Solid, in millimetres, each mesh in it (an
//! OBJ's objects) a polyhedron node of the geometry graph, united. The readers are
//! exporters/3d/stl.zig and obj_read.zig.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const stl = @import("../exporters/3d/stl.zig");
const obj_read = @import("../exporters/3d/obj_read.zig");
const Diagnostic = @import("../exporters/diagnostic.zig").Diagnostic;
const file_import = @import("file_import.zig");

/// import_stl(path): the Solid of the STL file's triangles, binary or ASCII. What
/// `import logo from "./logo.stl"` calls.
pub fn nativeImportStl(vm: *VM, path: []const u8) !value.Value {
    const file = try file_import.read(vm, path, "STL", null);
    defer vm.allocator.free(file);
    const mesh = stl.parseStlBuffer(vm.allocator, file) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return vm.fail(.ImportError, "could not parse STL file '{s}': {s}", .{ path, @errorName(err) });
    };
    defer mesh.deinit(vm.allocator);
    return vm.allocateGeometry(.{ .symbolic = try vm.dag_builder.addPolyhedron(mesh.points, mesh.faces) });
}

/// import_obj(path): the Solid of the OBJ file's faces, each object (`o`) a mesh, united.
/// What `import bracket from "./bracket.obj"` calls.
pub fn nativeImportObj(vm: *VM, path: []const u8) !value.Value {
    const file = try file_import.read(vm, path, "OBJ", null);
    defer vm.allocator.free(file);
    var diag: Diagnostic = .{};
    var model = obj_read.read(vm.allocator, file, &diag) catch |err| return file_import.unreadable(vm, err, path, "OBJ", &diag);
    defer model.deinit();
    const nodes = try vm.allocator.alloc(u32, model.objects.len);
    defer vm.allocator.free(nodes);
    for (model.objects, nodes) |object, *node| node.* = try vm.dag_builder.addPolyhedron(object.mesh.points, object.mesh.faces);
    return vm.allocateGeometry(.{ .symbolic = try vm.dag_builder.addBalancedChain(.union_op, nodes) });
}
