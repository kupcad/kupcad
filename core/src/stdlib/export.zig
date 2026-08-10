const std = @import("std");
const value = @import("../core/value.zig");
const stl = @import("../core/stl.zig");
const VM = @import("../vm/vm.zig").VM;

pub fn nativeExportStl(vm_opaque: *anyopaque, arg_count: u8, args: [*]value.Value) anyerror!value.Value {
    const self: *VM = @ptrCast(@alignCast(vm_opaque));
    if (arg_count != 2) {
        std.log.err("export_stl expects exactly 2 arguments (filename, mesh)\n", .{});
        return error.RuntimeError;
    }
    if (!args[0].isString() or !args[1].isMesh()) {
        std.log.err("export_stl arguments must be (String, Mesh)\n", .{});
        return error.RuntimeError;
    }

    const filename = args[0].asString();
    const mesh = args[1].asMesh();

    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();

    stl.write(mesh, &out.writer) catch |err| {
        std.log.err("Error writing to STL buffer: {}\n", .{err});
        return error.RuntimeError;
    };

    self.cwd.writeFile(self.io, .{
        .sub_path = filename,
        .data = out.written(),
    }) catch |err| {
        std.log.err("Could not write STL file '{s}': {}\n", .{ filename, err });
        return error.RuntimeError;
    };

    return args[1];
}
