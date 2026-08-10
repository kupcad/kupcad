const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const boolean = @import("boolean.zig");
const methods = @import("methods.zig");
const manifest = @import("manifest.zig");

// Import the Manifold driver (In the future, a build flag will dynamically select OCCT)
const manifold_driver = @import("../kernel/engines/manifold/driver.zig").driver;

pub fn registerStandardLibrary(vm: *VM) !void {
    // 1. Bind Native Global Functions automatically from the manifest
    for (manifest.global_functions) |def| {
        try vm.defineNative(def.name, def.func);
    }

    // 2. Assign the Active Kernel Driver
    vm.active_kernel = &manifold_driver;

    // 3. Bind VM Hooks (Decoupling VM from CAD domain)
    vm.binary_handler = boolean.csgBinaryHandler;
    vm.invoke_handler = methods.cadInvokeHandler;

    // 4. The GC will directly call the active kernel's destruction routine.
    // Because GeometryHandle is passed by value, no ?*anyopaque wrappers are needed!
    vm.mesh_destructor = manifold_driver.destructFn;
}
