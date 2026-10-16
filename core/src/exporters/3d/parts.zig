//! What a script's `export_stl`, `export_gltf` and `export_step` write: the receiver's
//! parts, evaluated. The three natives each collected them their own way (STL took only a
//! Solid, glTF an Array too, which no script can call it on).

const std = @import("std");
const value = @import("../../core/value.zig");
const VM = @import("../../vm/vm.zig").VM;
const geom = @import("../../kernel/geometry_handle.zig");
const util = @import("../../stdlib/methods/util.zig");

/// Appends the evaluated parts of `receiver`, a Solid (itself) or an Assembly (its Solids),
/// to `out`; `method` names the export in the error for anything else. Handles are
/// borrowed from the VM.
pub fn receiverParts(vm: *VM, receiver: value.Value, comptime method: []const u8, out: *std.ArrayListUnmanaged(geom.GeometryHandle)) !void {
    if (receiver.isGeometry()) return out.append(vm.allocator, try vm.ensureConcrete(receiver));
    if (!receiver.isAssembly()) return util.notDefinedFor(vm, method, receiver);
    for (receiver.asAssembly().parts.items.items) |part| try out.append(vm.allocator, try vm.ensureConcrete(part));
}
