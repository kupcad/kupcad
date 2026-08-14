const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const value = @import("../core/value.zig");
const manifest = @import("manifest.zig");

// Import the Manifold driver (In the future, a build flag will dynamically select OCCT)
const manifold_driver = @import("../kernel/engines/manifold/driver.zig").driver;

fn defaultPrintHandler(vm: *VM, message: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(vm.io, message) catch {};
}

pub fn registerStandardLibrary(vm: *VM) !void {
    // Bind Native Global Functions automatically from the manifest
    for (manifest.global_functions) |def| {
        try vm.defineNative(def.name, def.func);
    }

    // Set up Math module (as an instance of a pseudo-class)
    const math_str = try vm.gc.allocateString(vm, "Math");
    const math_class = try vm.gc.allocateClass(vm, math_str, null);
    const math_inst = try vm.gc.allocateInstance(vm, math_class);

    // Add Math::PI
    const pi_val = value.Value.initNumber(std.math.pi);
    try math_inst.fields.put(vm.allocator, "PI", pi_val);

    // Inject into globals
    try vm.globals.put(vm.allocator, "Math", value.Value.initObj(&math_inst.obj));

    // Assign the Active Kernel Driver
    vm.active_kernel = &manifold_driver;

    // Bind Host Platform Interface Hooks
    vm.host = .{
        .binary_handler = manifest.cadBinaryHandler,
        .invoke_handler = manifest.cadInvokeHandler,
        .print_handler = defaultPrintHandler,
        .mesh_destructor = manifold_driver.destructFn,
    };
}
