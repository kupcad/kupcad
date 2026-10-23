//! `import_stl`: a mesh file's Solid, in millimetres, its mesh a polyhedron node of the
//! geometry graph. The reader is exporters/3d/stl.zig.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const stl = @import("../exporters/3d/stl.zig");
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
