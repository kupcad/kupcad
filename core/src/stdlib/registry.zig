const VM = @import("../vm/vm.zig").VM;
const primitives = @import("primitives.zig");
const export_ops = @import("export.zig");

pub fn registerStandardLibrary(vm: *VM) !void {
    try vm.defineNative("cube", primitives.nativeCube);
    try vm.defineNative("export_stl", export_ops.nativeExportStl);
}
