const VM = @import("../vm/vm.zig").VM;
const boolean = @import("boolean.zig");
const methods = @import("methods.zig");
const manifold = @import("../bindings/manifold/manifold.zig");
const manifest = @import("manifest.zig");

// Wrapper function for the GC destructor hook
fn manifoldDestructorWrapper(handle: ?*anyopaque) void {
    if (handle) |h| {
        manifold.destruct(@ptrCast(h));
    }
}

pub fn registerStandardLibrary(vm: *VM) !void {
    // 1. Bind Native Global Functions automatically from the manifest
    for (manifest.global_functions) |def| {
        try vm.defineNative(def.name, def.func);
    }

    // 2. Bind VM Hooks (Decoupling VM from CAD domain)
    vm.binary_handler = boolean.csgBinaryHandler;
    vm.invoke_handler = methods.cadInvokeHandler;
    vm.mesh_destructor = manifoldDestructorWrapper;
}
