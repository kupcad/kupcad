const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const boolean = @import("boolean.zig");
const methods = @import("methods.zig");
const manifest = @import("manifest.zig");

// Import the Manifold driver (In the future, a build flag will dynamically select OCCT)
const manifold_driver = @import("../kernel/engines/manifold/driver.zig").driver;

pub fn registerStandardLibrary(vm: *VM) !void {
    // Bind Native Global Functions automatically from the manifest
    for (manifest.global_functions) |def| {
        try vm.defineNative(def.name, def.func);
    }

    // Assign the Active Kernel Driver
    vm.active_kernel = &manifold_driver;

    // Bind Host Platform Interface Hooks
    vm.host = .{
        .binary_handler = boolean.csgBinaryHandler,
        .invoke_handler = methods.cadInvokeHandler,
        .mesh_destructor = manifold_driver.destructFn,
    };
}
