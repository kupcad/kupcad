const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;

const array_class = @import("classes/array.zig");
const map_class = @import("classes/map.zig");
const string_class = @import("classes/string.zig");
const number_class = @import("classes/number.zig");
const symbol_class = @import("classes/symbol.zig");
const boolean_class = @import("classes/boolean.zig");
const bbox_class = @import("classes/bbox.zig");
const gc_class = @import("classes/gc.zig");
const math_class = @import("classes/math.zig");
const cad_class = @import("classes/cad.zig");

fn bindNativeMethod(vm: *VM, class: *value.ObjClass, name: []const u8, func: value.NativeFn) !void {
    const native_obj = try vm.gc.allocateNative(vm, func);
    const native_val = value.Value.initObj(&native_obj.obj);
    try class.methods.put(vm.allocator, name, native_val);
}

pub fn registerCoreClasses(vm: *VM) !void {
    if (vm.array_class) |cls| {
        for (array_class.methods) |def| try bindNativeMethod(vm, cls, def.name, def.func);
    }
    if (vm.map_class) |cls| {
        for (map_class.methods) |def| try bindNativeMethod(vm, cls, def.name, def.func);
    }
    if (vm.string_class) |cls| {
        for (string_class.methods) |def| try bindNativeMethod(vm, cls, def.name, def.func);
    }
    if (vm.number_class) |cls| {
        for (number_class.methods) |def| try bindNativeMethod(vm, cls, def.name, def.func);
    }
    if (vm.symbol_class) |cls| {
        for (symbol_class.methods) |def| try bindNativeMethod(vm, cls, def.name, def.func);
    }
    if (vm.boolean_class) |cls| {
        for (boolean_class.methods) |def| try bindNativeMethod(vm, cls, def.name, def.func);
    }
    if (vm.bbox_class) |cls| {
        for (bbox_class.methods) |def| try bindNativeMethod(vm, cls, def.name, def.func);
    }
    if (vm.globals.get("GC")) |v| {
        const gc_cls = v.asInstance().class;
        for (gc_class.methods) |def| try bindNativeMethod(vm, gc_cls, def.name, def.func);
    }
    if (vm.globals.get("Math")) |v| {
        const math_cls = v.asInstance().class;
        for (math_class.methods) |def| try bindNativeMethod(vm, math_cls, def.name, def.func);
    }
    if (vm.globals.get("CAD")) |v| {
        const cad_cls = v.asInstance().class;
        for (cad_class.methods) |def| try bindNativeMethod(vm, cad_cls, def.name, def.func);
    }
}
