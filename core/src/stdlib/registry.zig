const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const value = @import("../core/value.zig");
const core_classes = @import("core_classes.zig");
const manifest = @import("manifest.zig");

// Import the Manifold driver (In the future, a build flag will dynamically select OCCT)
const manifold_driver = @import("../kernel/engines/manifold/driver.zig").driver;

fn defaultPrintHandler(vm: *VM, message: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(vm.io, message) catch {};
}

// --- Bootstrap Helpers ---

fn defineBuiltinClass(vm: *VM, name: []const u8, superclass: ?*value.ObjClass) !*value.ObjClass {
    const name_str = try vm.gc.allocateString(vm, name);
    const class_obj = try vm.gc.allocateClass(vm, name_str, superclass);
    try vm.globals.put(vm.allocator, name, value.Value.initObj(&class_obj.obj));
    return class_obj;
}

// --- Standard Library Registration ---

pub fn registerStandardLibrary(vm: *VM) !void {
    // Bind Native Global Functions automatically from the manifest
    for (manifest.global_functions) |def| {
        try vm.defineNative(def.name, def.func);
    }

    // Bootstrap Exception Hierarchy
    const std_err_class = try defineBuiltinClass(vm, "StandardError", null);
    _ = try defineBuiltinClass(vm, "ArgumentError", std_err_class);
    _ = try defineBuiltinClass(vm, "TypeError", std_err_class);

    // Bootstrap Primitive Classes for Monkey-Patching
    vm.array_class = try defineBuiltinClass(vm, "Array", null);
    vm.string_class = try defineBuiltinClass(vm, "String", null);
    vm.map_class = try defineBuiltinClass(vm, "Map", null);
    vm.number_class = try defineBuiltinClass(vm, "Number", null);

    // Bootstrap Standard Modules
    // Set up Math module (as an instance of a pseudo-class to support property access)
    const math_class = try defineBuiltinClass(vm, "Math", null);
    const math_inst = try vm.gc.allocateInstance(vm, math_class);
    try math_inst.fields.put(vm.allocator, "PI", value.Value.initNumber(std.math.pi));
    try vm.globals.put(vm.allocator, "Math", value.Value.initObj(&math_inst.obj));

    // Bind Core Class Methods Natively
    try core_classes.registerCoreClasses(vm);

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
