const std = @import("std");
const macros = @import("macros.zig");
const ast = @import("../core/ast.zig");
const chunk = @import("../vm/chunk.zig");
const value = @import("../core/value.zig");
const limits = @import("../core/limits.zig");
const common_errors = @import("../core/errors.zig");
const resolver = @import("../core/resolver.zig");
const verifier = @import("../vm/verifier.zig");
const VM = @import("../vm/vm.zig").VM;
const manifest = @import("../stdlib/manifest.zig");
const scope_mod = @import("scope.zig");
const emitter_mod = @import("emitter.zig");

const DEFAULT_IMPORT_ENDPOINT = "main.kup";

/// True for a name that can become a function-local: not `@ivar`, `@@cvar`,
/// `$global` or a Constant, which `classifyStorage` routes by their first char.
fn isPlainLocalName(name: []const u8) bool {
    if (name.len == 0) return false;
    return name[0] != '@' and name[0] != '$' and !std.ascii.isUpper(name[0]);
}

pub const CompileError = error{
    /// A call passed two blocks (`f(&b) { ... }`), or `yield` was given one.
    UnexpectedBlock,
    OutOfMemory,
    UnknownNode,
    TooManyConstants,
    TooManyLocals,
    TooManyArguments,
    UnsupportedScope,
    ProtectedSymbol,
    CorruptedBytecode,
    VariableAlreadyDeclared,
    AstTooDeep,
    TooManyParameters,
    TooManyInlineCaches,
};

/// Room for a compile error message such as "'cube' is a built-in and can't be assigned".
const MAX_FAILURE_MESSAGE_LEN = 192;

/// The first error of a failed compile: where it happened and what went wrong, for callers
/// to report like a syntax error (Compiler.errorDiagnostic). Before, they could only print
/// the error name, such as "error.ProtectedSymbol".
pub const CompileFailure = struct {
    /// Byte offset of the node being compiled.
    offset: u32,
    buf: [MAX_FAILURE_MESSAGE_LEN]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const CompileFailure) []const u8 {
        return self.buf[0..self.len];
    }
};

/// What a compile error means to the script's author, when its raise site didn't say more.
fn describeError(err: CompileError) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory while compiling",
        error.TooManyConstants => "this function has too many constants (literals and names); split it up",
        error.TooManyLocals => std.fmt.comptimePrint("too many variables in one function (at most {d}, and {d} captured from outside)", .{ limits.MAX_LOCALS, limits.MAX_UPVALUES }),
        error.TooManyArguments => std.fmt.comptimePrint("a call takes at most {d} arguments", .{limits.MAX_ARGS}),
        error.TooManyParameters => std.fmt.comptimePrint("a function takes at most {d} parameters", .{limits.MAX_ARGS}),
        error.TooManyInlineCaches => std.fmt.comptimePrint("too many method calls in one script (at most {d})", .{limits.MAX_INLINE_CACHES}),
        error.AstTooDeep => "the code is nested too deeply",
        error.UnexpectedBlock => "a call takes one block: a &block argument or a do/{ } block, not both",
        error.ProtectedSymbol => "a built-in name can't be redefined",
        error.VariableAlreadyDeclared => "this name is already defined",
        error.UnknownNode, error.UnsupportedScope, error.CorruptedBytecode => "internal compiler error",
    };
}

/// How many values a call pushed for its arguments, and how (see chunk.CallFlags).
const CallArgs = struct {
    count: usize,
    flags: chunk.CallFlags = .{},
};

pub const Upvalue = scope_mod.Upvalue;
pub const Local = scope_mod.Local;
pub const LoopState = scope_mod.LoopState;
pub const UnwindEntry = scope_mod.UnwindEntry;

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    tree: *const ast.Tree,

    // Track script globals purely by String Slice to decouple from AST integer IDs
    script_globals: std.StringHashMapUnmanaged(void) = .empty,
    imported_symbols: std.StringHashMapUnmanaged(void) = .empty,

    symbols: []const resolver.ResolvedSymbol,
    token_starts: []const u32, // Map AST nodes back to Lexer byte offsets
    current_source_offset: u32, // Implictly passed to Chunk
    current_chunk: *chunk.Chunk,
    vm: *VM,

    /// Set on the root compiler when compiling fails (see CompileFailure).
    failure: ?CompileFailure = null,

    // Lexical Scope Tracking
    enclosing: ?*Compiler = null,
    function: ?*value.ObjFunction = null,
    is_method: bool = false,
    /// Set (on the root compiler) when compiling an imported module: every function
    /// compiled for it resolves globals in the module's own namespace.
    module_namespace: ?*value.Namespace = null,
    active_namespaces: usize = 0,
    has_export_module: bool = false,
    // Lexical Scope tracking
    namespace_stack: std.ArrayListUnmanaged(ast.StringId) = .empty,

    upvalues: std.ArrayListUnmanaged(Upvalue) = .empty,
    locals: std.ArrayListUnmanaged(Local) = .empty,
    loops: std.ArrayListUnmanaged(LoopState) = .empty,
    // Enclosing rescue/ensure regions of the current function, innermost last
    unwind_stack: std.ArrayListUnmanaged(UnwindEntry) = .empty,

    // --- DOD Zero-Waste Compilation Buffers ---
    scratch_ops: std.ArrayListUnmanaged(ast.BinaryOp) = .empty,
    scratch_rights: std.ArrayListUnmanaged(ast.NodeIndex) = .empty,

    current_stack_depth: usize = 0,
    max_stack_depth: usize = 0,
    max_local_slot: usize = 0,
    ast_depth: usize = 0, // Tracks absolute recursion depth

    seeded_locals: []const []const u8 = &.{},
    seeded_slot_offset: u16 = 0,

    // Hidden frame slot that emitVariableStore parks a value in to reorder the
    // stack; allocated on first use, once per function.
    scratch_slot: ?u16 = null,

    // --- Mixin Forwarding (Decoupled Modules) ---
    pub const classifyVariable = scope_mod.classifyVariable;
    pub const buildFullyQualifiedPath = scope_mod.buildFullyQualifiedPath;
    pub const addLocal = scope_mod.addLocal;
    pub const resolveLocal = scope_mod.resolveLocal;
    pub const resolveUpvalue = scope_mod.resolveUpvalue;
    pub const resolveSelfUpvalue = scope_mod.resolveSelfUpvalue;
    pub const addUpvalue = scope_mod.addUpvalue;
    pub const isScriptGlobal = scope_mod.isScriptGlobal;
    pub const insideDef = scope_mod.insideDef;
    pub const writesScriptGlobal = scope_mod.writesScriptGlobal;

    /// The namespace of the module being compiled (null for the main script).
    pub fn rootModuleNamespace(self: *const Compiler) ?*value.Namespace {
        var root = self;
        while (root.enclosing) |parent| root = parent;
        return root.module_namespace;
    }
    pub const seedLocals = scope_mod.seedLocals;
    pub const getNextLocalSlot = scope_mod.getNextLocalSlot;

    pub const JumpTableOffsets = emitter_mod.JumpTableOffsets;
    pub const emitJumpTable = emitter_mod.emitJumpTable;
    pub const simulatePush = emitter_mod.simulatePush;
    pub const simulatePop = emitter_mod.simulatePop;
    pub const emitInlineCacheIndex = emitter_mod.emitInlineCacheIndex;
    pub const emitByte = emitter_mod.emitByte;
    pub const emitOp = emitter_mod.emitOp;
    pub const emitBinaryOp = emitter_mod.emitBinaryOp;
    pub const makeConstant = emitter_mod.makeConstant;
    pub const emitConstant = emitter_mod.emitConstant;
    pub const emitJump = emitter_mod.emitJump;
    pub const patchJump = emitter_mod.patchJump;
    pub const emitLoop = emitter_mod.emitLoop;
    pub const makeMethodNameConstant = emitter_mod.makeMethodNameConstant;
    pub const makeStringConstant = emitter_mod.makeStringConstant;
    pub const makeSymbolConstant = emitter_mod.makeSymbolConstant;
    pub const emitOpWithOperand = emitter_mod.emitOpWithOperand;
    pub const writeJumpOffset = emitter_mod.writeJumpOffset;

    pub fn init(
        allocator: std.mem.Allocator,
        tree: *const ast.Tree,
        symbols: []const resolver.ResolvedSymbol,
        token_starts: []const u32,
        output_chunk: *chunk.Chunk,
        vm: *VM,
    ) Compiler {
        return .{
            .allocator = allocator,
            .tree = tree,
            .script_globals = .empty,
            .imported_symbols = .empty,
            .symbols = symbols,
            .token_starts = token_starts,
            .current_chunk = output_chunk,
            .vm = vm,
            .enclosing = null,
            .function = null,
            .is_method = false,
            .has_export_module = false,
            .namespace_stack = .empty,
            .upvalues = .empty,
            .locals = .empty,
            .loops = .empty,
            .scratch_ops = .empty,
            .scratch_rights = .empty,
            .current_stack_depth = 0,
            .max_stack_depth = 0,
            .ast_depth = 0,
            .current_source_offset = 0,
            .max_local_slot = 0,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.upvalues.deinit(self.allocator);
        self.script_globals.deinit(self.allocator);
        self.imported_symbols.deinit(self.allocator);
        self.locals.deinit(self.allocator);
        for (self.loops.items) |*loop| {
            loop.exit_jumps.deinit(self.allocator);
        }
        self.loops.deinit(self.allocator);
        self.unwind_stack.deinit(self.allocator);
        self.scratch_ops.deinit(self.allocator);
        self.scratch_rights.deinit(self.allocator);
        self.namespace_stack.deinit(self.allocator);
    }

    // --- Compilation Engine ---

    pub fn compile(self: *Compiler, root: ast.NodeIndex) CompileError!void {
        self.compileRoot(root) catch |err| return self.fail(err, "{s}", .{describeError(err)});
    }

    /// The first compile error as a diagnostic (its message lives as long as the compiler).
    pub fn errorDiagnostic(self: *const Compiler) ?common_errors.Diagnostic {
        const failure = if (self.failure) |*f| f else return null;
        return .{ .loc = .{ .offset = failure.offset, .length = 1, .file_id = 0 }, .message = failure.message() };
    }

    /// Records the first compile error (on the root compiler, which the caller holds) and
    /// returns `err`. Later ones are fallout of the first as it propagates.
    fn fail(self: *Compiler, err: CompileError, comptime fmt: []const u8, args: anytype) CompileError {
        var root = self;
        while (root.enclosing) |outer| root = outer;
        if (root.failure == null) {
            var failure: CompileFailure = .{ .offset = self.current_source_offset };
            // A message too long for the buffer (a huge name) falls back to the generic one.
            const msg = std.fmt.bufPrint(&failure.buf, fmt, args) catch
                std.fmt.bufPrint(&failure.buf, "{s}", .{describeError(err)}) catch unreachable;
            failure.len = msg.len;
            root.failure = failure;
        }
        return err;
    }

    fn compileRoot(self: *Compiler, root: ast.NodeIndex) CompileError!void {
        if (root == .none) {
            try self.emitOp(.op_nil);
        } else {
            try self.compileNode(root);
        }
        try self.emitOp(.op_return);
        self.current_chunk.max_stack_slots = self.max_stack_depth;
        self.current_chunk.local_count = @max(self.locals.items.len, self.max_local_slot + 1);

        // Verify bytecode integrity before allowing execution. Only the root verifies: it
        // checks every nested function's chunk too, knowing its locals and upvalues, which a
        // child compiler can't (its function's counts are set after its body compiles).
        if (self.enclosing == null) {
            verifier.verifyChunk(self.current_chunk) catch return error.CorruptedBytecode;
        }
    }

    /// Compiles one node; an error is recorded at the innermost node it came from (at that
    /// node's own position, even if it was raised after compiling its children).
    fn compileNode(self: *Compiler, node_idx: ast.NodeIndex) CompileError!void {
        const node_offset = if (self.tree.getNode(node_idx)) |node|
            (if (node.main_token < self.token_starts.len) self.token_starts[node.main_token] else self.current_source_offset)
        else
            self.current_source_offset;
        self.compileNodeAt(node_idx) catch |err| {
            self.current_source_offset = node_offset;
            return self.fail(err, "{s}", .{describeError(err)});
        };
    }

    // --- The Lean Routing Table ---
    fn compileNodeAt(self: *Compiler, node_idx: ast.NodeIndex) CompileError!void {
        if (node_idx == .none) return;

        // AST Depth Breaker. The parser bounds tree depth already, but trees can be
        // built programmatically and wrapper nodes (def -> begin -> block) add levels
        // the parser doesn't count, so this must be a real error, not an assert.
        if (self.ast_depth >= limits.MAX_AST_DEPTH) return error.AstTooDeep;
        self.ast_depth += 1;
        defer self.ast_depth -= 1;

        // Track where we started
        const expected_entry_depth = self.current_stack_depth;

        const node = self.tree.getNode(node_idx) orelse return error.UnknownNode;

        if (node.main_token < self.token_starts.len) {
            self.current_source_offset = self.token_starts[node.main_token];
        }

        switch (node.tag) {
            // Primitives
            .number => {
                const val = self.tree.number(node);
                try self.emitConstant(value.Value.initNumber(val));
            },
            .string => {
                const str_content = self.tree.getString(self.tree.stringId(node));
                const str_idx = try self.makeStringConstant(str_content);
                try self.emitOpWithOperand(.op_constant, .op_constant_wide, str_idx);
            },
            .symbol => {
                const sym_str = self.tree.getString(self.tree.stringId(node));
                const sym_idx = try self.makeSymbolConstant(sym_str);
                try self.emitOpWithOperand(.op_constant, .op_constant_wide, sym_idx);
            },
            .boolean => {
                const val = self.tree.boolean(node);
                if (val) try self.emitOp(.op_true) else try self.emitOp(.op_false);
            },
            .undef => try self.emitOp(.op_nil),

            // Extracted Node Handlers
            .identifier => try self.compileIdentifier(node, node_idx),
            .singleton_class => try self.compileSingletonClass(node),
            .return_stmt => try self.compileReturnStmt(node),
            .next_stmt => try self.compileNextStmt(node),
            .break_stmt => try self.compileBreakStmt(node),
            .assignment => try self.compileAssignment(node, node_idx),
            .rescue_modifier => try self.compileRescueModifier(node, expected_entry_depth),
            .namespace_access => try self.compileNamespaceAccess(node),
            .import_stmt => try self.compileImportStmt(node),
            .export_stmt => try self.compileExportStmt(node),
            .def_stmt, .lambda_expr => try self.compileDefStmt(node, node_idx),
            .index_access => try self.compileIndexAccess(node),
            .index_assignment => try self.compileIndexAssignment(node),
            .unary_op => try self.compileUnaryOp(node),
            .binary_op => try self.compileBinaryOp(node_idx),
            .array_literal => try self.compileArrayLiteral(node),
            .hash_literal => try self.compileHashLiteral(node),
            .case_stmt => try self.compileCaseStmt(node, expected_entry_depth),
            .begin_stmt => try self.compileBeginStmt(node, expected_entry_depth),
            .method_call => try self.compileMethodCall(node),
            .if_stmt => try self.compileIfStmt(node, expected_entry_depth),
            .self_expr => try self.emitPushSelf(),
            .while_stmt => try self.compileWhileStmt(node, expected_entry_depth),
            .ternary_op => try self.compileTernaryOp(node, expected_entry_depth),
            .range => try self.compileRange(node),
            .interpolated_string => try self.compileInterpolatedString(node),
            .multiple_assignment => try self.compileMultipleAssignment(node),
            .class_stmt => try self.compileClassStmt(node, node_idx),
            .module_stmt => try self.compileModuleStmt(node),
            .super_call => try self.compileSuperCall(node),
            .property_assignment => try self.compilePropertyAssignment(node),
            .defined_expr => try self.compileDefinedExpr(node),
            .block => try self.compileBlock(node),

            else => {
                try self.emitOp(.op_nil); // Push dummy value for unknown AST nodes
            },
        }

        // Every compiled node is an expression in KupCAD.
        // It MUST result in exactly ONE net value pushed to the stack
        if (node.tag != .return_stmt and node.tag != .break_stmt and node.tag != .next_stmt and node.tag != .class_stmt and node.tag != .module_stmt) {
            std.debug.assert(self.current_stack_depth == expected_entry_depth + 1);
        }
    }

    // --- AST Node Compilers ---

    fn compileIdentifier(self: *Compiler, node: *const ast.Node, node_idx: ast.NodeIndex) CompileError!void {
        // Ensure the Resolver properly mapped this node
        std.debug.assert(@backingInt(node_idx) < self.symbols.len);

        const sym = self.symbols[@backingInt(node_idx)];
        const name_id = self.tree.stringId(node);
        const name_str = self.tree.getString(name_id);

        // `block_given?` without parentheses is the intrinsic too (it used to be looked up
        // as a variable: NameError). The other intrinsics need arguments, or (`yield`)
        // parse as a statement.
        if (manifest.compiler_intrinsics.get(name_str) == .block_given_chk) {
            try self.emitOp(.op_block_given);
            return;
        }

        const is_local = (self.resolveLocal(name_id) != null) or
            (sym.kind == .local);
        const is_upvalue = (try self.resolveUpvalue(name_id)) != null;
        const is_script_global = self.isScriptGlobal(name_id);

        // Check the VM's active runtime memory for REPL
        const vm_global = self.vm.globals.get(name_str);

        const is_special_or_const = name_str.len == 0 or
            std.mem.startsWith(u8, name_str, "@") or
            std.mem.startsWith(u8, name_str, "$") or
            std.ascii.isUpper(name_str[0]);

        // A built-in function is called by name like a def, so a bare `cube` is `cube()`
        // (unless a script variable shadows it). Other VM globals are variables.
        const is_script_variable = is_local or is_upvalue or is_script_global;
        const is_builtin_function = !is_script_variable and !is_special_or_const and vm_global != null and vm_global.?.isNative();
        const is_variable = !is_builtin_function and (is_script_variable or is_special_or_const or vm_global != null);

        if (!is_variable) {
            // Bare identifier that is not a known variable or constant:
            // In Ruby/KupCAD, this is a 0-argument function/method invocation!
            const name_idx = try self.makeStringConstant(name_str);
            try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, name_idx);
            try self.emitCall(.op_call, .{ .count = 0 });
            self.simulatePop(1); // Consumes function pointer
            self.simulatePush(1); // Pushes function return value
        } else {
            try self.emitVariableLoad(name_id, sym);
        }
    }

    fn compileSingletonClass(self: *Compiler, node: *const ast.Node) CompileError!void {
        const sc = self.tree.singletonClassPayload(node);
        const target_node = self.tree.getNode(sc.target).?;

        // If `self` is referenced at the root level of a class/module definition,
        // the namespace object is already sitting at the top of the stack baseline!
        if (target_node.tag == .self_expr and self.enclosing == null and self.active_namespaces > 0) {
            try self.emitOp(.op_dup);
        } else {
            try self.compileNode(sc.target);
        }

        const body_node = self.tree.getNode(sc.body).?;
        const block_payload = self.tree.block(body_node);
        const stmts = self.tree.getNodes(block_payload.stmts);

        // Compile entire body as singleton methods
        try self.compileNamespaceBody(stmts, true);

        // Stack equilibrium: The target remains on the stack as the expression's return value
    }

    fn compileReturnStmt(self: *Compiler, node: *const ast.Node) CompileError!void {
        const ret_idx = self.tree.nodeIndex(node);
        if (ret_idx != .none) {
            try self.compileNode(ret_idx);
        } else {
            try self.emitOp(.op_nil);
        }
        // Leaving the function: every rescue/ensure region in this frame is exited
        try self.emitUnwind(0);
        try self.emitOp(.op_return);
        self.simulatePush(1); // Equilibrium for dead code
    }

    /// Emits the cleanup for every unwind region above `target_len`, innermost
    /// first: `op_pop_rescue` for active handlers and an inline copy of each
    /// `ensure` body. The value being returned/broken with stays on the stack.
    fn emitUnwind(self: *Compiler, target_len: usize) CompileError!void {
        if (self.unwind_stack.items.len <= target_len) return;

        // Snapshot the regions being exited: compiling an inline ensure body may
        // push/pop its own entries and would otherwise clobber the ones above it.
        const exited = try self.allocator.dupe(UnwindEntry, self.unwind_stack.items[target_len..]);
        defer self.allocator.free(exited);
        defer {
            self.unwind_stack.shrinkRetainingCapacity(target_len);
            self.unwind_stack.appendSliceAssumeCapacity(exited);
        }

        var i = exited.len;
        while (i > 0) {
            i -= 1;
            switch (exited[i]) {
                .rescue_handler => try self.emitOp(.op_pop_rescue),
                .ensure_body => |body| {
                    // Compile the ensure body as if we were already outside its
                    // region, so a jump inside it doesn't re-run it recursively.
                    self.unwind_stack.shrinkRetainingCapacity(target_len);
                    try self.unwind_stack.appendSlice(self.allocator, exited[0..i]);
                    try self.compileNode(body);
                    try self.emitOp(.op_pop); // discard ensure block output
                },
            }
        }
    }

    fn compileNextStmt(self: *Compiler, node: *const ast.Node) CompileError!void {
        const next_idx = self.tree.nodeIndex(node);
        if (next_idx != .none) {
            try self.compileNode(next_idx);
        } else {
            try self.emitOp(.op_nil);
        }
        if (self.loops.items.len > 0) {
            try self.emitOp(.op_pop);
            const cur_loop = self.loops.items[self.loops.items.len - 1];

            if (self.current_stack_depth > cur_loop.depth) return error.UnsupportedScope;

            try self.emitUnwind(cur_loop.unwind_depth);
            try self.emitLoop(cur_loop.start);
            self.simulatePush(1);
        } else if (self.enclosing != null or self.function != null) {
            try self.emitUnwind(0);
            try self.emitOp(.op_return);
            self.simulatePush(1);
        } else {
            return error.UnknownNode;
        }
    }

    fn compileBreakStmt(self: *Compiler, node: *const ast.Node) CompileError!void {
        const break_idx = self.tree.nodeIndex(node);
        if (break_idx != .none) {
            try self.compileNode(break_idx);
        } else {
            try self.emitOp(.op_nil);
        }
        if (self.loops.items.len > 0) {
            const loop_idx = self.loops.items.len - 1;
            if (self.current_stack_depth > self.loops.items[loop_idx].depth + 1) return error.UnsupportedScope;

            try self.emitUnwind(self.loops.items[loop_idx].unwind_depth);
            const jump = try self.emitJump(.op_jump);
            // Re-index: compiling an inline ensure body may grow `self.loops`
            try self.loops.items[loop_idx].exit_jumps.append(self.allocator, jump);
        } else if (self.enclosing != null or self.function != null) {
            try self.emitUnwind(0);
            try self.emitOp(.op_break_block);
            self.simulatePush(1);
        } else {
            return error.UnknownNode;
        }
    }

    fn compileAssignment(self: *Compiler, node: *const ast.Node, node_idx: ast.NodeIndex) CompileError!void {
        const assign_payload = self.tree.assignment(node);
        const sym = self.symbols[@backingInt(node_idx)];
        const name_id = assign_payload.name;
        const name_str = self.tree.getString(name_id);

        if (manifest.compiler_intrinsics.has(name_str)) {
            return self.fail(error.ProtectedSymbol, "'{s}' is a built-in and can't be assigned", .{name_str});
        }

        // Intercept Instance Variables (@x) securely
        if (std.mem.startsWith(u8, name_str, "@") and !std.mem.startsWith(u8, name_str, "@@")) {
            try self.emitPushSelf(); // Stack: [self]

            // Strip '@' at compile time
            const clean_name = if (name_str.len > 1) name_str[1..] else name_str;

            if (assign_payload.op) |op| {
                try self.emitOp(.op_dup); // Stack: [self, self]
                const name_idx = try self.makeStringConstant(clean_name);
                try self.emitOpWithOperand(.op_get_property, .op_get_property_wide, name_idx);
                try self.emitInlineCacheIndex();

                try self.compileNode(assign_payload.value);
                try self.emitBinaryOp(op);
            } else {
                try self.compileNode(assign_payload.value); // Stack: [self, new_val]
            }

            const name_idx = try self.makeStringConstant(clean_name);
            try self.emitOpWithOperand(.op_set_property, .op_set_property_wide, name_idx);
            try self.emitInlineCacheIndex();
            return;
        }

        // Check if the variable exists locally or in an upvalue FIRST
        const local_slot = self.resolveLocal(name_id);
        const upval_slot = try self.resolveUpvalue(name_id);

        // If it doesn't exist locally/upvalue, and we're at the top-level, it's a global.
        // Otherwise, if it's a new local declaration inside a block:
        const is_new_local = self.enclosing != null and
            sym.kind == .local and
            !std.mem.startsWith(u8, name_str, "@@") and
            !std.mem.startsWith(u8, name_str, "@") and
            local_slot == null and
            upval_slot == null and
            !self.writesScriptGlobal(name_id);

        if (is_new_local) {
            const slot = self.getNextLocalSlot();
            try self.addLocal(name_id, slot);
        }

        // Evaluate RHS (with Compound Operator getters if necessary)
        if (assign_payload.op) |op| {
            try self.emitVariableLoad(name_id, sym);
            try self.compileNode(assign_payload.value);
            try self.emitBinaryOp(op);
        } else {
            try self.compileNode(assign_payload.value);
        }

        // Set the Target Variable
        try self.emitVariableStore(name_id, sym);
    }

    fn compileRescueModifier(self: *Compiler, node: *const ast.Node, expected_entry_depth: usize) CompileError!void {
        const rm = self.tree.rescueModifier(node);
        const rescue_jump = try self.emitJump(.op_setup_rescue);
        try self.unwind_stack.append(self.allocator, .rescue_handler);
        try self.compileNode(rm.expr);
        _ = self.unwind_stack.pop();
        try self.emitOp(.op_pop_rescue);
        const end_jump = try self.emitJump(.op_jump);

        self.patchJump(rescue_jump);

        // `op_setup_rescue` jumps here with the error value pushed to the stack
        self.current_stack_depth = expected_entry_depth + 1;

        try self.emitOp(.op_pop); // Discard error value
        try self.compileNode(rm.rescue_expr);
        self.patchJump(end_jump);
    }

    fn compileNamespaceAccess(self: *Compiler, node: *const ast.Node) CompileError!void {
        const path = self.tree.getStringLists(self.tree.nodeSpan(node));
        if (path.len == 0) {
            try self.emitOp(.op_nil);
            return;
        }

        // Get the root of the namespace
        const root_idx = try self.makeStringConstant(self.tree.getString(path[0]));
        try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, root_idx);

        // Chain property accesses for the rest of the namespace path
        for (path[1..]) |segment_id| {
            const seg_idx = try self.makeStringConstant(self.tree.getString(segment_id));
            try self.emitOpWithOperand(.op_get_property, .op_get_property_wide, seg_idx);
            try self.emitInlineCacheIndex();
        }
    }

    fn compileImportStmt(self: *Compiler, node: *const ast.Node) CompileError!void {
        const is_stmt = self.tree.importStmt(node);

        // Sanitize path and extract AliasPairs at the very top
        const raw_path_str = self.tree.getString(is_stmt.path);
        const path_str = std.mem.trimEnd(u8, raw_path_str, "/");
        const symbols = self.tree.getAliasPairs(is_stmt.symbols);

        // --- 1. Asset Interception ---
        if (std.mem.endsWith(u8, path_str, ".stl") or std.mem.endsWith(u8, path_str, ".step")) {
            const func_name = if (std.mem.endsWith(u8, path_str, ".stl")) "import_stl" else "import_step";
            const func_idx = try self.makeStringConstant(func_name);
            try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, func_idx);

            const path_val = try self.vm.allocateString(path_str);
            self.vm.push(path_val);
            const path_idx = try self.makeConstant(path_val);
            _ = self.vm.pop();

            try self.emitOpWithOperand(.op_constant, .op_constant_wide, path_idx);
            try self.emitCall(.op_call, .{ .count = 1 });

            self.simulatePop(2);
            self.simulatePush(1);

            if (symbols.len > 0) {
                const sym_id = symbols[0].alias; // Target the alias ID
                if (self.enclosing != null and self.resolveLocal(sym_id) == null and (try self.resolveUpvalue(sym_id)) == null and !self.writesScriptGlobal(sym_id)) {
                    const slot = self.getNextLocalSlot();
                    try self.addLocal(sym_id, slot);
                }
                const dummy_sym = resolver.ResolvedSymbol{ .kind = .local, .index = 0 };
                try self.emitVariableStore(sym_id, dummy_sym);
            }

            try self.emitOp(.op_pop); // Discard geometry from stack
            try self.emitOp(.op_nil); // Yield nil for statement
            return;
        }

        // --- 2. Package Cache Resolution ---
        var final_path_str: []const u8 = path_str;
        var allocated_path: ?[]u8 = null;
        defer if (allocated_path) |p| self.allocator.free(p);

        // If the import is not a local relative path, route it to the new Package Manager VFS workspace
        const is_local_path = std.mem.startsWith(u8, path_str, "./") or std.mem.startsWith(u8, path_str, "../") or std.mem.startsWith(u8, path_str, "/");
        if (!is_local_path) {
            if (@import("builtin").target.os.tag != .freestanding and @import("builtin").target.os.tag != .wasi) {
                // Route to the symlinked package workspace created by Resolver.linkWorkspace()
                if (std.mem.endsWith(u8, path_str, ".kup")) {
                    allocated_path = try self.allocator.print(".kupcad/pkg/{s}", .{path_str});
                } else {
                    allocated_path = try self.allocator.print(".kupcad/pkg/{s}/{s}", .{ path_str, DEFAULT_IMPORT_ENDPOINT });
                }
                final_path_str = allocated_path.?;
            }
        }

        // --- 3. Standard Module Import & Destructuring ---
        const path_val = try self.vm.allocateString(final_path_str);
        self.vm.push(path_val);
        const path_idx = try self.makeConstant(path_val);
        _ = self.vm.pop();

        try self.emitOpWithOperand(.op_import, .op_import_wide, path_idx);

        if (symbols.len == 0) {
            try self.emitOp(.op_pop);
            try self.emitOp(.op_nil);
            return;
        }

        for (symbols) |pair| {
            try self.emitOp(.op_dup);

            const orig_str = self.tree.getString(pair.original);
            const orig_idx = try self.makeStringConstant(orig_str);
            try self.emitOpWithOperand(.op_get_property, .op_get_property_wide, orig_idx);
            try self.emitInlineCacheIndex();

            const alias_str = self.tree.getString(pair.alias);
            const alias_idx = try self.makeStringConstant(alias_str);

            if (self.enclosing != null) {
                if (self.resolveLocal(pair.alias) != null or (try self.resolveUpvalue(pair.alias)) != null or self.writesScriptGlobal(pair.alias)) {
                    return self.fail(error.VariableAlreadyDeclared, "import '{s}' collides with a variable of the same name", .{alias_str});
                }

                const slot = self.getNextLocalSlot();
                try self.addLocal(pair.alias, slot);
                const dummy_sym = resolver.ResolvedSymbol{ .kind = .local, .index = 0 };
                try self.emitVariableStore(pair.alias, dummy_sym);
            } else {
                if (self.isScriptGlobal(pair.alias) or self.imported_symbols.contains(alias_str)) {
                    return self.fail(error.VariableAlreadyDeclared, "import '{s}' collides with a variable of the same name", .{alias_str});
                }

                try self.emitOp(.op_dup);
                try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, alias_idx);
                try self.imported_symbols.put(self.allocator, alias_str, {}); // Track securely
            }

            try self.emitOp(.op_pop);
        }

        try self.emitOp(.op_pop); // Pop module
        try self.emitOp(.op_nil);
    }

    fn compileExportStmt(self: *Compiler, node: *const ast.Node) CompileError!void {
        const ex_stmt = self.tree.exportStmt(node);
        const symbols = self.tree.getAliasPairs(ex_stmt.symbols);

        const mod_name = try self.makeStringConstant("__exports__");

        if (!self.has_export_module) {
            const export_str_idx = try self.makeStringConstant("exports");
            try self.emitOpWithOperand(.op_module, .op_module_wide, export_str_idx);
            try self.emitOp(.op_dup);
            try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, mod_name);
            self.has_export_module = true;
        } else {
            try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, mod_name);
        }

        for (symbols) |pair| {
            try self.emitVariableLoad(pair.original, null);

            const alias_str = self.tree.getString(pair.alias);
            const alias_idx = try self.makeStringConstant(alias_str);

            // op_set_member expects [ObjModule, Value]. It pops Value, attaches it, and leaves ObjModule + Value
            try self.emitOpWithOperand(.op_set_member, .op_set_member_wide, alias_idx);

            // Pop the attached Value so ONLY the ObjModule remains on the stack
            try self.emitOp(.op_pop);
        }
    }

    fn compileDefStmt(self: *Compiler, node: *const ast.Node, node_idx: ast.NodeIndex) CompileError!void {
        var params: []const ast.Param = &.{};
        var body_node: ast.NodeIndex = .none;
        var def_name_id: ast.StringId = .none;

        if (node.tag == .def_stmt) {
            const ds = self.tree.defStmt(node);
            params = self.tree.getParams(ds.params);
            body_node = ds.body;
            def_name_id = ds.name;
        } else {
            const ls = self.tree.lambdaExpr(node);
            params = self.tree.getParams(ls.params);
            body_node = ls.body;
        }

        const is_method = (node.tag == .def_stmt);
        const name_str = if (def_name_id != .none) self.tree.getString(def_name_id) else null;
        try self.compileClosureBlock(params, body_node, name_str, is_method);

        if (node.tag == .def_stmt) {
            const sym = self.symbols[@backingInt(node_idx)];
            if (self.enclosing == null or sym.kind == .global) {
                const def_name_str = self.tree.getString(def_name_id);
                if (manifest.compiler_intrinsics.has(def_name_str)) {
                    return self.fail(error.ProtectedSymbol, "'{s}' is a built-in and can't be redefined", .{def_name_str});
                }

                const name_idx = try self.makeStringConstant(self.tree.getString(def_name_id));
                try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, name_idx);
                try self.emitOp(.op_nil);
            } else {
                const slot = self.getNextLocalSlot();
                try self.addLocal(def_name_id, slot);
                try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, slot);
            }
        }
    }

    fn compileIndexAccess(self: *Compiler, node: *const ast.Node) CompileError!void {
        const ia = self.tree.indexAccess(node);
        try self.compileNode(ia.target);
        try self.compileNode(ia.index);
        try self.emitOp(.op_get_index);
    }

    fn compileIndexAssignment(self: *Compiler, node: *const ast.Node) CompileError!void {
        const ia = self.tree.indexAssignment(node);

        try self.compileNode(ia.target);
        try self.compileNode(ia.index);

        if (ia.op) |op| {
            // Stack is currently: [target, index]

            // Duplicate BOTH so we can fetch the current value without losing the target/index pointers for the setter
            try self.emitOp(.op_dup_two);
            // Stack is now: [target, index, target, index]

            try self.emitOp(.op_get_index);
            // Stack is now: [target, index, current_val]

            try self.compileNode(ia.value);
            // Stack is now: [target, index, current_val, rhs_val]

            try self.emitBinaryOp(op);
            // Stack is now: [target, index, new_val]
        } else {
            try self.compileNode(ia.value); // Stack: [target, index, new_val]
        }

        // op_set_index consumes [target, index, new_val] and pushes [new_val] back
        try self.emitOp(.op_set_index);
    }

    fn compileUnaryOp(self: *Compiler, node: *const ast.Node) CompileError!void {
        const un_expr = self.tree.unaryExpr(node);
        try self.compileNode(un_expr.operand);
        switch (un_expr.op) {
            .negate => try self.emitOp(.op_negate),
            .not => try self.emitOp(.op_not),
            else => return error.UnknownNode,
        }
    }

    fn tryConstantFold(self: *Compiler, node_idx: ast.NodeIndex) ?f64 {
        const node = self.tree.getNode(node_idx) orelse return null;
        if (node.tag == .number) return self.tree.number(node);
        if (node.tag == .binary_op) {
            const bin = self.tree.binaryExpr(node);
            const left = self.tryConstantFold(bin.left) orelse return null;
            const right = self.tryConstantFold(bin.right) orelse return null;

            const folded: f64 = switch (bin.op) {
                .add => left + right,
                .subtract => left - right,
                .multiply => left * right,
                .divide => if (right != 0.0) left / right else return null,
                .modulo => if (right != 0.0) @mod(left, right) else return null,
                .exponent => std.math.pow(f64, left, right),
                else => return null,
            };
            // An overflow or a NaN is the VM's to report (RangeError / MathError), at run time.
            return if (std.math.isFinite(folded)) folded else null;
        }
        return null;
    }

    fn compileBinaryOp(self: *Compiler, start_node_idx: ast.NodeIndex) CompileError!void {
        // --- CONSTANT FOLDING PEEPHOLE OPTIMIZER ---
        // If the entire binary expression sub-tree consists of constants,
        // fold it into a single value at compile-time to save VM execution cycles
        if (self.tryConstantFold(start_node_idx)) |folded_val| {
            try self.emitConstant(value.Value.initNumber(folded_val));
            return;
        }

        const initial_ops_len = self.scratch_ops.items.len;
        const initial_rights_len = self.scratch_rights.items.len;
        defer {
            self.scratch_ops.shrinkRetainingCapacity(initial_ops_len);
            self.scratch_rights.shrinkRetainingCapacity(initial_rights_len);
        }

        var curr_idx = start_node_idx;
        var curr_node = self.tree.getNode(curr_idx).?;

        // Drill down the left side, recording the right side and operators in an explicit DOD stack
        while (curr_node.tag == .binary_op) {
            const bin_expr = self.tree.binaryExpr(curr_node);

            // Short-Circuiting operators require control-flow jumps, so we compile them recursively
            if (bin_expr.op == .logical_and) {
                try self.compileNode(bin_expr.left);
                const end_jump = try self.emitJump(.op_jump_if_false);
                try self.emitOp(.op_pop); // pop the true left value
                try self.compileNode(bin_expr.right);
                self.patchJump(end_jump);
                break;
            } else if (bin_expr.op == .logical_or) {
                try self.compileNode(bin_expr.left);
                const else_jump = try self.emitJump(.op_jump_if_false);
                const end_jump = try self.emitJump(.op_jump); // If true, skip right side
                self.patchJump(else_jump); // If false, land here
                try self.emitOp(.op_pop); // pop the false left value
                try self.compileNode(bin_expr.right);
                self.patchJump(end_jump); // True branch lands here
                break;
            }

            try self.scratch_ops.append(self.allocator, bin_expr.op);
            try self.scratch_rights.append(self.allocator, bin_expr.right);

            curr_idx = bin_expr.left;
            if (curr_idx == .none) break;
            curr_node = self.tree.getNode(curr_idx).?;
        }

        // Compile the bottom-most left node natively (unless short-circuited)
        if (curr_node.tag != .binary_op or (self.tree.binaryExpr(curr_node).op != .logical_and and self.tree.binaryExpr(curr_node).op != .logical_or)) {
            try self.compileNode(curr_idx);
        }

        // Unwind the explicit stack, compiling the right nodes and emitting operators bottom-up
        var i: usize = self.scratch_rights.items.len;
        while (i > initial_rights_len) {
            i -= 1;
            try self.compileNode(self.scratch_rights.items[i]);
            try self.emitBinaryOp(self.scratch_ops.items[i]);
        }
    }

    fn compileArrayLiteral(self: *Compiler, node: *const ast.Node) CompileError!void {
        const elements = self.tree.getNodes(self.tree.nodeSpan(node));
        if (elements.len == 0) {
            try self.emitOp(.op_build_array);
            try self.emitByte(0);
            self.simulatePush(1);
            return;
        }

        const has_splat = self.anySplat(elements);

        // Fallback to Dynamic Build Mode if array contains splats OR exceeds 65,535 elements
        const use_static_build = !has_splat and elements.len <= limits.MAX_CONSTANTS;

        if (use_static_build) {
            for (elements) |elem| try self.compileNode(elem);

            try self.emitOpWithOperand(.op_build_array, .op_build_array_wide, elements.len);

            self.simulatePop(elements.len);
            self.simulatePush(1);
        } else {
            // Dynamic Build Mode (Handles splats and point clouds/arrays exceeding 65,535 items)
            try self.compileSpreadArray(elements);
        }
    }

    fn compileHashLiteral(self: *Compiler, node: *const ast.Node) CompileError!void {
        const entries = self.tree.getHashEntries(self.tree.nodeSpan(node));
        if (entries.len == 0) {
            try self.emitOp(.op_build_map);
            try self.emitByte(0);
            self.simulatePush(1);
            return;
        }

        var has_splat = false;
        for (entries) |entry| {
            if (self.tree.getNode(entry.key).?.tag == .double_splat_expr) has_splat = true;
        }

        if (!has_splat) {
            for (entries) |entry| {
                const key_node = self.tree.getNode(entry.key).?;
                if (key_node.tag == .identifier) {
                    const str_content = self.tree.getString(self.tree.stringId(key_node));
                    const str_idx = try self.makeStringConstant(str_content);
                    try self.emitOpWithOperand(.op_constant, .op_constant_wide, str_idx);
                } else {
                    try self.compileNode(entry.key);
                }
                try self.compileNode(entry.value);
            }

            if (entries.len > limits.MAX_HASH_ENTRIES) return error.TooManyConstants;

            try self.emitOpWithOperand(.op_build_map, .op_build_map_wide, entries.len);

            self.simulatePop(entries.len * 2);
            self.simulatePush(1);
        } else {
            // Dynamic Build Mode
            try self.emitOp(.op_build_map);
            try self.emitByte(0);
            self.simulatePush(1);

            for (entries) |entry| {
                const key_node = self.tree.getNode(entry.key).?;
                if (key_node.tag == .double_splat_expr) {
                    try self.compileNode(self.tree.nodeIndex(key_node));
                    try self.emitOp(.op_map_spread);
                } else {
                    if (key_node.tag == .identifier) {
                        const str_content = self.tree.getString(self.tree.stringId(key_node));
                        const str_val = try self.vm.allocateString(str_content);
                        self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
                        self.vm.push(str_val);
                        const str_idx = try self.makeConstant(str_val);
                        _ = self.vm.pop();
                        try self.emitOpWithOperand(.op_constant, .op_constant_wide, str_idx);
                    } else {
                        try self.compileNode(entry.key);
                    }
                    try self.compileNode(entry.value);
                    try self.emitOp(.op_map_insert);
                }
            }
        }
    }

    // Entry Point: Routes to Fast Path or Linear Fallback
    fn compileCaseStmt(self: *Compiler, node: *const ast.Node, expected_entry_depth: usize) CompileError!void {
        _ = expected_entry_depth;
        const cs = self.tree.caseStmt(node);
        const saved_depth = self.current_stack_depth;
        const branches = self.tree.getWhenBranches(cs.when_branches);
        const has_cond = cs.condition != .none;

        if (self.checkJumpTableFeasibility(branches, has_cond)) |total_conditions| {
            try self.compileCaseFastPath(cs, branches, total_conditions, saved_depth);
        } else {
            try self.compileCaseLinearFallback(cs, branches, has_cond, saved_depth);
        }
    }

    // Heuristic Check: Verifies if all when-conditions are literal numbers or strings
    fn checkJumpTableFeasibility(self: *Compiler, branches: []const ast.WhenBranch, has_cond: bool) ?usize {
        if (!has_cond) return null;

        var total_conditions: usize = 0;
        for (branches) |branch| {
            const conds = self.tree.getNodes(branch.conditions);
            for (conds) |cond_idx| {
                const c_node = self.tree.getNode(cond_idx) orelse return null;
                if (c_node.tag != .number and c_node.tag != .string) return null;
                total_conditions += 1;
            }
        }

        // The table size is a 16-bit operand; oversized tables use the linear path
        if (total_conditions > limits.MAX_JUMP_TABLE_CASES) return null;
        return if (total_conditions > 0) total_conditions else null;
    }

    // Fast Path: Emits op_switch, collects, sorts, and backpatches jump table entries
    fn compileCaseFastPath(
        self: *Compiler,
        cs: ast.CaseStmt,
        branches: []const ast.WhenBranch,
        total_conditions: usize,
        saved_depth: usize,
    ) CompileError!void {
        try self.compileNode(cs.condition);

        const SwitchCase = struct {
            const_idx: u16,
            branch_idx: usize,
            val: value.Value,

            fn lessThan(_: void, a: @This(), b: @This()) bool {
                const type_a: u8 = if (a.val.isNumber()) 0 else 1;
                const type_b: u8 = if (b.val.isNumber()) 0 else 1;
                if (type_a != type_b) return type_a < type_b;

                if (type_a == 0) {
                    return a.val.asNumber() < b.val.asNumber();
                } else {
                    const str_a = a.val.asString().chars;
                    const str_b = b.val.asString().chars;
                    return std.mem.order(u8, str_a, str_b) == .lt;
                }
            }

            fn sameKey(a: @This(), b: @This()) bool {
                return !lessThan({}, a, b) and !lessThan({}, b, a);
            }
        };

        // Resolve every literal to a constant BEFORE emitting the table: the entry
        // count is encoded up front and duplicates must be dropped from it.
        var cases = try self.allocator.alloc(SwitchCase, total_conditions);
        defer self.allocator.free(cases);

        var condition_idx: usize = 0;
        for (branches, 0..) |branch, branch_idx| {
            for (self.tree.getNodes(branch.conditions)) |cond_node_idx| {
                const c_node = self.tree.getNode(cond_node_idx).?;

                var raw_idx: usize = 0;
                if (c_node.tag == .number) {
                    raw_idx = try self.makeConstant(value.Value.initNumber(self.tree.number(c_node)));
                } else if (c_node.tag == .string) {
                    const str_content = self.tree.getString(self.tree.stringId(c_node));
                    raw_idx = try self.makeStringConstant(str_content);
                }

                const const_idx: u16 = @intCast(raw_idx);
                cases[condition_idx] = .{
                    .const_idx = const_idx,
                    .branch_idx = branch_idx,
                    .val = self.current_chunk.constants.items[const_idx],
                };
                condition_idx += 1;
            }
        }

        // `case` takes the FIRST matching `when`, but the VM binary-searches the
        // table and may land on any of several equal keys. A stable sort keeps
        // equal keys in source order, so keeping the first of each run preserves
        // first-match semantics.
        std.sort.block(SwitchCase, cases, {}, SwitchCase.lessThan);
        var unique_count: usize = 0;
        for (cases) |entry| {
            if (unique_count > 0 and SwitchCase.sameKey(cases[unique_count - 1], entry)) continue;
            cases[unique_count] = entry;
            unique_count += 1;
        }
        const unique_cases = cases[0..unique_count];

        const offsets = try self.emitJumpTable(@intCast(unique_count));
        const table_start_offset = offsets.table_start;
        const default_jump_offset = offsets.default_jump;

        var body_targets = try self.allocator.alloc(usize, branches.len);
        defer self.allocator.free(body_targets);

        var end_jumps: std.ArrayListUnmanaged(usize) = .empty;
        defer end_jumps.deinit(self.allocator);

        for (branches, 0..) |branch, branch_idx| {
            body_targets[branch_idx] = self.current_chunk.code.items.len;
            self.current_stack_depth = saved_depth;

            try self.compileNode(branch.body);
            try end_jumps.append(self.allocator, try self.emitJump(.op_jump));
        }

        // Backpatch Default Branch
        const default_target = self.current_chunk.code.items.len;
        const d_offset = default_target - (default_jump_offset + 4);
        self.writeJumpOffset(default_jump_offset, d_offset);

        self.writeSortedJumpTable(table_start_offset, default_jump_offset + 4, unique_cases, body_targets);

        self.current_stack_depth = saved_depth;

        if (cs.else_branch != .none) {
            try self.compileNode(cs.else_branch);
        } else {
            try self.emitOp(.op_nil);
        }

        for (end_jumps.items) |jmp| {
            self.patchJump(jmp);
        }
        self.current_stack_depth = saved_depth + 1;
    }

    // Helper: Writes sorted cases into the jump table bytecode stream
    // Jump offsets are relative to `jump_base` (the byte after the default jump).
    inline fn writeSortedJumpTable(self: *Compiler, table_start_offset: usize, jump_base: usize, cases: anytype, body_targets: []const usize) void {
        for (cases, 0..) |case_entry, i| {
            const entry = .{
                .const_idx = case_entry.const_idx,
                .jump_offset = @as(u32, @intCast(body_targets[case_entry.branch_idx] - jump_base)),
            };
            const table_idx = table_start_offset + (i * 6);
            self.current_chunk.code.items[table_idx] = @intCast((entry.const_idx >> 8) & 0xFF);
            self.current_chunk.code.items[table_idx + 1] = @intCast(entry.const_idx & 0xFF);
            self.current_chunk.code.items[table_idx + 2] = @intCast((entry.jump_offset >> 24) & 0xFF);
            self.current_chunk.code.items[table_idx + 3] = @intCast((entry.jump_offset >> 16) & 0xFF);
            self.current_chunk.code.items[table_idx + 4] = @intCast((entry.jump_offset >> 8) & 0xFF);
            self.current_chunk.code.items[table_idx + 5] = @intCast(entry.jump_offset & 0xFF);
        }
    }

    // Fallback Path: Compiles complex expressions or conditionless case statements linearly
    fn compileCaseLinearFallback(
        self: *Compiler,
        cs: ast.CaseStmt,
        branches: []const ast.WhenBranch,
        has_cond: bool,
        saved_depth: usize,
    ) CompileError!void {
        if (has_cond) {
            try self.compileNode(cs.condition);
        }

        var end_jumps: std.ArrayListUnmanaged(usize) = .empty;
        defer end_jumps.deinit(self.allocator);

        for (branches) |branch| {
            const conds = self.tree.getNodes(branch.conditions);
            for (conds) |cond_idx| {
                if (has_cond) {
                    self.current_stack_depth = saved_depth + 1;
                    try self.emitOp(.op_dup);
                    try self.compileNode(cond_idx);
                    try self.emitOp(.op_case_equal);
                } else {
                    self.current_stack_depth = saved_depth;
                    try self.compileNode(cond_idx);
                }

                const skip_jump = try self.emitJump(.op_jump_if_false);
                try self.emitOp(.op_pop);
                if (has_cond) try self.emitOp(.op_pop);

                try self.compileNode(branch.body);
                try end_jumps.append(self.allocator, try self.emitJump(.op_jump));

                if (has_cond) {
                    self.current_stack_depth = saved_depth + 2;
                } else {
                    self.current_stack_depth = saved_depth + 1;
                }

                self.patchJump(skip_jump);
                try self.emitOp(.op_pop);
            }
        }

        if (has_cond) {
            self.current_stack_depth = saved_depth + 1;
            try self.emitOp(.op_pop);
        } else {
            self.current_stack_depth = saved_depth;
        }

        if (cs.else_branch != .none) {
            try self.compileNode(cs.else_branch);
        } else {
            try self.emitOp(.op_nil);
        }

        for (end_jumps.items) |jmp| {
            self.patchJump(jmp);
        }
        self.current_stack_depth = saved_depth + 1;
    }

    fn compileBeginStmt(self: *Compiler, node: *const ast.Node, expected_entry_depth: usize) CompileError!void {
        _ = expected_entry_depth; // Ignore warning
        const bs = self.tree.beginStmt(node);
        const saved_depth = self.current_stack_depth;

        const rescues = self.tree.getRescueClauses(bs.rescues);
        var rescue_jump: usize = 0;

        // The ensure region covers the body and the rescue clauses
        const unwind_base = self.unwind_stack.items.len;
        defer self.unwind_stack.shrinkRetainingCapacity(unwind_base);
        if (bs.ensure_body != .none) {
            try self.unwind_stack.append(self.allocator, .{ .ensure_body = bs.ensure_body });
        }

        if (rescues.len > 0) {
            rescue_jump = try self.emitJump(.op_setup_rescue);
            try self.unwind_stack.append(self.allocator, .rescue_handler);
        }

        try self.compileNode(bs.body);

        if (rescues.len > 0) {
            // The VM pops the handler itself when it dispatches a throw, so rescue
            // clause bodies run outside the handler region.
            _ = self.unwind_stack.pop();
            try self.emitOp(.op_pop_rescue);
        }

        const end_jump = try self.emitJump(.op_jump);

        if (rescues.len > 0) {
            self.patchJump(rescue_jump);
            // Reset compiler stack depth to the begin block's entry depth
            self.current_stack_depth = saved_depth;

            self.simulatePush(1); // Simulator: op_throw pushed the error value on the stack
            const error_depth = self.current_stack_depth; // Save the stack depth!
            var rescue_end_jumps: std.ArrayListUnmanaged(usize) = .empty;
            defer rescue_end_jumps.deinit(self.allocator);

            var next_rescue_jump: ?usize = null;

            for (rescues) |rescue| {
                self.current_stack_depth = error_depth; // Reset for each rescue block
                if (next_rescue_jump) |jmp| {
                    self.patchJump(jmp);
                }
                next_rescue_jump = null;

                const errors = self.tree.getStringLists(rescue.errors);
                var match_jumps: std.ArrayListUnmanaged(usize) = .empty;
                defer match_jumps.deinit(self.allocator);

                if (errors.len > 0) {
                    for (errors) |err_id| {
                        self.current_stack_depth = error_depth; // Reset for each type check
                        const name_idx = try self.makeStringConstant(self.tree.getString(err_id));
                        try self.emitOp(.op_dup); // Copy error payload
                        try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, name_idx);
                        try self.emitOp(.op_is_instance);

                        const skip_jump = try self.emitJump(.op_jump_if_false);
                        try self.emitOp(.op_pop); // Discard True

                        try match_jumps.append(self.allocator, try self.emitJump(.op_jump));

                        self.current_stack_depth = error_depth + 1; // False branch has error + false
                        self.patchJump(skip_jump);
                        try self.emitOp(.op_pop); // Discard False
                    }
                    // If no error type matched, jump to the next rescue block
                    next_rescue_jump = try self.emitJump(.op_jump);
                }

                // --- MATCHED ROUTE ---
                self.current_stack_depth = error_depth; // Jump lands here with error on top
                for (match_jumps.items) |jmp| {
                    self.patchJump(jmp);
                }

                const var_str = self.tree.getString(rescue.variable);
                if (var_str.len > 0) {
                    const name_id = rescue.variable;
                    const dummy_sym = resolver.ResolvedSymbol{ .kind = .local, .index = 0 };
                    try self.emitVariableStore(name_id, dummy_sym);
                }

                // Always pop the temporary error value off the expression stack!
                try self.emitOp(.op_pop);

                try self.compileNode(rescue.body);

                try rescue_end_jumps.append(self.allocator, try self.emitJump(.op_jump));
            }

            // If it fell through ALL rescue blocks without matching, re-throw it!
            if (next_rescue_jump) |jmp| {
                self.current_stack_depth = error_depth;
                self.patchJump(jmp);
                try self.emitOp(.op_throw); // op_throw inherently calls simulatePop(1)
                self.simulatePush(1); // Dead code equilibrium instead of double-popping!
            }

            // Patch all successful rescue block ends to arrive here
            for (rescue_end_jumps.items) |jmp| {
                self.patchJump(jmp);
            }
            self.current_stack_depth = error_depth; // The block successfully yields 1 value (error_depth is depth + 1)
        }

        self.patchJump(end_jump);

        self.unwind_stack.shrinkRetainingCapacity(unwind_base);
        if (bs.ensure_body != .none) {
            try self.compileNode(bs.ensure_body);
            try self.emitOp(.op_pop); // discard ensure block output
        }
    }

    fn compileMethodCall(self: *Compiler, node: *const ast.Node) CompileError!void {
        const mc = self.tree.methodCall(node);
        const func_name = self.tree.getString(mc.method_name);

        // Fast-path: compile `obj.nil?` directly into op_is_nil
        if (std.mem.eql(u8, func_name, "nil?") and mc.receiver != .none) {
            try self.compileNode(mc.receiver);
            try self.emitOp(.op_is_nil);
            return;
        }

        // Intercept Compiler Intrinsics via O(1) lookup
        if (manifest.compiler_intrinsics.get(func_name)) |intrinsic| {
            switch (intrinsic) {
                .raise_err => {
                    const args = self.tree.getNamedArgs(mc.args);
                    if (args.len > 0) try self.compileNode(args[0].value) else try self.emitOp(.op_nil);
                    try self.emitOp(.op_throw);
                    self.simulatePush(1); // Dead code equilibrium
                    return;
                },
                .block_given_chk => {
                    try self.emitOp(.op_block_given);
                    return;
                },
                .yield_call => {
                    const call = try self.compileCallArguments(self.tree.getNamedArgs(mc.args), mc.block);
                    // yield calls the method's own block; it cannot hand that block one.
                    if (call.flags.has_block) return error.UnexpectedBlock;

                    try self.emitCall(.op_yield, call);
                    self.simulatePop(call.count); // Yield consumes the args
                    self.simulatePush(1); // Yield returns the block's result
                    return;
                },
                .defined_chk => {
                    const args = self.tree.getNamedArgs(mc.args);
                    if (args.len > 0) {
                        const target_node = self.tree.getNode(args[0].value).?;
                        if (target_node.tag == .identifier) {
                            const name_id = self.tree.stringId(target_node);
                            if (self.resolveLocal(name_id) != null or (try self.resolveUpvalue(name_id)) != null) {
                                try self.emitOp(.op_true); // Locals are statically known
                            } else {
                                const name_str = self.tree.getString(name_id);
                                const name_idx = try self.makeStringConstant(name_str);
                                try self.emitOpWithOperand(.op_defined, .op_defined_wide, name_idx);
                            }
                        } else {
                            try self.emitOp(.op_true); // Complex expressions evaluate to true
                        }
                    } else {
                        try self.emitOp(.op_nil);
                    }
                    return;
                },
                .protected_symbol => {},
            }
        }

        var safe_jump: usize = 0;

        // Push Receiver/Target
        if (mc.receiver == .none) {
            try self.emitVariableLoad(mc.method_name, null);
        } else {
            try self.compileNode(mc.receiver);
            if (mc.is_safe) safe_jump = try self.emitJump(.op_jump_if_nil);
        }

        const call = try self.compileCallArguments(self.tree.getNamedArgs(mc.args), mc.block);

        if (mc.receiver == .none) {
            try self.emitCall(.op_call, call);
        } else {
            const name_idx = try self.makeStringConstant(func_name);
            try self.emitOpWithOperand(.op_invoke, .op_invoke_wide, name_idx);
            try self.emitCallOperands(call);
            try self.emitInlineCacheIndex();

            if (mc.is_safe) self.patchJump(safe_jump);
        }

        self.simulatePop(call.count + 1); // Pops args + receiver
        self.simulatePush(1); // Pushes the returned result
    }

    fn compileMultipleAssignment(self: *Compiler, node: *const ast.Node) CompileError!void {
        // Save simulator state to prevent stack corruption on TooManyConstants aborts
        const saved_depth = self.current_stack_depth;
        errdefer self.current_stack_depth = saved_depth;

        const ma = self.tree.multipleAssignment(node);
        const lhs = self.tree.getLhsExprs(ma.lhs);
        for (lhs) |l| {
            if (l.name != .none) {
                const name_id = l.name;
                // Same rule as a plain `name = value`: only plain names inside a
                // function become new locals. At the top level they are script
                // globals (top-level slot 0 is the script closure, so a local
                // there would clobber `self`).
                if (self.enclosing != null and
                    isPlainLocalName(self.tree.getString(name_id)) and
                    self.resolveLocal(name_id) == null and
                    (try self.resolveUpvalue(name_id)) == null and
                    !self.writesScriptGlobal(name_id))
                {
                    const slot = self.getNextLocalSlot();
                    try self.addLocal(name_id, slot);
                }
            }
        }

        var splat_idx: ?usize = null;
        for (lhs, 0..) |l, i| {
            if (l.modifier != null and l.modifier.? == .splat) {
                splat_idx = i;
                break;
            }
        }

        const val_node = self.tree.getNode(ma.value).?;
        var is_static_array = false;
        var arr_elements: []const ast.NodeIndex = &.{};

        if (val_node.tag == .array_literal) {
            arr_elements = self.tree.getNodes(self.tree.nodeSpan(val_node));
            is_static_array = true;
            for (arr_elements) |el| {
                if (self.tree.getNode(el).?.tag == .splat_expr) {
                    is_static_array = false;
                    break;
                }
            }
        }

        // Unpack fixed-length arrays directly onto the stack
        if (is_static_array and splat_idx == null) {
            for (arr_elements) |el| {
                try self.compileNode(el);
            }

            if (arr_elements.len > lhs.len) {
                const excess = arr_elements.len - lhs.len;
                for (0..excess) |_| {
                    try self.emitOp(.op_pop);
                }
            } else if (lhs.len > arr_elements.len) {
                const deficit = lhs.len - arr_elements.len;
                for (0..deficit) |_| {
                    try self.emitOp(.op_nil);
                }
            }

            var i: usize = lhs.len;
            while (i > 0) {
                i -= 1;
                try self.compileDestructure(lhs[i]);
            }
            try self.emitOp(.op_nil);
            return;
        }

        // --- Standard Dynamic Unpacking Fallback ---
        try self.compileNode(ma.value);
        if (splat_idx) |s_idx| {
            const pre_count = s_idx;
            const post_count = lhs.len - 1 - s_idx;
            if (pre_count > limits.MAX_SHORT_CONSTANTS or post_count > limits.MAX_SHORT_CONSTANTS) return error.TooManyConstants;
            try self.emitOp(.op_unpack_splat);
            try self.emitByte(@intCast(pre_count));
            try self.emitByte(@intCast(post_count));
            self.simulatePop(1);
            self.simulatePush(lhs.len);
        } else {
            if (lhs.len > limits.MAX_SHORT_CONSTANTS) return error.TooManyConstants;
            try self.emitOp(.op_unpack);
            try self.emitByte(@intCast(lhs.len));
            self.simulatePop(1);
            self.simulatePush(lhs.len);
        }

        var i: usize = lhs.len;
        while (i > 0) {
            i -= 1;
            try self.compileDestructure(lhs[i]);
        }
        try self.emitOp(.op_nil);
    }

    fn compileClassStmt(self: *Compiler, node: *const ast.Node, node_idx: ast.NodeIndex) CompileError!void {
        self.active_namespaces += 1;
        defer self.active_namespaces -= 1;

        const cs = self.tree.classStmt(node);
        const name_node = self.tree.getNode(cs.name).?;
        const name_id = self.tree.stringId(name_node);
        const name_idx = try self.makeStringConstant(self.tree.getString(name_id));
        const name_str = self.tree.getString(name_id);

        if (manifest.compiler_intrinsics.has(name_str)) {
            return self.fail(error.ProtectedSymbol, "'{s}' is a built-in and can't be redefined", .{name_str});
        }

        try self.namespace_stack.append(self.allocator, name_id);
        defer _ = self.namespace_stack.pop();

        try self.emitOpWithOperand(.op_class, .op_class_wide, name_idx);

        if (cs.super_class != .none) {
            try self.compileNode(cs.super_class);
            try self.emitOp(.op_inherit);
        }

        const body_node = self.tree.getNode(cs.body).?;
        const block_payload = self.tree.block(body_node);
        const stmts = self.tree.getNodes(block_payload.stmts);

        // Compile entire class body natively!
        try self.compileNamespaceBody(stmts, false);

        // Export Fully Qualified Name
        try self.defineFullyQualifiedNamespace(name_str);

        const sym = self.symbols[@backingInt(node_idx)];
        if (self.active_namespaces > 1) {
            try self.emitOpWithOperand(.op_set_member, .op_set_member_wide, name_idx);
        } else if (sym.kind == .local and self.enclosing != null) {
            const slot = self.getNextLocalSlot();
            try self.addLocal(name_id, slot);
            try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, slot);
        } else {
            try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, name_idx);
            try self.emitOp(.op_nil);
        }
    }

    fn compileModuleStmt(self: *Compiler, node: *const ast.Node) CompileError!void {
        self.active_namespaces += 1;
        defer self.active_namespaces -= 1;

        const ms = self.tree.moduleStmt(node);
        const name_id = ms.name;
        const name_str = self.tree.getString(name_id);
        const name_idx = try self.makeStringConstant(name_str);

        try self.namespace_stack.append(self.allocator, name_id);
        defer _ = self.namespace_stack.pop();

        try self.emitOpWithOperand(.op_module, .op_module_wide, name_idx);

        const body_node = self.tree.getNode(ms.body).?;
        const block_payload = self.tree.block(body_node);
        const stmts = self.tree.getNodes(block_payload.stmts);

        // Compile entire module body natively
        try self.compileNamespaceBody(stmts, false);

        // Export Fully Qualified Name
        try self.defineFullyQualifiedNamespace(name_str);

        if (self.active_namespaces > 1) {
            try self.emitOpWithOperand(.op_set_member, .op_set_member_wide, name_idx);
        } else {
            try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, name_idx);
            try self.emitOp(.op_nil);
        }
    }

    fn compileSuperCall(self: *Compiler, node: *const ast.Node) CompileError!void {
        const sc = self.tree.superCall(node);
        try self.emitOp(.op_get_local);
        try self.emitByte(0); // push `self`

        var call: CallArgs = .{ .count = 0 };

        if (sc.implicit_args) {
            const func = self.function orelse return error.UnknownNode;
            const arity = func.arity;

            // Forward the method's own parameters, the kwarg map included (it is the last of
            // the arity slots). A `*rest` parameter holds an Array, so it is spread back into
            // separate arguments: the positionals are packed into one Array, like `f(*xs)`.
            if (func.splat_pos) |splat_pos| {
                try self.emitOp(.op_build_array);
                try self.emitByte(0);
                self.simulatePush(1);
                for (0..arity) |i| {
                    try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, @intCast(i + 1));
                    try self.emitOp(if (i == splat_pos) .op_array_spread else .op_array_push);
                }
            } else {
                for (0..arity) |i| {
                    try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, @intCast(i + 1));
                }
            }
            if (sc.block == .none) {
                // Forward the parent's block (nil when it got none)
                try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, @intCast(arity + 1));
            } else {
                // An explicitly passed block overrides the implicit one
                try self.compileBlockLiteral(sc.block);
            }
            call = if (func.splat_pos != null)
                .{ .count = 2, .flags = .{ .has_block = true, .spread = true } }
            else
                .{ .count = @as(usize, arity) + 1, .flags = .{ .has_block = true } };
        } else {
            call = try self.compileCallArguments(self.tree.getNamedArgs(sc.args), sc.block);
        }

        try self.emitCall(.op_super_invoke, call);

        // Pop the arguments + the implicit `self` receiver
        self.simulatePop(call.count + 1);
        self.simulatePush(1);
    }

    fn lowerBlockParams(self: *Compiler, param_span: ast.Span) CompileError![]const ast.Param {
        const param_nodes = self.tree.getNodes(param_span);
        var lowered = try self.allocator.alloc(ast.Param, param_nodes.len);

        for (param_nodes, 0..) |node_idx, i| {
            const node = self.tree.getNode(node_idx) orelse return error.UnknownNode;

            switch (node.tag) {
                .identifier => {
                    lowered[i] = .{
                        .name = self.tree.stringId(node),
                        .default_value = .none,
                        .modifier = null,
                        .is_keyword = false,
                    };
                },
                .assignment => {
                    const assign = self.tree.assignment(node);
                    lowered[i] = .{
                        .name = assign.name,
                        .default_value = assign.value,
                        .modifier = null,
                        .is_keyword = false,
                    };
                },
                .symbol => {
                    lowered[i] = .{
                        .name = self.tree.stringId(node),
                        .default_value = .none,
                        .modifier = null,
                        .is_keyword = true,
                    };
                },
                .hash_literal => {
                    const entries = self.tree.getHashEntries(self.tree.nodeSpan(node));
                    const key_node = self.tree.getNode(entries[0].key).?;
                    lowered[i] = .{
                        .name = self.tree.stringId(key_node),
                        .default_value = entries[0].value,
                        .modifier = null,
                        .is_keyword = true,
                    };
                },
                .splat_expr => {
                    const inner_node = self.tree.getNode(self.tree.nodeIndex(node)).?;
                    lowered[i] = .{
                        .name = self.tree.stringId(inner_node),
                        .default_value = .none,
                        .modifier = .splat,
                        .is_keyword = false,
                    };
                },
                .double_splat_expr => {
                    const inner_node = self.tree.getNode(self.tree.nodeIndex(node)).?;
                    lowered[i] = .{
                        .name = self.tree.stringId(inner_node),
                        .default_value = .none,
                        .modifier = .double_splat,
                        .is_keyword = false,
                    };
                },
                .array_literal => {
                    // This represents destructuring like |(x, y)|
                    lowered[i] = .{
                        .name = .none, // Anonymous parameter
                        .default_value = .none,
                        .modifier = null,
                        .is_keyword = false,
                    };
                },
                else => return error.UnknownNode,
            }
        }
        return lowered;
    }

    fn compileIfStmt(self: *Compiler, node: *const ast.Node, expected_entry_depth: usize) CompileError!void {
        const if_payload = self.tree.ifStmt(node);
        try self.compileNode(if_payload.condition);
        if (if_payload.is_unless) try self.emitOp(.op_not);

        const then_jump = try self.emitJump(.op_jump_if_false);
        try self.emitOp(.op_pop); // pop cond for true branch

        try self.compileNode(if_payload.then_branch);

        // Force sync before branch jump
        self.current_stack_depth = expected_entry_depth + 1;
        const else_jump = try self.emitJump(.op_jump);

        self.patchJump(then_jump);

        // False branch: VM stack still has the condition on it
        self.current_stack_depth = expected_entry_depth + 1;

        try self.emitOp(.op_pop); // pop cond for false branch

        if (if_payload.else_branch != .none) {
            try self.compileNode(if_payload.else_branch);
        } else {
            try self.emitOp(.op_nil);
        }

        self.patchJump(else_jump);
        // Guarantee perfectly balanced exit
        self.current_stack_depth = expected_entry_depth + 1;
    }

    fn compileWhileStmt(self: *Compiler, node: *const ast.Node, expected_entry_depth: usize) CompileError!void {
        const while_payload = self.tree.whileStmt(node);
        const loop_start = self.current_chunk.code.items.len;

        // Push loop state WITH stack depth
        try self.loops.append(self.allocator, .{
            .start = loop_start,
            .depth = self.current_stack_depth,
            .unwind_depth = self.unwind_stack.items.len,
        });

        try self.compileNode(while_payload.condition);
        if (while_payload.is_until) try self.emitOp(.op_not);

        const exit_jump = try self.emitJump(.op_jump_if_false);
        try self.emitOp(.op_pop); // Clean up condition

        try self.compileNode(while_payload.body);

        // Force sync before loop jump
        self.current_stack_depth = expected_entry_depth + 1;
        try self.emitOp(.op_pop); // Pop the body's yielded result

        try self.emitLoop(loop_start);

        self.patchJump(exit_jump);

        // VM stack still has the condition on it when it jumps here!
        self.current_stack_depth = expected_entry_depth + 1;

        try self.emitOp(.op_pop);
        try self.emitOp(.op_nil); // Natural exit yields nil

        // Pop loop state and safely patch all 'break' jump addresses
        var cur_loop = self.loops.pop().?;
        defer cur_loop.exit_jumps.deinit(self.allocator);
        for (cur_loop.exit_jumps.items) |jmp| {
            self.patchJump(jmp);
        }

        // Guarantee perfectly balanced exit
        self.current_stack_depth = expected_entry_depth + 1;
    }

    fn compileTernaryOp(self: *Compiler, node: *const ast.Node, expected_entry_depth: usize) CompileError!void {
        const ternary = self.tree.ternaryExpr(node);
        try self.compileNode(ternary.condition);
        const then_jump = try self.emitJump(.op_jump_if_false);
        try self.emitOp(.op_pop); // pop condition if true
        try self.compileNode(ternary.then_branch);
        const else_jump = try self.emitJump(.op_jump);

        self.patchJump(then_jump);

        // False branch: VM stack still has the condition on it!
        self.current_stack_depth = expected_entry_depth + 1;

        try self.emitOp(.op_pop); // pop condition if false
        try self.compileNode(ternary.else_branch);
        self.patchJump(else_jump);
    }

    fn compileRange(self: *Compiler, node: *const ast.Node) CompileError!void {
        const r = self.tree.range(node);
        try self.compileNode(r.start);
        try self.compileNode(r.end);

        if (r.step != .none) {
            try self.compileNode(r.step);
        } else {
            try self.emitConstant(value.Value.initNumber(1.0)); // Default step
        }

        try self.emitOp(.op_build_range);
        try self.emitByte(if (r.is_exclusive) 1 else 0);

        self.simulatePop(3); // Pops start, end, step
        self.simulatePush(1); // Pushes ObjRange
    }

    fn compileInterpolatedString(self: *Compiler, node: *const ast.Node) CompileError!void {
        const parts = self.tree.getNodes(self.tree.nodeSpan(node));
        for (parts) |part| {
            try self.compileNode(part);
        }

        if (parts.len > limits.MAX_SHORT_CONSTANTS) return error.TooManyConstants;

        try self.emitOp(.op_interpolate);
        try self.emitByte(@intCast(parts.len));

        self.simulatePop(parts.len);
        self.simulatePush(1); // Pushes the final merged String
    }

    fn compilePropertyAssignment(self: *Compiler, node: *const ast.Node) CompileError!void {
        const pa = self.tree.propertyAssignment(node);
        const prop_name = self.tree.getString(pa.property);

        const name_idx = try self.makeStringConstant(prop_name);

        try self.compileNode(pa.target); // Stack: [target]

        if (pa.op) |op| {
            // Duplicate the pointer instead of re-evaluating the AST
            try self.emitOp(.op_dup); // Stack: [target, target]

            // Compound assignments must read properties via op_get_property, not op_invoke
            try self.emitOpWithOperand(.op_get_property, .op_get_property_wide, name_idx);
            try self.emitInlineCacheIndex();
            // Stack is now: [target, old_val]

            try self.compileNode(pa.value); // Stack: [target, old_val, rhs_val]

            try self.emitBinaryOp(op);
            // Stack is now: [target, new_val]
        } else {
            try self.compileNode(pa.value); // Stack: [target, new_val]
        }

        // op_set_property consumes both target and new_val, then pushes new_val back
        try self.emitOpWithOperand(.op_set_property, .op_set_property_wide, name_idx);
        try self.emitInlineCacheIndex();
    }

    fn compileDefinedExpr(self: *Compiler, node: *const ast.Node) CompileError!void {
        if (self.tree.stringId(node) != .none) {
            const name_id = self.tree.stringId(node);
            if (self.resolveLocal(name_id) != null or (try self.resolveUpvalue(name_id)) != null) {
                try self.emitOp(.op_true); // Locals are statically known
            } else {
                const name_str = self.tree.getString(name_id);
                const name_idx = try self.makeStringConstant(name_str);
                try self.emitOpWithOperand(.op_defined, .op_defined_wide, name_idx);
            }
        } else {
            try self.emitOp(.op_true);
        }
    }

    fn compileBlock(self: *Compiler, node: *const ast.Node) CompileError!void {
        const block_payload = self.tree.block(node);
        const stmts = self.tree.getNodes(block_payload.stmts);

        // Unpack destructured block arguments
        const param_nodes = self.tree.getNodes(block_payload.params);
        for (param_nodes, 0..) |p_idx, i| {
            const p_node = self.tree.getNode(p_idx).?;
            if (p_node.tag == .array_literal) {
                // The tuple is sitting in local slot (i + 1)
                try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, @intCast(i + 1));
                // Call recursive destructuring directly
                try self.compileDestructureNode(p_idx);
            }
        }

        if (stmts.len == 0) {
            try self.emitOp(.op_nil);
        } else {
            for (stmts, 0..) |stmt_idx, i| {
                try self.compileNode(stmt_idx);

                // Unconditionally pop every statement except the last one!
                if (i < stmts.len - 1) {
                    try self.emitOp(.op_pop);
                }
            }
        }
    }

    fn emitPushSelf(self: *Compiler) CompileError!void {
        if (self.is_method or self.enclosing == null) {
            try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, 0);
        } else {
            // We are in a block. Capture the parent method's `self`
            if (try self.resolveSelfUpvalue()) |upv_idx| {
                try self.emitOp(.op_get_upvalue);
                try self.emitByte(upv_idx);
            } else {
                // Fallback (shouldn't happen in valid code)
                try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, 0);
            }
        }
    }

    fn emitVariableLoad(self: *Compiler, name_id: ast.StringId, sym: ?resolver.ResolvedSymbol) CompileError!void {
        const name_str = self.tree.getString(name_id);
        const classification = try self.classifyStorage(name_id, sym);

        switch (classification.kind) {
            .constant => {
                if (self.namespace_stack.items.len > 0) {
                    var end_jumps = std.ArrayListUnmanaged(usize).empty;
                    defer end_jumps.deinit(self.allocator);

                    var i: usize = self.namespace_stack.items.len;
                    while (i > 0) {
                        const fq_name = try self.buildFullyQualifiedPath(name_str, i);

                        const fq_idx = try self.makeStringConstant(fq_name);

                        try self.emitOpWithOperand(.op_defined, .op_defined_wide, fq_idx);
                        const skip_jump = try self.emitJump(.op_jump_if_false);
                        try self.emitOp(.op_pop); // pop true

                        try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, fq_idx);
                        try end_jumps.append(self.allocator, try self.emitJump(.op_jump));

                        self.patchJump(skip_jump);
                        try self.emitOp(.op_pop); // pop false

                        // Explicitly free inside the loop
                        self.allocator.free(fq_name);
                        i -= 1;
                    }

                    const global_idx = try self.makeStringConstant(name_str);
                    try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, global_idx);

                    for (end_jumps.items) |jmp| self.patchJump(jmp);
                } else {
                    const name_idx = try self.makeStringConstant(name_str);
                    try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, name_idx);
                }
            },
            .class_var => {
                try self.emitPushSelf();
                const name_idx = try self.makeStringConstant(name_str);
                try self.emitOpWithOperand(.op_get_class_var, .op_get_class_var_wide, name_idx);
            },
            .instance_var => {
                try self.emitPushSelf();
                const clean_name = if (name_str.len > 1) name_str[1..] else name_str;
                const name_idx = try self.makeStringConstant(clean_name);
                try self.emitOpWithOperand(.op_get_property, .op_get_property_wide, name_idx);
                try self.emitInlineCacheIndex();
            },
            .local => {
                try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, classification.index);
            },
            .upvalue => {
                try self.emitOp(.op_get_upvalue);
                try self.emitByte(@intCast(classification.index));
            },
            .global, .new_local => {
                const name_idx = try self.makeStringConstant(name_str);
                try self.emitOpWithOperand(.op_get_global, .op_get_global_wide, name_idx);
            },
        }
    }

    /// `classifyVariable` plus the `$name` sigil. The resolver already marks every
    /// `$name` read as a global; stores must agree, or `$x = 1` inside a function
    /// would make a function-local that no other function could read.
    fn classifyStorage(self: *Compiler, name_id: ast.StringId, sym: ?resolver.ResolvedSymbol) CompileError!scope_mod.ResolvedVar {
        const name_str = self.tree.getString(name_id);
        if (std.mem.startsWith(u8, name_str, "$")) return .{ .kind = .global };
        const classified = try self.classifyVariable(name_id, sym);
        // Every store path (rescue binding, destructuring, block params) gets the same
        // rule as plain assignment: inside a def, a plain name never writes a script global.
        if (classified.kind == .global and isPlainLocalName(name_str) and self.insideDef()) {
            return .{ .kind = .new_local };
        }
        return classified;
    }

    /// The hidden frame slot behind `scratch_slot`, allocated on first use.
    fn scratchLocalSlot(self: *Compiler) CompileError!u16 {
        if (self.scratch_slot) |slot| return slot;
        // Slot 0 holds the running closure, and at the top level it is also what
        // `self` reads, so it must never double as scratch. Function compilers
        // reserve it up front; the top-level compiler does not.
        if (self.getNextLocalSlot() == 0) try self.addLocal(.none, 0);
        const slot = self.getNextLocalSlot();
        try self.addLocal(.none, slot);
        self.scratch_slot = slot;
        return slot;
    }

    /// Stores the value on top of the stack into the named variable and leaves the
    /// value there, whatever kind of variable the name turns out to be.
    fn emitVariableStore(self: *Compiler, name_id: ast.StringId, sym: resolver.ResolvedSymbol) CompileError!void {
        const name_str = self.tree.getString(name_id);
        const classification = try self.classifyStorage(name_id, sym);

        switch (classification.kind) {
            .constant => {
                const fq_name = try self.buildFullyQualifiedPath(name_str, self.namespace_stack.items.len);
                defer self.allocator.free(fq_name);
                const fq_name_idx = try self.makeStringConstant(fq_name);

                try self.emitOp(.op_dup);
                try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, fq_name_idx);

                if (self.namespace_stack.items.len == 0) {
                    try self.emitOp(.op_dup);
                    const short_name_idx = try self.makeStringConstant(name_str);
                    try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, short_name_idx);
                }
            },
            .class_var => {
                try self.emitPushSelf();
                const name_idx = try self.makeStringConstant(name_str);
                try self.emitOpWithOperand(.op_set_class_var, .op_set_class_var_wide, name_idx);
            },
            .instance_var => {
                // A plain `@x = v` pushes self before evaluating v (compileAssignment).
                // Here v is already on the stack (a destructured element, a rescued
                // error), but op_set_property needs [self, v] and the VM has no swap,
                // so park v in a hidden slot and reload it above self.
                const scratch = try self.scratchLocalSlot();
                try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, scratch); // [v]
                try self.emitPushSelf(); // [v, self]
                try self.emitOpWithOperand(.op_get_local, .op_get_local_wide, scratch); // [v, self, v]
                const clean_name = if (name_str.len > 1) name_str[1..] else name_str;
                const name_idx = try self.makeStringConstant(clean_name);
                try self.emitOpWithOperand(.op_set_property, .op_set_property_wide, name_idx); // [v, v]
                try self.emitInlineCacheIndex();
                try self.emitOp(.op_pop); // [v]
            },
            .local => {
                try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, classification.index);
            },
            .upvalue => {
                try self.emitOp(.op_set_upvalue);
                try self.emitByte(@intCast(classification.index));
            },
            .global => {
                if (self.enclosing == null) {
                    try self.script_globals.put(self.allocator, name_str, {});
                }
                try self.emitOp(.op_dup);
                const name_idx = try self.makeStringConstant(name_str);
                try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, name_idx);
            },
            .new_local => {
                const slot = self.getNextLocalSlot();
                try self.addLocal(name_id, @intCast(slot));
                try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, slot);
            },
        }
    }

    fn handleMacroMethod(self: *Compiler, stmt_node: *const ast.Node, is_singleton: bool) CompileError!bool {
        if (stmt_node.tag != .method_call) return false;
        const mc = self.tree.methodCall(stmt_node);
        const func_name = self.tree.getString(mc.method_name);

        if (std.mem.eql(u8, func_name, "include") and mc.receiver == .none) {
            const args = self.tree.getNamedArgs(mc.args);
            if (args.len == 1) {
                try self.compileNode(args[0].value);
                try self.emitOp(.op_mixin);
                return true;
            }
        } else if ((std.mem.eql(u8, func_name, "attr_accessor") or std.mem.eql(u8, func_name, "attr_reader") or std.mem.eql(u8, func_name, "attr_writer")) and mc.receiver == .none) {
            const args = self.tree.getNamedArgs(mc.args);
            for (args) |arg| {
                const arg_node = self.tree.getNode(arg.value).?;
                if (arg_node.tag == .symbol or arg_node.tag == .string) {
                    const name_str = self.tree.getString(self.tree.stringId(arg_node));
                    if (std.mem.eql(u8, func_name, "attr_reader") or std.mem.eql(u8, func_name, "attr_accessor")) {
                        try macros.emitAttrReader(self, name_str, is_singleton);
                    }
                    if (std.mem.eql(u8, func_name, "attr_writer") or std.mem.eql(u8, func_name, "attr_accessor")) {
                        try macros.emitAttrWriter(self, name_str, is_singleton);
                    }
                } else {
                    return error.UnknownNode;
                }
            }
            return true;
        }
        return false;
    }

    /// Unifies Positional and Keyword Argument compilation for Method and Super calls
    /// Compiles a call's arguments onto the stack, in the order every call dispatch expects:
    /// the positionals (packed into one Array when any is a `*splat`, flagged `spread`), the
    /// keywords and `**hash` arguments as one trailing Map, then the block (`&blk` or a
    /// literal `do ... end` / `{ ... }`, flagged `has_block`).
    fn compileCallArguments(self: *Compiler, args: []const ast.NamedArg, literal_block: ast.NodeIndex) CompileError!CallArgs {
        var call: CallArgs = .{ .count = 0 };

        var has_splat = false;
        for (args) |arg| {
            if (isPositionalArg(arg) and arg.modifier == .splat) has_splat = true;
        }
        if (has_splat) {
            try self.emitOp(.op_build_array);
            try self.emitByte(0);
            self.simulatePush(1);
            for (args) |arg| {
                if (!isPositionalArg(arg)) continue;
                try self.compileNode(arg.value);
                try self.emitOp(if (arg.modifier == .splat) .op_array_spread else .op_array_push);
            }
            call = .{ .count = 1, .flags = .{ .spread = true } };
        } else {
            for (args) |arg| {
                if (!isPositionalArg(arg)) continue;
                try self.compileNode(arg.value);
                call.count += 1;
            }
        }

        if (try self.compileKeywordArguments(args)) call.count += 1;

        var block_arg: ast.NodeIndex = .none;
        for (args) |arg| {
            if (arg.modifier != .block) continue;
            if (block_arg != .none) return error.UnexpectedBlock;
            block_arg = arg.value;
        }
        if (block_arg != .none) {
            if (literal_block != .none) return error.UnexpectedBlock; // `f(&b) { ... }`
            try self.compileNode(block_arg);
        } else if (literal_block != .none) {
            try self.compileBlockLiteral(literal_block);
        }
        if (block_arg != .none or literal_block != .none) {
            call.count += 1;
            call.flags.has_block = true;
        }

        if (call.count > limits.MAX_ARGS) return error.TooManyArguments;
        return call;
    }

    fn isPositionalArg(arg: ast.NamedArg) bool {
        return arg.name == .none and arg.modifier != .block and arg.modifier != .double_splat;
    }

    /// Packs `name: value` and `**hash` arguments into one Map on the stack; false if the
    /// call has none.
    fn compileKeywordArguments(self: *Compiler, args: []const ast.NamedArg) CompileError!bool {
        var kw_count: usize = 0;
        var has_double_splat = false;
        for (args) |arg| {
            if (arg.name != .none) kw_count += 1;
            if (arg.modifier == .double_splat) has_double_splat = true;
        }
        if (kw_count == 0 and !has_double_splat) return false;

        if (!has_double_splat) {
            for (args) |arg| {
                if (arg.name == .none) continue;
                const name_idx = try self.makeSymbolConstant(self.tree.getString(arg.name));
                try self.emitOpWithOperand(.op_constant, .op_constant_wide, name_idx);
                try self.compileNode(arg.value);
            }
            try self.emitOpWithOperand(.op_build_map, .op_build_map_wide, kw_count);
            self.simulatePop(kw_count * 2);
            self.simulatePush(1);
            return true;
        }

        // `**hash` merges at run time, in source order with the named keywords.
        try self.emitOp(.op_build_map);
        try self.emitByte(0);
        self.simulatePush(1);
        for (args) |arg| {
            if (arg.modifier == .double_splat) {
                try self.compileNode(arg.value);
                try self.emitOp(.op_map_spread);
            } else if (arg.name != .none) {
                const name_idx = try self.makeSymbolConstant(self.tree.getString(arg.name));
                try self.emitOpWithOperand(.op_constant, .op_constant_wide, name_idx);
                try self.compileNode(arg.value);
                try self.emitOp(.op_map_insert);
            }
        }
        return true;
    }

    /// A `do ... end` / `{ ... }` block, compiled as a closure value.
    fn compileBlockLiteral(self: *Compiler, block_idx: ast.NodeIndex) CompileError!void {
        const block_payload = self.tree.block(self.tree.getNode(block_idx).?);
        const lowered_params = try self.lowerBlockParams(block_payload.params);
        defer self.allocator.free(lowered_params);
        try self.compileClosureBlock(lowered_params, block_idx, null, false);
    }

    fn anySplat(self: *Compiler, nodes: []const ast.NodeIndex) bool {
        for (nodes) |n| {
            if (self.tree.getNode(n).?.tag == .splat_expr) return true;
        }
        return false;
    }

    /// Builds one Array from `nodes`, spreading each `*splat` element into it.
    fn compileSpreadArray(self: *Compiler, nodes: []const ast.NodeIndex) CompileError!void {
        try self.emitOp(.op_build_array);
        try self.emitByte(0);
        self.simulatePush(1);
        for (nodes) |n| {
            const node = self.tree.getNode(n).?;
            if (node.tag == .splat_expr) {
                try self.compileNode(self.tree.nodeIndex(node));
                try self.emitOp(.op_array_spread);
            } else {
                try self.compileNode(n);
                try self.emitOp(.op_array_push);
            }
        }
    }

    /// Emits a call opcode with its argument count and CallFlags.
    fn emitCall(self: *Compiler, op: chunk.OpCode, call: CallArgs) CompileError!void {
        try self.emitOp(op);
        try self.emitCallOperands(call);
    }

    fn emitCallOperands(self: *Compiler, call: CallArgs) CompileError!void {
        try self.emitByte(@intCast(call.count));
        try self.emitByte(@bitCast(call.flags));
    }

    /// Unifies Method, Macro, and Statement parsing for Classes, Modules, and Singleton blocks
    fn compileNamespaceBody(self: *Compiler, stmts: []const ast.NodeIndex, is_singleton: bool) CompileError!void {
        for (stmts) |stmt_idx| {
            const stmt_node = self.tree.getNode(stmt_idx).?;
            if (stmt_node.tag == .def_stmt) {
                const ds = self.tree.defStmt(stmt_node);
                const method_name = self.tree.getString(ds.name);

                var is_class_method = ds.is_class_method or std.mem.startsWith(u8, method_name, "self.");
                if (is_singleton) is_class_method = true; // In `class << self`, all methods are class methods

                var final_name = method_name;
                if (std.mem.startsWith(u8, method_name, "self.")) {
                    final_name = method_name[5..];
                }

                const m_name_idx = try self.makeMethodNameConstant(final_name, ds.is_private);
                const params = self.tree.getParams(ds.params);

                try self.compileClosureBlock(params, ds.body, final_name, true);
                try self.emitOpWithOperand(if (is_class_method) .op_class_method else .op_method, if (is_class_method) .op_class_method_wide else .op_method_wide, m_name_idx);
            } else if (try self.handleMacroMethod(stmt_node, is_singleton)) {
                // Macro handled successfully
            } else {
                try self.compileNode(stmt_idx);
                try self.emitOp(.op_pop);
            }
        }
    }

    /// Emits the fully qualified alias for nested modules and classes
    fn defineFullyQualifiedNamespace(self: *Compiler, short_name: []const u8) CompileError!void {
        const fq_name = try self.buildFullyQualifiedPath(short_name, self.namespace_stack.items.len - 1);
        defer self.allocator.free(fq_name);

        if (!std.mem.eql(u8, fq_name, short_name)) {
            const fq_name_idx = try self.makeStringConstant(fq_name);
            try self.emitOp(.op_dup);
            try self.emitOpWithOperand(.op_define_global, .op_define_global_wide, fq_name_idx);
        }
    }

    fn compileDestructure(self: *Compiler, target: ast.LhsExpr) CompileError!void {
        // Assign the unpacked value currently on top of the stack to the target identifier
        if (target.name != .none) {
            // Provide a dummy symbol. The classification engine will figure out if it's a
            // constant, class variable, existing local, upvalue, or global automatically!
            const dummy_sym = resolver.ResolvedSymbol{ .kind = .local, .index = 0 };

            try self.emitVariableStore(target.name, dummy_sym);

            // `emitVariableStore` is designed for standard assignments, so it ALWAYS leaves
            // the assigned value on the stack. Destructuring expects to consume the value
            // to move to the next array element, so we must pop it unconditionally here.
            try self.emitOp(.op_pop);
        } else {
            // Unhandled pattern or skipped element (e.g., `_`): pop to maintain stack equilibrium
            try self.emitOp(.op_pop);
        }
    }

    // Helper function to handle nested array destructuring
    /// Unpacks a destructured block parameter (`|(x, (y, z))|`) into block locals.
    fn compileDestructureNode(self: *Compiler, target_node_idx: ast.NodeIndex) CompileError!void {
        // Save simulator state to prevent stack corruption on TooManyConstants aborts
        const saved_depth = self.current_stack_depth;
        errdefer self.current_stack_depth = saved_depth;

        const node = self.tree.getNode(target_node_idx) orelse return error.UnknownNode;

        if (node.tag == .identifier) {
            // A destructured name is a parameter like a plain `|x|`: it always shadows an
            // outer variable of the same name instead of writing through it.
            const name_id = self.tree.stringId(node);
            const slot = self.resolveLocal(name_id) orelse blk: {
                const new_slot = self.getNextLocalSlot();
                try self.addLocal(name_id, new_slot);
                break :blk new_slot;
            };
            try self.emitOpWithOperand(.op_set_local, .op_set_local_wide, slot);
            try self.emitOp(.op_pop);
        } else if (node.tag == .array_literal) {
            // Recursive Spatial Destructuring!
            const elements = self.tree.getNodes(self.tree.nodeSpan(node));
            if (elements.len > limits.MAX_SHORT_CONSTANTS) return error.TooManyConstants;

            try self.emitOp(.op_unpack);
            try self.emitByte(@intCast(elements.len));
            self.simulatePop(1);
            self.simulatePush(elements.len);

            var el_i: usize = elements.len;
            while (el_i > 0) {
                el_i -= 1;
                try self.compileDestructureNode(elements[el_i]);
            }
        } else {
            // MUST reject invalid tuple parameters (like splats or defaults) natively
            return error.UnknownNode;
        }
    }

    fn emitAugmentedOp(self: *Compiler, op: ast.BinaryOp) CompileError!void {
        switch (op) {
            .add => try self.emitOp(.op_add),
            .subtract => try self.emitOp(.op_subtract),
            .multiply => try self.emitOp(.op_multiply),
            .divide => try self.emitOp(.op_divide),
            .modulo => try self.emitOp(.op_modulo),
            .exponent => try self.emitOp(.op_exponent),
            .bitwise_and => try self.emitOp(.op_bitwise_and),
            .bitwise_or => try self.emitOp(.op_bitwise_or),
            .bitwise_xor => try self.emitOp(.op_bitwise_xor),
            .shift_left => try self.emitOp(.op_shift_left),
            .shift_right => try self.emitOp(.op_shift_right),
            else => return error.UnknownNode,
        }
    }

    fn compileClosureBlock(self: *Compiler, params: []const ast.Param, body_node: ast.NodeIndex, func_name: ?[]const u8, is_method: bool) CompileError!void {
        const func = try self.vm.gc.allocateFunction(self.vm);
        func.namespace = self.rootModuleNamespace();
        func.is_lambda = !is_method;

        // Root the function immediately: it is reachable from nothing else until
        // it lands in our constant pool, and every allocation below (its name,
        // the child's constants) may trigger a collection.
        self.vm.ensureStackCapacity(self.vm.stack_top + 1) catch return error.OutOfMemory;
        self.vm.push(value.Value.initObj(&func.obj));
        var func_rooted = true;
        errdefer if (func_rooted) {
            _ = self.vm.pop();
        };

        // Assign the method name so `super()` can dynamically look up the hierarchy
        if (func_name) |n| {
            const str_val = try self.vm.allocateString(n);
            func.name = @as(*value.ObjString, @alignCast(@fieldParentPtr("obj", str_val.asObj())));
        }

        var positional_count: usize = 0;
        var keyword_count: usize = 0;
        var splat_pos: ?u8 = null;
        var has_kwargs = false;

        // Frame slots and arity are u8 operands. Layout: slot 0 = closure,
        // 1..N = positionals (+ kwarg map), N+1 = block, then one virtual slot
        // per keyword param. Reject before any @intCast below can overflow.
        var needs_kwarg_map = false;
        for (params) |p| {
            if (p.is_keyword) keyword_count += 1;
            if (p.is_keyword or (p.modifier != null and p.modifier.? == .double_splat)) {
                needs_kwarg_map = true;
            } else if (p.modifier == null or p.modifier.? == .splat) {
                positional_count += 1;
            }
        }
        const highest_slot = positional_count + @intFromBool(needs_kwarg_map) + 1 + keyword_count;
        if (highest_slot > limits.MAX_ARGS) return error.TooManyParameters;
        positional_count = 0;

        for (params) |p| {
            if (p.modifier != null) {
                if (p.modifier.? == .splat or p.modifier.? == .double_splat) {
                    if (p.modifier.? == .splat) splat_pos = @intCast(positional_count);
                }
            }
            if (p.is_keyword or (p.modifier != null and p.modifier.? == .double_splat)) {
                has_kwargs = true;
            } else if (p.modifier == null or p.modifier.? == .splat) {
                positional_count += 1;
            }
        }

        // Kwargs are passed as a single Dictionary map taking exactly 1 positional slot
        const kwarg_slot_offset = positional_count;
        if (has_kwargs) positional_count += 1;
        // Include the implicit block slot in the arity so the VM pads it with nil when omitted
        func.arity = @intCast(positional_count);
        func.splat_pos = splat_pos;

        const child_chunk = try self.allocator.create(chunk.Chunk);
        child_chunk.* = chunk.Chunk.init();
        func.chunk = child_chunk;

        var child_compiler = Compiler{
            .allocator = self.allocator,
            .tree = self.tree,
            .script_globals = .empty,
            .imported_symbols = .empty,
            .symbols = self.symbols,
            .token_starts = self.token_starts,
            .current_chunk = child_chunk,
            .vm = self.vm,
            .enclosing = self,
            .function = func,
            .is_method = is_method,
            .has_export_module = false,
            .active_namespaces = self.active_namespaces,
            .namespace_stack = try self.namespace_stack.clone(self.allocator), // Inherit lexical scope dynamically
            .upvalues = .empty,
            .locals = .empty,
            .loops = .empty,
            .scratch_ops = .empty,
            .scratch_rights = .empty,
            .current_stack_depth = 0,
            .max_stack_depth = 0,
            // Carry the recursion depth over: the child compiles on the same native
            // stack, so nested defs/blocks must count toward the same limit.
            .ast_depth = self.ast_depth,
            .current_source_offset = self.current_source_offset,
            .max_local_slot = 0,
            .seeded_locals = &.{},
            .seeded_slot_offset = 0,
        };
        defer child_compiler.deinit();

        // Reserve slot 0 for the closure itself
        try child_compiler.addLocal(.none, 0);

        var current_slot: u8 = 1;
        // The kwarg map goes AFTER the standard positionals
        const map_slot = if (has_kwargs) @as(u8, @intCast(kwarg_slot_offset + 1)) else 0;

        for (params) |param| {
            if (param.modifier != null and param.modifier.? == .block) {
                try child_compiler.addLocal(param.name, @intCast(positional_count + 1));
            } else if (param.is_keyword) {
                // Handled dynamically via virtual slots below
            } else if (param.modifier != null and param.modifier.? == .double_splat) {
                try child_compiler.addLocal(param.name, map_slot);
            } else {
                try child_compiler.addLocal(param.name, current_slot);
                current_slot += 1;
            }
        }

        // Reserve slot (positional_count + 1) for the implicit block slot safely
        while (child_compiler.locals.items.len <= positional_count + 1) {
            try child_compiler.addLocal(.none, @intCast(child_compiler.locals.items.len));
        }

        // u16 like addLocal's slot: the check above caps the LAST keyword's slot at
        // MAX_ARGS (255), so a u8 counter overflowed on its final `+= 1`, and its
        // start value (block slot + 1) already overflowed with zero keywords.
        var virtual_slot: u16 = @intCast(positional_count + 2);
        for (params) |param| {
            if (param.is_keyword) {
                try child_compiler.addLocal(param.name, virtual_slot);
                virtual_slot += 1;
            }
        }

        if (has_kwargs) {
            for (params) |param| {
                if (param.is_keyword) {
                    const name_str = self.tree.getString(param.name);
                    const kw_name_idx = try child_compiler.makeSymbolConstant(name_str);

                    if (kw_name_idx <= limits.MAX_SHORT_CONSTANTS) {
                        try child_compiler.emitOp(.op_extract_kwarg);
                        try child_compiler.emitByte(map_slot);
                        try child_compiler.emitByte(@intCast(kw_name_idx));
                    } else {
                        try child_compiler.emitOp(.op_extract_kwarg_wide);
                        try child_compiler.emitByte(map_slot);
                        try child_compiler.emitByte(@intCast((kw_name_idx >> 8) & 0xff));
                        try child_compiler.emitByte(@intCast(kw_name_idx & 0xff));
                    }

                    if (param.default_value != .none) {
                        // The extracted value is already sitting on top of the stack.
                        // Peek at it. If it is NOT nil, jump directly to setting the local variable.
                        const skip_default_jump = try child_compiler.emitJump(.op_jump_if_not_nil);

                        // If it IS nil, pop the nil and evaluate the default AST expression
                        try child_compiler.emitOp(.op_pop);
                        try child_compiler.compileNode(param.default_value);

                        // The landing zone for the jump
                        child_compiler.patchJump(skip_default_jump);
                    }

                    const local_slot = child_compiler.resolveLocal(param.name).?;
                    try child_compiler.emitOpWithOperand(.op_set_local, .op_set_local_wide, local_slot);
                    try child_compiler.emitOp(.op_pop);
                }
            }
        }

        // Positional Parameter Defaults Handling
        for (params) |param| {
            if (!param.is_keyword and param.modifier == null and param.default_value != .none) {
                if (child_compiler.resolveLocal(param.name)) |local_slot| {
                    // Read the padded parameter from the stack
                    try child_compiler.emitOpWithOperand(.op_get_local, .op_get_local_wide, local_slot);

                    // If the caller provided an argument (it is NOT nil), jump over the default assignment
                    const skip_default_jump = try child_compiler.emitJump(.op_jump_if_not_nil);

                    // If it IS nil, pop the nil and evaluate the default AST expression
                    try child_compiler.emitOp(.op_pop);
                    try child_compiler.compileNode(param.default_value);

                    // Store the evaluated default back into the local variable slot
                    try child_compiler.emitOpWithOperand(.op_set_local, .op_set_local_wide, local_slot);

                    // The landing zone for the jump
                    child_compiler.patchJump(skip_default_jump);

                    // Clean up the stack (pop the result of set_local or the unskipped get_local)
                    try child_compiler.emitOp(.op_pop);
                }
            }
        }

        try child_compiler.compile(body_node);

        // Extract the exact local footprint from the child AFTER compiling
        func.local_count = @max(child_compiler.locals.items.len, child_compiler.max_local_slot + 1);

        const func_val = value.Value.initObj(&func.obj);
        const func_idx = try self.makeConstant(func_val);
        // Now owned by our constant pool; unroot exactly once
        _ = self.vm.pop();
        func_rooted = false;

        try self.emitOpWithOperand(.op_closure, .op_closure_wide, func_idx);

        for (child_compiler.upvalues.items) |upv| {
            try self.emitByte(if (upv.is_local) 1 else 0);
            try self.emitByte(@intCast((upv.index >> 8) & 0xff));
            try self.emitByte(@intCast(upv.index & 0xff));
        }
    }
};
