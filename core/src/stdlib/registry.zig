const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const value = @import("../core/value.zig");
const common = @import("classes/common.zig");
const primitives = @import("primitives.zig");
const std_exceptions = @import("exceptions.zig");
const core_classes = @import("core_classes.zig");
const manifest = @import("manifest.zig");
const object_mod = @import("classes/object.zig");
const kernel = @import("../kernel/kernel.zig");

fn defaultPrintHandler(vm: *VM, message: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(vm.io, message) catch return;
}

// --- Bootstrap Helpers ---

fn defineBuiltinClass(vm: *VM, name: []const u8, superclass: ?*value.ObjClass) !*value.ObjClass {
    const name_str = try vm.gc.allocateString(vm, name);
    const class_obj = try vm.gc.allocateClass(vm, name_str, superclass);
    try vm.globals.put(vm.allocator, name, value.Value.initObj(&class_obj.obj));
    return class_obj;
}

/// A built-in kind of value (see ObjClass.is_value_class), under Object.
fn defineValueClass(vm: *VM, name: []const u8) !*value.ObjClass {
    const class = try defineBuiltinClass(vm, name, vm.object_class);
    class.is_value_class = true;
    return class;
}

/// A class's own `new`, named `display_name` in errors.
fn bindNew(vm: *VM, class: *value.ObjClass, display_name: []const u8, func: value.NativeFn) !void {
    const native_fn = try vm.gc.allocateNative(vm, display_name, func);
    try class.class_methods.put(vm.gc.trackingAllocator(), try vm.allocateString("new"), value.Value.initObj(&native_fn.obj));
}

fn bindNativeClassMethod(vm: *VM, class: *value.ObjClass, name: []const u8, func: value.NativeFn) !void {
    const native_fn = try vm.gc.allocateNative(vm, name, func);
    const name_val = try vm.allocateString(name);
    try class.class_methods.put(vm.gc.trackingAllocator(), name_val, value.Value.initObj(&native_fn.obj));
}

fn bindNativeMethod(vm: *VM, class: *value.ObjClass, name: []const u8, func: value.NativeFn) !void {
    const native_obj = try vm.gc.allocateNative(vm, name, func);
    const name_val = try vm.allocateString(name);
    try class.methods.put(vm.gc.trackingAllocator(), name_val, value.Value.initObj(&native_obj.obj));
}

// --- Standard Library Registration ---

pub fn registerStandardLibrary(vm: *VM) !void {
    // Bind Native Global Functions automatically from the manifest
    for (manifest.global_functions) |def| {
        try vm.defineNative(def.name, def.func);
    }

    // Object class
    vm.object_class = try defineBuiltinClass(vm, "Object", null);

    // Register Universal Object Protocol on Object root class
    for (object_mod.methods) |def| {
        try bindNativeMethod(vm, vm.object_class.?, def.name, def.func);
    }

    // Bootstrap Exception Hierarchy AFTER Object exists
    try std_exceptions.registerExceptions(vm);

    // Bootstrap Primitive Classes for Monkey-Patching
    vm.array_class = try defineValueClass(vm, "Array");
    vm.string_class = try defineValueClass(vm, "String");
    vm.map_class = try defineValueClass(vm, "Map");
    vm.number_class = try defineValueClass(vm, "Number");
    // Ruby's Float::INFINITY and Float::NAN. Arithmetic never produces them (it raises
    // RangeError or MathError), so a script reaching for one has to say so.
    try vm.number_class.?.class_fields.put(vm.gc.trackingAllocator(), try vm.allocateString("INFINITY"), value.Value.initNumber(std.math.inf(f64)));
    try vm.number_class.?.class_fields.put(vm.gc.trackingAllocator(), try vm.allocateString("NAN"), value.Value.initNumber(std.math.nan(f64)));
    // The gap between 1 and the next number, Ruby's Float::EPSILON: a scale for tolerances.
    try vm.number_class.?.class_fields.put(vm.gc.trackingAllocator(), try vm.allocateString("EPSILON"), value.Value.initNumber(std.math.floatEps(f64)));
    vm.range_class = try defineValueClass(vm, "Range");
    vm.symbol_class = try defineValueClass(vm, "Symbol");
    vm.boolean_class = try defineValueClass(vm, "Boolean");
    vm.bbox_class = try defineValueClass(vm, "BoundingBox");
    vm.geometry_class = try defineValueClass(vm, "Geometry");
    vm.cross_section_class = try defineValueClass(vm, "CrossSection");
    vm.nil_class = try defineValueClass(vm, "NilClass");
    vm.proc_class = try defineValueClass(vm, "Proc");
    vm.method_class = try defineValueClass(vm, "Method");
    vm.class_class = try defineValueClass(vm, "Class");
    vm.module_class = try defineValueClass(vm, "Module");
    vm.assembly_class = try defineValueClass(vm, "Assembly");
    // Workplane is hidden until the fluent sketching API exists (see manifest.zig, on_face);
    // its class stays unregistered, so the name is free for scripts.
    // vm.workplane_class = try defineValueClass(vm, "Workplane");

    // Array.new / String.new / Map.new build real empty values, as in Ruby.
    try bindNew(vm, vm.array_class.?, "Array.new", common.wrapMethod(@import("classes/array.zig").arrayNew));
    try bindNew(vm, vm.string_class.?, "String.new", common.wrapMethod(@import("classes/string.zig").stringNew));
    try bindNew(vm, vm.map_class.?, "Map.new", common.wrapMethod(@import("classes/map.zig").mapNew));

    // --- Formalize Kernel, Solid and Sketch2D Classes ---
    const kernel_class = try defineBuiltinClass(vm, "Kernel", vm.object_class);
    const solid_class = try defineBuiltinClass(vm, "Solid", vm.geometry_class);
    const sketch2d_class = try defineBuiltinClass(vm, "Sketch2D", vm.cross_section_class);
    // Shapes come from their constructors (Solid.cube, Sketch2D.square), not `.new`.
    solid_class.is_value_class = true;
    sketch2d_class.is_value_class = true;

    // Kernel.puts, Solid.cube, Sketch2D.square: the global functions, as class methods too.
    for (manifest.global_functions) |def| {
        const class = switch (def.category) {
            .io => kernel_class,
            .primitive_3d => solid_class,
            .primitive_2d => sketch2d_class,
            else => continue,
        };
        try bindNativeClassMethod(vm, class, def.name, def.func);
    }

    // Bind CAD methods natively to the classes
    for (manifest.mesh_methods) |def| {
        try bindNativeMethod(vm, vm.geometry_class.?, def.name, def.func);
        try bindNativeMethod(vm, vm.cross_section_class.?, def.name, def.func);
    }

    // Set up GC module (as an instance of a pseudo-class)
    const gc_class = try defineBuiltinClass(vm, "GC", vm.object_class);
    const gc_inst = try vm.gc.allocateInstance(vm, gc_class);
    try vm.globals.put(vm.allocator, "GC", value.Value.initObj(&gc_inst.obj));

    // Bootstrap Standard Modules
    // Set up Math module (as an instance of a pseudo-class to support property access)
    const math_class = try defineBuiltinClass(vm, "Math", vm.object_class);
    const math_inst = try vm.gc.allocateInstance(vm, math_class);
    const math_constants = [_]struct { []const u8, f64 }{ .{ "PI", std.math.pi }, .{ "TAU", std.math.tau }, .{ "E", std.math.e } };
    for (math_constants) |c| try vm.setInstanceField(math_inst, try vm.allocateString(c[0]), value.Value.initNumber(c[1]), null);
    try vm.globals.put(vm.allocator, "Math", value.Value.initObj(&math_inst.obj));

    // Set up CAD settings module (as a pseudo-class)
    const cad_module = try defineBuiltinClass(vm, "CAD", vm.object_class);
    const cad_inst = try vm.gc.allocateInstance(vm, cad_module);
    try vm.globals.put(vm.allocator, "CAD", value.Value.initObj(&cad_inst.obj));

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
