const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const value = @import("../core/value.zig");
const common = @import("classes/common.zig");
const primitives = @import("primitives.zig");
const std_exceptions = @import("exceptions.zig");
const core_classes = @import("core_classes.zig");
const manifest = @import("manifest.zig");
const io_mod = @import("io.zig");
const diagnostics_mod = @import("diagnostics.zig");
const debug_mod = @import("debug.zig");
const object_mod = @import("classes/object.zig");
const params_mod = @import("params.zig");
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
    vm.workplane_class = try defineValueClass(vm, "Workplane");

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

    // I/O & Debugging
    try bindNativeClassMethod(vm, kernel_class, "puts", common.wrapGlobal(io_mod.nativePuts));
    try bindNativeClassMethod(vm, kernel_class, "print", common.wrapGlobal(io_mod.nativePrint));
    try bindNativeClassMethod(vm, kernel_class, "inspect", common.wrapGlobal(io_mod.nativeInspect));
    try bindNativeClassMethod(vm, kernel_class, "debugger", common.wrapGlobal(debug_mod.nativeDebugger));
    try bindNativeClassMethod(vm, kernel_class, "warn", common.wrapGlobal(diagnostics_mod.nativeWarn));
    try bindNativeClassMethod(vm, kernel_class, "assert", common.wrapGlobal(diagnostics_mod.nativeAssert));
    try bindNativeClassMethod(vm, kernel_class, "benchmark", common.wrapGlobal(diagnostics_mod.nativeBenchmark));
    try bindNativeClassMethod(vm, kernel_class, "param", common.wrapGlobal(params_mod.nativeParam));

    // Bind 3D Static Primitive Constructors to Solid
    try bindNativeClassMethod(vm, solid_class, "cube", common.wrapGlobal(primitives.nativeCube));
    try bindNativeClassMethod(vm, solid_class, "cylinder", common.wrapGlobal(primitives.nativeCylinder));
    try bindNativeClassMethod(vm, solid_class, "sphere", common.wrapGlobal(primitives.nativeSphere));
    try bindNativeClassMethod(vm, solid_class, "torus", common.wrapGlobal(primitives.nativeTorus));
    try bindNativeClassMethod(vm, solid_class, "polyhedron", common.wrapGlobal(primitives.nativePolyhedron));

    // Bind 2D Static Primitive Constructors to Sketch2D
    try bindNativeClassMethod(vm, sketch2d_class, "square", common.wrapGlobal(primitives.nativeSquare));
    try bindNativeClassMethod(vm, sketch2d_class, "circle", common.wrapGlobal(primitives.nativeCircle));
    try bindNativeClassMethod(vm, sketch2d_class, "polygon", common.wrapGlobal(primitives.nativePolygon));
    try bindNativeClassMethod(vm, sketch2d_class, "regular_polygon", common.wrapGlobal(primitives.nativeRegularPolygon));
    try bindNativeClassMethod(vm, sketch2d_class, "text", common.wrapGlobal(primitives.nativeText));

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
    const pi_name = try vm.allocateString("PI");
    try vm.setInstanceField(math_inst, pi_name, value.Value.initNumber(std.math.pi), null);
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
