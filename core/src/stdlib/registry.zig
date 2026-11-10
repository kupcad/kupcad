//! `registerStandardLibrary`: sets up a VM's built-in environment: the global functions of
//! `manifest.zig`, the `Object` class and its methods, the exceptions, the value classes,
//! the shapes (`Shape`, and `Solid`, `Sketch` and `Path` under it), `Kernel`, the `GC`, `Math`
//! and `CAD` objects, `params`, and the host hooks.

const std = @import("std");
const vm_mod = @import("../vm/vm.zig");
const VM = vm_mod.VM;
const BuiltinClass = vm_mod.BuiltinClass;
const value = @import("../core/value.zig");
const common = @import("classes/common.zig");
const std_exceptions = @import("exceptions.zig");
const core_classes = @import("core_classes.zig");
const manifest = @import("manifest.zig");
const object_mod = @import("classes/object.zig");
const array_class_mod = @import("classes/array.zig");
const string_class_mod = @import("classes/string.zig");
const map_class_mod = @import("classes/map.zig");
const random_class_mod = @import("classes/random.zig");
const kernel = @import("../kernel/kernel.zig");
const module_compiler = @import("../compiler/module_compiler.zig");
const log = @import("../log.zig");

/// What the script prints goes to stderr through log.zig, as every other print there does,
/// so the CLI's progress line comes off first instead of the two garbling each other.
fn defaultPrintHandler(vm: *VM, message: []const u8) void {
    log.writeStderr(vm.io, message);
}

/// What a preview's run prints is kept in its report, for its frame (the console beside the
/// model), not written where no one reads it (a language server's worker's stderr); so is a
/// run's whose host asks (api.RunSetup.keep_output).
pub fn keepPrinted(vm: *VM, message: []const u8) void {
    vm.report.addOutput(vm.allocator, message) catch return;
}

// --- Bootstrap Helpers ---

fn defineBuiltinClass(vm: *VM, name: []const u8, superclass: ?*value.ObjClass) !*value.ObjClass {
    const name_str = try vm.gc.internStatic(vm, name);
    const class_obj = try vm.gc.allocateClass(vm, name_str, superclass);
    try vm.setGlobal(name, value.Value.initObj(&class_obj.obj));
    return class_obj;
}

/// A class of built-in values (see ObjClass.is_value_class), under `superclass`.
fn defineValueClass(vm: *VM, name: []const u8, superclass: ?*value.ObjClass) !*value.ObjClass {
    const class = try defineBuiltinClass(vm, name, superclass);
    class.is_value_class = true;
    return class;
}

/// The class of the kind of value `kind`, under `superclass`, kept as its class (VM.classes).
fn defineKindClass(vm: *VM, kind: BuiltinClass, superclass: ?*value.ObjClass) !*value.ObjClass {
    const class = try defineValueClass(vm, kind.scriptName(), superclass);
    vm.classes.set(kind, class);
    return class;
}

/// A class's own `new`, named `display_name` in errors.
fn bindNew(vm: *VM, class: *value.ObjClass, display_name: []const u8, func: value.NativeFn) !void {
    const native_fn = try vm.gc.allocateNative(display_name, func);
    try class.class_methods.put(vm.gc.trackingAllocator(), try vm.staticString("new"), value.Value.initObj(&native_fn.obj));
}

fn bindNativeClassMethod(vm: *VM, class: *value.ObjClass, name: []const u8, func: value.NativeFn) !void {
    const native_fn = try vm.gc.allocateNative(name, func);
    const name_val = try vm.staticString(name);
    try class.class_methods.put(vm.gc.trackingAllocator(), name_val, value.Value.initObj(&native_fn.obj));
}

fn bindNativeMethod(vm: *VM, class: *value.ObjClass, name: []const u8, func: value.NativeFn) !void {
    const native_obj = try vm.gc.allocateNative(name, func);
    const name_val = try vm.staticString(name);
    try class.methods.put(vm.gc.trackingAllocator(), name_val, value.Value.initObj(&native_obj.obj));
}

// --- Standard Library Registration ---

pub fn registerStandardLibrary(vm: *VM) !void {
    // Bind Native Global Functions automatically from the manifest
    for (manifest.global_functions) |def| {
        try vm.defineNative(def.name, def.func);
    }

    // Object class
    const object = try defineBuiltinClass(vm, BuiltinClass.object.scriptName(), null);
    vm.classes.set(.object, object);

    // Register Universal Object Protocol on Object root class
    for (object_mod.methods) |def| {
        try bindNativeMethod(vm, object, def.name, def.func);
    }

    // Bootstrap Exception Hierarchy AFTER Object exists
    try std_exceptions.registerExceptions(vm);

    // Bootstrap Primitive Classes for Monkey-Patching
    for ([_]BuiltinClass{ .array, .string, .map, .json_object, .font, .random, .range, .symbol, .boolean, .bbox, .nil, .proc, .method, .class, .module, .assembly }) |kind| {
        _ = try defineKindClass(vm, kind, object);
    }
    const number = try defineKindClass(vm, .number, object);
    // Ruby's Float::INFINITY and Float::NAN. Arithmetic never produces them (it raises
    // RangeError or MathError), so a script reaching for one has to say so.
    try number.class_fields.put(vm.gc.trackingAllocator(), try vm.staticString("INFINITY"), value.Value.initNumber(std.math.inf(f64)));
    try number.class_fields.put(vm.gc.trackingAllocator(), try vm.staticString("NAN"), value.Value.initNumber(std.math.nan(f64)));
    // The gap between 1 and the next number, Ruby's Float::EPSILON: a scale for tolerances.
    try number.class_fields.put(vm.gc.trackingAllocator(), try vm.staticString("EPSILON"), value.Value.initNumber(std.math.floatEps(f64)));
    // The shapes: each made by its constructors (cube, square, line), none by `.new`
    const shape_class = try defineValueClass(vm, "Shape", object);
    for ([_]BuiltinClass{ .solid, .sketch, .path }) |kind| _ = try defineKindClass(vm, kind, shape_class);
    // Workplane is hidden until the fluent sketching API exists (see manifest.zig, on_face);
    // its class stays unregistered, so the name is free for scripts.

    // Array.new / String.new / Map.new build real empty values, as in Ruby.
    try bindNew(vm, vm.classes.get(.array).?, "Array.new", common.wrapMethod(array_class_mod.arrayNew));
    try bindNew(vm, vm.classes.get(.string).?, "String.new", common.wrapMethod(string_class_mod.stringNew));
    try bindNew(vm, vm.classes.get(.map).?, "Map.new", common.wrapMethod(map_class_mod.mapNew));
    try bindNew(vm, vm.classes.get(.random).?, "Random.new", common.wrapMethod(random_class_mod.randomNew));

    const kernel_class = try defineBuiltinClass(vm, "Kernel", object);

    // Kernel.puts, Solid.cube, Sketch.square, Path.line: the global functions, as class
    // methods too.
    for (manifest.global_functions) |def| {
        const class = switch (def.category) {
            .io => kernel_class,
            .primitive_3d => vm.classes.get(.solid).?,
            .primitive_2d => vm.classes.get(.sketch).?,
            .primitive_path => vm.classes.get(.path).?,
            else => continue,
        };
        try bindNativeClassMethod(vm, class, def.name, def.func);
    }

    // Bind CAD methods natively to the classes
    try vm.classes.get(.solid).?.methods.ensureUnusedCapacity(vm.gc.trackingAllocator(), manifest.mesh_methods.len);
    try vm.classes.get(.sketch).?.methods.ensureUnusedCapacity(vm.gc.trackingAllocator(), manifest.mesh_methods.len);
    try vm.classes.get(.assembly).?.methods.ensureUnusedCapacity(vm.gc.trackingAllocator(), manifest.assembly_methods.len);
    for (manifest.assembly_methods) |def| try bindNativeMethod(vm, vm.classes.get(.assembly).?, def.name, def.func);
    try vm.classes.get(.path).?.methods.ensureUnusedCapacity(vm.gc.trackingAllocator(), manifest.path_methods.len);
    for (manifest.path_methods) |def| try bindNativeMethod(vm, vm.classes.get(.path).?, def.name, def.func);
    for (manifest.mesh_methods) |def| {
        if (def.isOn(.solids)) try bindNativeMethod(vm, vm.classes.get(.solid).?, def.name, def.func);
        if (def.isOn(.sketches)) try bindNativeMethod(vm, vm.classes.get(.sketch).?, def.name, def.func);
    }

    // Set up GC module (as an instance of a pseudo-class)
    const gc_class = try defineBuiltinClass(vm, "GC", object);
    const gc_inst = try vm.gc.allocateInstance(vm, gc_class);
    try vm.setGlobal("GC", value.Value.initObj(&gc_inst.obj));

    // Bootstrap Standard Modules
    // Set up Math module (as an instance of a pseudo-class to support property access)
    const math_class = try defineBuiltinClass(vm, "Math", object);
    const math_inst = try vm.gc.allocateInstance(vm, math_class);
    const math_constants = [_]struct { []const u8, f64 }{ .{ "PI", std.math.pi }, .{ "TAU", std.math.tau }, .{ "E", std.math.e } };
    for (math_constants) |c| try vm.setInstanceField(math_inst, try vm.staticString(c[0]), value.Value.initNumber(c[1]), null);
    try vm.setGlobal("Math", value.Value.initObj(&math_inst.obj));

    // Set up CAD settings module (as a pseudo-class)
    const cad_module = try defineBuiltinClass(vm, "CAD", object);
    const cad_inst = try vm.gc.allocateInstance(vm, cad_module);
    try vm.setGlobal("CAD", value.Value.initObj(&cad_inst.obj));

    // Initialize the empty Global Parameters Map for CLI injection
    const params_map = try vm.gc.allocateMap(vm);
    try vm.setGlobal("params", value.Value.initObj(&params_map.obj));

    // Bind Core Class Methods Natively
    try core_classes.registerCoreClasses(vm);

    // Bind Host Platform Interface Hooks
    vm.host = .{
        .binary_handler = manifest.cadBinaryHandler,
        .missing_method_hint = manifest.missingMethodHint,
        .print_handler = if (vm.previewing) keepPrinted else defaultPrintHandler,
        .mesh_destructor = kernel.destruct,
        .compile_module = module_compiler.compileModule,
    };
}
