//! The methods `attr_reader`, `attr_writer` and `attr_accessor` define: `emitAccessor` compiles
//! a getter or a setter of an instance variable as its own function and emits the bytecode
//! that binds it to the class. Called by `compiler.zig`. The shape of a test block,
//! `test("name") do ... end`, is told here too (`isTestForm`, `testName`, `hasTestBlocks`),
//! for the compiler and for `kupcad test`, which looks for files holding one.

const std = @import("std");
const ast = @import("../core/ast.zig");
const chunk = @import("../vm/chunk.zig");
const value = @import("../core/value.zig");
const Compiler = @import("compiler.zig").Compiler;

/// What a test block looks like, for the error that one doesn't.
pub const TEST_FORM_HELP = "a test takes its name as a string literal and a block without parameters: test(\"name\") do ... end";

/// Whether `node` is a call of `test` with a block and no receiver: a test block, or an
/// attempt at one (`testName` tells which).
pub fn isTestForm(tree: *const ast.Tree, node: *const ast.Node) bool {
    if (node.tag != .method_call) return false;
    const mc = tree.methodCall(node);
    return mc.receiver == .none and mc.block != .none and std.mem.eql(u8, tree.getString(mc.method_name), "test");
}

/// The name of the test block `node` (isTestForm): its one argument, a plain string
/// literal, with a block that takes no parameters; null for any other shape.
pub fn testName(tree: *const ast.Tree, node: *const ast.Node) ?[]const u8 {
    const mc = tree.methodCall(node);
    const args = tree.getNamedArgs(mc.args);
    if (args.len != 1 or args[0].name != .none or args[0].modifier != null) return null;
    const arg = tree.getNode(args[0].value) orelse return null;
    if (arg.tag != .string) return null;
    const block = tree.block(tree.getNode(mc.block).?);
    if (block.params.start != block.params.end) return null;
    return tree.getString(tree.stringId(arg));
}

/// The block node of the test block `node` (isTestForm).
pub fn testBody(tree: *const ast.Tree, node: *const ast.Node) ast.NodeIndex {
    return tree.methodCall(node).block;
}

/// Whether the file's top level holds a test block (or an attempt at one, which fails to
/// compile: `kupcad test` runs the file to say so).
pub fn hasTestBlocks(tree: *const ast.Tree) bool {
    for (topLevel(tree)) |stmt_idx| {
        if (tree.getNode(stmt_idx)) |stmt| if (isTestForm(tree, stmt)) return true;
    }
    return false;
}

/// A well-formed test block of a file's top level: its name, and the token its `test` is.
pub const TestBlock = struct { name: []const u8, token: u32 };

/// The well-formed test blocks of the file's top level, in order (an editor's run buttons).
pub fn testBlocks(allocator: std.mem.Allocator, tree: *const ast.Tree) ![]TestBlock {
    var found: std.ArrayList(TestBlock) = .empty;
    errdefer found.deinit(allocator);
    for (topLevel(tree)) |stmt_idx| {
        const stmt = tree.getNode(stmt_idx) orelse continue;
        if (!isTestForm(tree, stmt)) continue;
        const name = testName(tree, stmt) orelse continue;
        try found.append(allocator, .{ .name = name, .token = stmt.main_token });
    }
    return found.toOwnedSlice(allocator);
}

/// The statements of the file's top level.
fn topLevel(tree: *const ast.Tree) []const ast.NodeIndex {
    const root = tree.getNode(tree.root) orelse return &.{};
    if (root.tag != .block) return &.{};
    return tree.getNodes(tree.block(root).stmts);
}

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
