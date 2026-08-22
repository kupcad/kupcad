const std = @import("std");
const chunk = @import("../vm/chunk.zig");
const value = @import("../core/value.zig");

pub fn emitAttrReader(comp: anytype, prop_name: []const u8, is_singleton: bool) !void {
    const clean_name = std.mem.trimStart(u8, prop_name, ":@");

    const func = try comp.vm.gc.allocateFunction(comp.vm);
    func.arity = 0;
    func.owns_chunk = true;

    const child_chunk = try comp.allocator.create(chunk.Chunk);
    child_chunk.* = chunk.Chunk.init();
    func.chunk = child_chunk;

    const str_val = try comp.vm.allocateString(clean_name);
    func.name = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", str_val.asObj())));

    var child_comp = @TypeOf(comp.*).init(comp.allocator, comp.tree, comp.symbols, comp.token_starts, child_chunk, comp.vm);
    defer child_comp.deinit();
    child_comp.current_source_offset = comp.current_source_offset;

    try child_comp.addLocal(.none, 0); // Slot 0: self
    try child_comp.addLocal(.none, 1); // Slot 1: implicit block slot
    func.local_count = 2;

    // --- Generate Bytecode: def prop() @prop end ---
    try child_comp.emitOpWithOperand(.op_get_local, .op_get_local_wide, 0);
    const prop_idx = try child_comp.makeStringConstant(clean_name);
    try child_comp.emitOpWithOperand(.op_get_property, .op_get_property_wide, prop_idx);
    try child_comp.emitInlineCacheIndex();
    try child_comp.emitOp(.op_return);

    child_chunk.max_stack_slots = 2;

    const func_val = value.Value.initObj(&func.obj);
    const func_idx = try comp.makeConstant(func_val);
    try comp.emitOpWithOperand(.op_closure, .op_closure_wide, func_idx);

    const meth_name_idx = try comp.makeStringConstant(clean_name);
    const meth_op: chunk.OpCode = if (is_singleton) .op_class_method else .op_method;
    const meth_wide_op: chunk.OpCode = if (is_singleton) .op_class_method_wide else .op_method_wide;
    try comp.emitOpWithOperand(meth_op, meth_wide_op, meth_name_idx);
}

pub fn emitAttrWriter(comp: anytype, prop_name: []const u8, is_singleton: bool) !void {
    const clean_name = std.mem.trimStart(u8, prop_name, ":@");

    const func = try comp.vm.gc.allocateFunction(comp.vm);
    func.arity = 1;
    func.owns_chunk = true;

    const child_chunk = try comp.allocator.create(chunk.Chunk);
    child_chunk.* = chunk.Chunk.init();
    func.chunk = child_chunk;

    // Fixed 256-byte stack buffer, explicitly casting NoSpaceLeft into OutOfMemory
    var name_buf: [256]u8 = undefined;
    const setter_name = std.fmt.bufPrint(&name_buf, "{s}=", .{clean_name}) catch return error.OutOfMemory;

    const str_val = try comp.vm.allocateString(setter_name);
    func.name = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", str_val.asObj())));

    var child_comp = @TypeOf(comp.*).init(comp.allocator, comp.tree, comp.symbols, comp.token_starts, child_chunk, comp.vm);
    defer child_comp.deinit();
    child_comp.current_source_offset = comp.current_source_offset;

    try child_comp.addLocal(.none, 0); // Slot 0: self
    try child_comp.addLocal(.none, 1); // Slot 1: val
    try child_comp.addLocal(.none, 2); // Slot 2: implicit block slot
    func.local_count = 3;

    // --- Generate Bytecode: def prop=(val) @prop = val end ---
    try child_comp.emitOpWithOperand(.op_get_local, .op_get_local_wide, 0);
    try child_comp.emitOpWithOperand(.op_get_local, .op_get_local_wide, 1);
    const prop_idx = try child_comp.makeStringConstant(clean_name);

    try child_comp.emitOpWithOperand(.op_set_property, .op_set_property_wide, prop_idx);
    try child_comp.emitInlineCacheIndex();
    try child_comp.emitOp(.op_return);

    child_chunk.max_stack_slots = 3;

    const func_val = value.Value.initObj(&func.obj);
    const func_idx = try comp.makeConstant(func_val);
    try comp.emitOpWithOperand(.op_closure, .op_closure_wide, func_idx);

    const meth_name_idx = try comp.makeStringConstant(setter_name);
    const meth_op: chunk.OpCode = if (is_singleton) .op_class_method else .op_method;
    const meth_wide_op: chunk.OpCode = if (is_singleton) .op_class_method_wide else .op_method_wide;
    try comp.emitOpWithOperand(meth_op, meth_wide_op, meth_name_idx);
}
