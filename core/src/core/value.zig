const std = @import("std");

/// Identifies the primitive type of a Value.
pub const ValueTag = enum(u8) {
    number,
    boolean,
    nil,
    symbol,
    object, // Points to a heap-allocated Obj
};

/// Identifies the specific type of a heap-allocated Object.
pub const ObjType = enum(u8) {
    string,
    array,
    mesh,
    // Future additions: part, mesh, transform, etc.
};

/// The Base Header for ALL heap-allocated objects.
/// Every complex object must start with this struct so the GC can trace it.
pub const Obj = struct {
    obj_type: ObjType,
    is_marked: bool,
    next: ?*Obj, // Intrusive linked list for the Garbage Collector
};

/// A heap-allocated String Object.
pub const ObjString = struct {
    obj: Obj,
    chars: []const u8,
};

/// Represents a 3D Geometry Object in the VM
pub const ObjMesh = struct {
    obj: Obj,
    /// Pointer to the underlying C/C++ CAD kernel structure (e.g., CSG Node or BRep)
    kernel_handle: ?*anyopaque,
    /// Cached metadata for quick access in the VM without crossing the FFI boundary
    vertex_count: usize,
    face_count: usize,
};

/// The Universal 16-Byte Dynamic Value.
/// Passed by value in 2 CPU registers (no hidden pointer indirection overhead).
pub const Value = extern struct {
    tag: ValueTag,

    // 7 bytes of implicit padding exist here for alignment.

    payload: extern union {
        number: f64,
        boolean: bool,
        symbol: u32,
        obj: *Obj,
        _padding: u64, // Forces the union to always be exactly 8 bytes
    },

    // --- Initializers ---

    pub inline fn initNumber(val: f64) Value {
        return .{ .tag = .number, .payload = .{ .number = val } };
    }

    pub inline fn initBool(val: bool) Value {
        return .{ .tag = .boolean, .payload = .{ .boolean = val } };
    }

    pub inline fn initNil() Value {
        return .{ .tag = .nil, .payload = .{ ._padding = 0 } };
    }

    pub inline fn initSymbol(id: u32) Value {
        return .{ .tag = .symbol, .payload = .{ .symbol = id } };
    }

    pub inline fn initObj(obj: *Obj) Value {
        return .{ .tag = .object, .payload = .{ .obj = obj } };
    }

    // --- Type Checkers ---

    pub inline fn isNumber(self: Value) bool {
        return self.tag == .number;
    }
    pub inline fn isBool(self: Value) bool {
        return self.tag == .boolean;
    }
    pub inline fn isNil(self: Value) bool {
        return self.tag == .nil;
    }
    pub inline fn isSymbol(self: Value) bool {
        return self.tag == .symbol;
    }
    pub inline fn isObject(self: Value) bool {
        return self.tag == .object;
    }

    pub inline fn isObjType(self: Value, obj_type: ObjType) bool {
        return self.isObject() and self.asObj().obj_type == obj_type;
    }

    pub inline fn isMesh(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .mesh;
    }

    // --- Safe Accessors (with safety assertions) ---

    pub inline fn asNumber(self: Value) f64 {
        std.debug.assert(self.tag == .number);
        return self.payload.number;
    }

    pub inline fn asBool(self: Value) bool {
        std.debug.assert(self.tag == .boolean);
        return self.payload.boolean;
    }

    pub inline fn asSymbol(self: Value) u32 {
        std.debug.assert(self.tag == .symbol);
        return self.payload.symbol;
    }

    pub inline fn asObj(self: Value) *Obj {
        std.debug.assert(self.tag == .object);
        return self.payload.obj;
    }

    pub inline fn asString(self: Value) *ObjString {
        std.debug.assert(self.isObjType(.string));
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    pub inline fn asMesh(self: Value) *ObjMesh {
        std.debug.assert(self.isMesh());
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    // --- Equality Check ---

    pub fn eql(a: Value, b: Value) bool {
        if (a.tag != b.tag) return false;
        return switch (a.tag) {
            .nil => true,
            .boolean => a.asBool() == b.asBool(),
            .number => a.asNumber() == b.asNumber(),
            .symbol => a.asSymbol() == b.asSymbol(),
            // For objects, we check pointer equality (interned strings, exact objects)
            .object => a.asObj() == b.asObj(),
        };
    }
};

/// A dynamic array of Values (used for the VM Stack and constants arrays).
pub const ValueArray = std.ArrayListUnmanaged(Value);
