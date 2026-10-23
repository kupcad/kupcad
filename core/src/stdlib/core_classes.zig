//! `registerCoreClasses`: binds the native methods of the built-in classes (Array, Map,
//! JsonObject, String, Number, Range, Symbol, Boolean, BoundingBox, Font) and of the `GC`,
//! `Math` and `CAD` objects, from the method tables under `classes/`.

const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;

const array_class = @import("classes/array.zig");
const map_class = @import("classes/map.zig");
const json_object_class = @import("classes/json_object.zig");
const string_class = @import("classes/string.zig");
const number_class = @import("classes/number.zig");
const range_class = @import("classes/range.zig");
const symbol_class = @import("classes/symbol.zig");
const boolean_class = @import("classes/boolean.zig");
const bbox_class = @import("classes/bbox.zig");
const font_class = @import("classes/font.zig");
const random_class = @import("classes/random.zig");
const gc_class = @import("classes/gc.zig");
const math_class = @import("classes/math.zig");
const cad_class = @import("classes/cad.zig");
const common = @import("classes/common.zig");

/// Binds `defs` as methods of `class`. Errors name each one `prefix ++ name`, such as
/// "String#split" or "Math.sin".
fn bindMethods(vm: *VM, class: *value.ObjClass, comptime prefix: []const u8, comptime defs: []const common.MethodDef) !void {
    try class.methods.ensureUnusedCapacity(vm.gc.trackingAllocator(), defs.len);
    inline for (defs) |def| {
        const native_obj = try vm.gc.allocateNative(prefix ++ def.name, def.func);
        const name_val = try vm.staticString(def.name);
        try class.methods.put(vm.gc.trackingAllocator(), name_val, value.Value.initObj(&native_obj.obj));
    }
}

pub fn registerCoreClasses(vm: *VM) !void {
    if (vm.array_class) |cls| try bindMethods(vm, cls, "Array#", &array_class.methods);
    if (vm.map_class) |cls| try bindMethods(vm, cls, "Map#", &map_class.methods);
    if (vm.json_object_class) |cls| try bindMethods(vm, cls, "JsonObject#", &json_object_class.methods);
    if (vm.string_class) |cls| try bindMethods(vm, cls, "String#", &string_class.methods);
    if (vm.number_class) |cls| try bindMethods(vm, cls, "Number#", &number_class.methods);
    if (vm.range_class) |cls| try bindMethods(vm, cls, "Range#", &range_class.methods);
    if (vm.symbol_class) |cls| try bindMethods(vm, cls, "Symbol#", &symbol_class.methods);
    if (vm.boolean_class) |cls| try bindMethods(vm, cls, "Boolean#", &boolean_class.methods);
    if (vm.bbox_class) |cls| try bindMethods(vm, cls, "BoundingBox#", &bbox_class.methods);
    if (vm.font_class) |cls| try bindMethods(vm, cls, "Font#", &font_class.methods);
    if (vm.random_class) |cls| try bindMethods(vm, cls, "Random#", &random_class.methods);
    if (vm.globals.get("GC")) |v| try bindMethods(vm, v.asInstance().class, "GC.", &gc_class.methods);
    if (vm.globals.get("Math")) |v| try bindMethods(vm, v.asInstance().class, "Math.", &math_class.methods);
    if (vm.globals.get("CAD")) |v| try bindMethods(vm, v.asInstance().class, "CAD.", &cad_class.methods);
}
