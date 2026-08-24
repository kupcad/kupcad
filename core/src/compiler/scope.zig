const std = @import("std");
const ast = @import("../core/ast.zig");
const resolver = @import("../core/resolver.zig");
const limits = @import("../vm/limits.zig");
const Compiler = @import("compiler.zig").Compiler;
const CompileError = @import("compiler.zig").CompileError;

pub const Upvalue = struct {
    index: u16,
    is_local: bool,
};

pub const Local = struct {
    name_id: ast.StringId,
    slot: u16,
};

pub const LoopState = struct {
    start: usize,
    depth: usize,
    exit_jumps: std.ArrayListUnmanaged(usize) = .empty,
};

pub const VarType = enum {
    constant,
    class_var,
    instance_var,
    local,
    upvalue,
    global,
    new_local,
};

pub const ResolvedVar = struct {
    kind: VarType,
    index: usize = 0,
};

// --- Lexical Scope Resolvers ---

pub fn classifyVariable(self: *Compiler, name_id: ast.StringId, sym_opt: ?resolver.ResolvedSymbol) CompileError!ResolvedVar {
    const name_str = self.tree.getString(name_id);
    if (std.ascii.isUpper(name_str[0])) return .{ .kind = .constant };
    if (std.mem.startsWith(u8, name_str, "@@")) return .{ .kind = .class_var };
    if (std.mem.startsWith(u8, name_str, "@")) return .{ .kind = .instance_var };

    if (self.resolveLocal(name_id)) |slot| return .{ .kind = .local, .index = slot };
    if (try self.resolveUpvalue(name_id)) |upv_slot| return .{ .kind = .upvalue, .index = upv_slot };

    if (sym_opt) |sym| {
        if (sym.kind == .global or self.enclosing == null or self.isScriptGlobal(name_id)) {
            return .{ .kind = .global };
        }
        return .{ .kind = .new_local };
    }

    return .{ .kind = .global };
}

pub fn buildFullyQualifiedPath(self: *Compiler, target: []const u8, depth: usize) CompileError![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(self.allocator);

    for (self.namespace_stack.items[0..depth]) |ns_id| {
        try buf.appendSlice(self.allocator, self.tree.getString(ns_id));
        try buf.appendSlice(self.allocator, "::");
    }
    try buf.appendSlice(self.allocator, target);

    // Return the owned slice directly to prevent duping leaks
    return try buf.toOwnedSlice(self.allocator);
}

pub fn addLocal(self: *Compiler, name_id: ast.StringId, slot: u16) CompileError!void {
    // Allow anonymous padding slots (.none) to bypass deduplication ---
    if (name_id != .none) {
        for (self.locals.items) |loc| {
            if (loc.name_id == name_id) return;
        }
    }
    if (self.locals.items.len >= limits.MAX_LOCALS) return error.TooManyLocals;
    try self.locals.append(self.allocator, .{ .name_id = name_id, .slot = slot });
    if (slot > self.max_local_slot) self.max_local_slot = slot;

    // --- DEBUGGER METADATA: Track local names ---
    const name_str = if (name_id != .none) self.tree.getString(name_id) else "<anonymous>";

    // Pad the array dynamically since block parameters can be registered out-of-order
    while (self.current_chunk.local_names.items.len <= slot) {
        try self.current_chunk.local_names.append(self.allocator, "<anonymous>");
    }
    self.current_chunk.local_names.items[slot] = name_str;
}

pub fn resolveLocal(self: *Compiler, name_id: ast.StringId) ?u16 {
    const target_str = self.tree.getString(name_id);
    var i: usize = self.locals.items.len;
    while (i > 0) {
        i -= 1;
        const loc = self.locals.items[i];
        if (loc.name_id != .none) {
            if (std.mem.eql(u8, self.tree.getString(loc.name_id), target_str)) return loc.slot;
        }
    }

    for (self.seeded_locals, 0..) |seeded_name, idx| {
        if (std.mem.eql(u8, seeded_name, target_str)) return @intCast(idx + self.seeded_slot_offset);
    }

    return null;
}

pub fn resolveUpvalue(self: *Compiler, name_id: ast.StringId) CompileError!?u8 {
    if (self.enclosing == null) return null;
    const enclosing = self.enclosing.?;

    // Look for it as a direct local variable in the parent
    if (enclosing.resolveLocal(name_id)) |local_idx| {
        return try self.addUpvalue(local_idx, true);
    }

    // Recursively look up the scope chain for an already captured upvalue
    if (try enclosing.resolveUpvalue(name_id)) |upv_idx| {
        return try self.addUpvalue(upv_idx, false);
    }

    return null;
}

pub fn resolveSelfUpvalue(self: *Compiler) CompileError!?u8 {
    if (self.enclosing == null) return null;
    const enclosing = self.enclosing.?;

    if (enclosing.is_method) {
        // The parent IS a method. Its `self` is at local 0.
        return try self.addUpvalue(0, true);
    }

    // The parent is also a block. Recursively capture.
    if (try enclosing.resolveSelfUpvalue()) |upv_idx| {
        return try self.addUpvalue(upv_idx, false);
    }

    return null;
}

pub fn addUpvalue(self: *Compiler, index: u16, is_local: bool) CompileError!u8 {
    for (self.upvalues.items, 0..) |upv, i| {
        if (upv.index == index and upv.is_local == is_local) {
            return @intCast(i);
        }
    }
    if (self.upvalues.items.len >= limits.MAX_UPVALUES) return error.TooManyLocals;
    try self.upvalues.append(self.allocator, .{ .index = index, .is_local = is_local });
    if (self.function) |f| f.upvalue_count = @intCast(self.upvalues.items.len);
    return @intCast(self.upvalues.items.len - 1);
}

pub fn isScriptGlobal(self: *Compiler, name_id: ast.StringId) bool {
    var root: *Compiler = self;
    while (root.enclosing) |parent| {
        root = parent;
    }

    // Use pure string lookup to bypass integer ID caching discrepancies
    const name_str = self.tree.getString(name_id);
    return root.script_globals.contains(name_str);
}

pub fn seedLocals(self: *Compiler, names: []const []const u8, offset: u16) void {
    self.seeded_locals = names;
    self.seeded_slot_offset = offset;
    if (names.len > 0) {
        self.max_local_slot = @intCast(names.len + offset - 1);
    }
}

pub fn getNextLocalSlot(self: *Compiler) u16 {
    return @as(u16, @intCast(self.locals.items.len + self.seeded_locals.len + self.seeded_slot_offset));
}
