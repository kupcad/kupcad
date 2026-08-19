const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const value = @import("../core/value.zig");
const std_exceptions = @import("exceptions.zig");
const core_classes = @import("core_classes.zig");
const manifest = @import("manifest.zig");
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

// --- Standard Library Registration ---

pub fn registerStandardLibrary(vm: *VM) !void {
    // Bind Native Global Functions automatically from the manifest
    for (manifest.global_functions) |def| {
        try vm.defineNative(def.name, def.func);
    }

    // Bootstrap Exception Hierarchy
    try std_exceptions.registerExceptions(vm);

    // Bootstrap Primitive Classes for Monkey-Patching
    vm.array_class = try defineBuiltinClass(vm, "Array", null);
    vm.string_class = try defineBuiltinClass(vm, "String", null);
    vm.map_class = try defineBuiltinClass(vm, "Map", null);
    vm.number_class = try defineBuiltinClass(vm, "Number", null);
    vm.symbol_class = try defineBuiltinClass(vm, "Symbol", null);
    vm.boolean_class = try defineBuiltinClass(vm, "Boolean", null);
    vm.bbox_class = try defineBuiltinClass(vm, "BoundingBox", null);

    // Bootstrap Standard Modules
    // Set up Math module (as an instance of a pseudo-class to support property access)
    const math_class = try defineBuiltinClass(vm, "Math", null);
    const math_inst = try vm.gc.allocateInstance(vm, math_class);
    try vm.setInstanceField(math_inst, "PI", value.Value.initNumber(std.math.pi));
    try vm.globals.put(vm.allocator, "Math", value.Value.initObj(&math_inst.obj));

    // Bind Core Class Methods Natively
    try core_classes.registerCoreClasses(vm);

    // Global params
    const params_map = try vm.gc.allocateMap(vm);
    try vm.globals.put(vm.allocator, "params", value.Value.initObj(&params_map.obj));

    // Bind Host Platform Interface Hooks
    vm.host = .{
        .binary_handler = manifest.cadBinaryHandler,
        .invoke_handler = manifest.cadInvokeHandler,
        .print_handler = defaultPrintHandler,
        .mesh_destructor = kernel.destruct,
    };
}
