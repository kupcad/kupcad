const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const value = @import("../core/value.zig");
const std_exceptions = @import("exceptions.zig");
const core_classes = @import("core_classes.zig");
const manifest = @import("manifest.zig");
const object_mod = @import("classes/object.zig");
const kernel = @import("../kernel/kernel.zig");

fn defaultPrintHandler(vm: *VM, message: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(vm.io, message) catch {};
}

// --- Bootstrap Helpers ---

fn defineBuiltinClass(vm: *VM, name: []const u8, superclass: ?*value.ObjClass) !*value.ObjClass {
    const name_str = try vm.gc.allocateString(vm, name);
    const class_obj = try vm.gc.allocateClass(vm, name_str, superclass);
    try vm.globals.put(vm.allocator, name, value.Value.initObj(&class_obj.obj));
    return class_obj;
}

fn bindNativeMethod(vm: *VM, class: *value.ObjClass, name: []const u8, func: value.NativeFn) !void {
    const native_obj = try vm.gc.allocateNative(vm, func);
    try class.methods.put(vm.allocator, name, value.Value.initObj(&native_obj.obj));
}

// --- Standard Library Registration ---

pub fn registerStandardLibrary(vm: *VM) !void {
    // Bind Native Global Functions automatically from the manifest
    for (manifest.global_functions) |def| {
        try vm.defineNative(def.name, def.func);
    }

    // Bootstrap Exception Hierarchy
    try std_exceptions.registerExceptions(vm);

    // Object class
    vm.object_class = try defineBuiltinClass(vm, "Object", null);

    // Register Universal Object Protocol on Object root class
    for (object_mod.methods) |def| {
        try bindNativeMethod(vm, vm.object_class.?, def.name, def.func);
    }

    // Bootstrap Primitive Classes for Monkey-Patching
    vm.array_class = try defineBuiltinClass(vm, "Array", vm.object_class);
    vm.string_class = try defineBuiltinClass(vm, "String", vm.object_class);
    vm.map_class = try defineBuiltinClass(vm, "Map", vm.object_class);
    vm.number_class = try defineBuiltinClass(vm, "Number", vm.object_class);
    vm.symbol_class = try defineBuiltinClass(vm, "Symbol", vm.object_class);
    vm.boolean_class = try defineBuiltinClass(vm, "Boolean", vm.object_class);
    vm.bbox_class = try defineBuiltinClass(vm, "BoundingBox", vm.object_class);

    // Set up GC module (as an instance of a pseudo-class)
    const gc_class = try defineBuiltinClass(vm, "GC", null);
    const gc_inst = try vm.gc.allocateInstance(vm, gc_class);
    try vm.globals.put(vm.allocator, "GC", value.Value.initObj(&gc_inst.obj));

    // Bootstrap Standard Modules
    // Set up Math module (as an instance of a pseudo-class to support property access)
    const math_class = try defineBuiltinClass(vm, "Math", null);
    const math_inst = try vm.gc.allocateInstance(vm, math_class);
    try vm.setInstanceField(math_inst, "PI", value.Value.initNumber(std.math.pi));
    try vm.globals.put(vm.allocator, "Math", value.Value.initObj(&math_inst.obj));

    // Initialize the empty Global Parameters Map for CLI injection
    const params_map = try vm.gc.allocateMap(vm);
    try vm.globals.put(vm.allocator, "params", value.Value.initObj(&params_map.obj));

    // Bind Core Class Methods Natively
    try core_classes.registerCoreClasses(vm);

    // Bind Host Platform Interface Hooks
    vm.host = .{
        .binary_handler = manifest.cadBinaryHandler,
        .invoke_handler = manifest.cadInvokeHandler,
        .print_handler = defaultPrintHandler,
        .mesh_destructor = kernel.destruct,
    };
}
