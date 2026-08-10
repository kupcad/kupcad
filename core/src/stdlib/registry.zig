const VM = @import("../vm/vm.zig").VM;
const boolean = @import("boolean.zig");
const primitives = @import("primitives.zig");
const export_ops = @import("export.zig");
const methods = @import("methods.zig");
const manifold = @import("../bindings/manifold/manifold.zig");

// Wrapper function for the GC destructor hook
fn manifoldDestructorWrapper(handle: ?*anyopaque) void {
    if (handle) |h| {
        manifold.destruct(@ptrCast(h));
    }
}

pub fn registerStandardLibrary(vm: *VM) !void {
    // Bind Native Global Functions
    try vm.defineNative("cube", primitives.nativeCube);
    try vm.defineNative("export_stl", export_ops.nativeExportStl);

    // Bind VM Hooks (Decoupling VM from CAD domain)
    vm.binary_handler = boolean.csgBinaryHandler;
    vm.invoke_handler = methods.cadInvokeHandler;
    vm.mesh_destructor = manifoldDestructorWrapper;
}
