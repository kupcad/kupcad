const VM = @import("../vm/vm.zig").VM;
const boolean = @import("boolean.zig");
const primitives = @import("primitives.zig");
const export_ops = @import("export.zig");

pub fn registerStandardLibrary(vm: *VM) !void {
    vm.binary_handler = boolean.csgBinaryHandler;

    try vm.defineNative("cube", primitives.nativeCube);
    try vm.defineNative("export_stl", export_ops.nativeExportStl);
}
