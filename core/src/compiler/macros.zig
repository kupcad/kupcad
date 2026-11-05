//! The methods `attr_reader`, `attr_writer` and `attr_accessor` define: `emitAccessor` compiles
//! a getter or a setter of an instance variable as its own function and emits the bytecode
//! that binds it to the class. Called by `compiler.zig`.

const std = @import("std");
const chunk = @import("../vm/chunk.zig");
const value = @import("../core/value.zig");
const Compiler = @import("compiler.zig").Compiler;

/// What an accessor does with its instance variable.
pub const Accessor = enum {
    /// `def prop = @prop`
    reader,
    /// `def prop=(val) = @prop = val`
    writer,
};

/// Defines the `accessor` of the instance variable `prop_name` (`:width`, `"width"` or
/// `"@width"`) on the class being compiled, or on its singleton.
pub fn emitAccessor(comp: *Compiler, prop_name: []const u8, accessor: Accessor, is_singleton: bool) !void {
    const clean_name = std.mem.trimStart(u8, prop_name, ":@");
    // A setter's name was printed into a 256-byte buffer: a longer one failed as "out of
    // memory while compiling"
    const method_name = switch (accessor) {
        .reader => clean_name,
        .writer => try comp.allocator.print("{s}=", .{clean_name}),
    };
    defer if (accessor == .writer) comp.allocator.free(method_name);

    const func = try comp.vm.gc.allocateFunction(comp.vm);
    func.namespace = comp.rootModuleNamespace();
    // Root the function until it is stored in the constant pool: the name and
    // child-chunk constants allocated below can trigger a collection.
    comp.vm.ensureStackCapacity(comp.vm.stack_top + 1) catch return error.OutOfMemory;
    comp.vm.push(value.Value.initObj(&func.obj));
    var func_rooted = true;
    errdefer if (func_rooted) {
        _ = comp.vm.pop();
    };
    const arity: u8 = switch (accessor) {
        .reader => 0,
        .writer => 1,
    };
    func.arity = arity;
    func.owns_chunk = true;

    const child_chunk = try comp.allocator.create(chunk.Chunk);
    child_chunk.* = chunk.Chunk.init();
    func.chunk = child_chunk;

    const str_val = try comp.vm.allocateString(method_name);
    func.name = str_val.asString();

    var child_comp = @TypeOf(comp.*).init(comp.allocator, comp.tree, comp.symbols, comp.token_starts, child_chunk, comp.vm);
    defer child_comp.deinit();
    child_comp.current_source_offset = comp.current_source_offset;

    // Slot 0 is self, a setter's value comes next, and the implicit block slot last
    const local_count = @as(u16, arity) + 2;
    for (0..local_count) |slot| try child_comp.addLocal(.none, @intCast(slot));
    func.local_count = local_count;

    try child_comp.emitOpWithOperand(.op_get_local, .op_get_local_wide, 0);
    const prop_idx = try child_comp.makeStringConstant(clean_name);
    switch (accessor) {
        .reader => try child_comp.emitOpWithOperand(.op_get_ivar, .op_get_ivar_wide, prop_idx),
        .writer => {
            try child_comp.emitOpWithOperand(.op_get_local, .op_get_local_wide, 1);
            try child_comp.emitOpWithOperand(.op_set_property, .op_set_property_wide, prop_idx);
        },
    }
    try child_comp.emitInlineCacheIndex();
    try child_comp.emitOp(.op_return);

    child_chunk.max_stack_slots = local_count;

    const func_val = value.Value.initObj(&func.obj);
    const func_idx = try comp.makeConstant(func_val);
    _ = comp.vm.pop();
    func_rooted = false;
    try comp.emitOpWithOperand(.op_closure, .op_closure_wide, func_idx);

    const meth_name_idx = try comp.makeStringConstant(method_name);
    const meth_op: chunk.OpCode = if (is_singleton) .op_class_method else .op_method;
    const meth_wide_op: chunk.OpCode = if (is_singleton) .op_class_method_wide else .op_method_wide;
    try comp.emitOpWithOperand(meth_op, meth_wide_op, meth_name_idx);
}
