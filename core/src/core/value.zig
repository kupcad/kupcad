const std = @import("std");
const dag = @import("../vm/dag.zig");
const topology = @import("../kernel/engines/brep/topology.zig");
const geom = @import("../kernel/geometry_handle.zig");

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
    native,
    brep,
    array,
    map,
    function,
    upvalue,
    closure,
    class,
    instance,
    bound_method,
    geometry,
    workplane,
};

/// The Base Header for ALL heap-allocated objects.
/// Every complex object must start with this struct so the GC can trace it.
/// Note: ObjGeometry uses this header to fit in the Value union,
/// but explicitly leaves `next` as null so the GC ignores it.
pub const Obj = struct {
    obj_type: ObjType,
    is_marked: bool,
    next: ?*Obj, // Tracing GC header (ObjGeometry leaves this null)
};

/// A heap-allocated String Object.
pub const ObjString = struct {
    obj: Obj,
    chars: []const u8,
};

pub const ObjArray = struct {
    obj: Obj,
    items: std.ArrayListUnmanaged(Value),
};

pub const ObjMap = struct {
    obj: Obj,
    keys: std.ArrayListUnmanaged(Value),
    values: std.ArrayListUnmanaged(Value),
};

pub const ObjFunction = struct {
    obj: Obj,
    arity: u8,
    upvalue_count: u16,
    chunk: ?*anyopaque, // Pointer to chunk.Chunk (avoids circular dependency)
    name: ?*ObjString,
    owns_chunk: bool,
};

pub const ObjUpvalue = struct {
    obj: Obj,
    location: *Value, // Points to the stack initially
    closed: Value, // Holds the value once it escapes the stack
    next: ?*ObjUpvalue,
};

pub const ObjClosure = struct {
    obj: Obj,
    function: *ObjFunction,
    upvalues: [*]?*ObjUpvalue,
};

pub const ObjClass = struct {
    obj: Obj,
    name: *ObjString,
    methods: std.StringHashMapUnmanaged(Value),
};

pub const ObjInstance = struct {
    obj: Obj,
    class: *ObjClass,
    fields: std.StringHashMapUnmanaged(Value),
};

pub const ObjBoundMethod = struct {
    obj: Obj,
    receiver: Value,
    method: *ObjClosure,
};

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const GeometryState = union(enum) {
    symbolic: dag.DAGNodeIndex,
    concrete: geom.GeometryHandle,
};

pub const BBox = struct {
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,
};

pub const TopologyCache = struct {
    is_populated: bool,
    // Future: HashMap mapping FaceFilters to cached FaceHandles
};

pub const ObjWorkplane = struct {
    obj: Obj,
    ref_count: u32,
    parent: *ObjGeometry,
    origin: [3]f64,
    normal: [3]f64,
};

/// The Hybrid ARC-managed Geometry Object.
pub const ObjGeometry = struct {
    obj: Obj, // Must be first field for safe casting
    ref_count: u32 = 1, // Managed explicitly by VM push/pop, NOT the GC

    // The DAG root index representing how this geometry was formed.
    // We retain this permanently so we can always append to it later.
    dag_idx: dag.DAGNodeIndex,

    // Optional memoized properties populated via JIT evaluation
    cached_handle: ?geom.GeometryHandle = null,
    cached_bbox: ?BBox = null,
    cached_topology: ?*TopologyCache,

    pub fn isConcrete(self: *const ObjGeometry) bool {
        return self.cached_handle != null;
    }
};

/// Signature for all Native CAD Built-ins
/// Takes an opaque VM pointer to avoid circular imports, argument count, and a pointer to the first argument on the stack.
pub const NativeFn = *const fn (vm: *anyopaque, arg_count: u8, args: [*]Value) anyerror!Value;

pub const ObjNative = struct {
    obj: Obj,
    function: NativeFn,
};

pub const ObjBrep = struct {
    obj: Obj,
    data: *topology.Brep, // Pointer to the pure Zig B-Rep data
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

    pub fn initGeometry(ptr: *ObjGeometry) Value {
        return .{ .tag = .object, .payload = .{ .obj = &ptr.obj } };
    }

    pub inline fn initWorkplane(ptr: *ObjWorkplane) Value {
        return initObj(&ptr.obj);
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

    pub inline fn isString(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .string;
    }

    pub inline fn isArray(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .array;
    }

    pub inline fn isMap(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .map;
    }

    pub inline fn isClosure(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .closure;
    }

    pub inline fn isClass(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .class;
    }

    pub inline fn isInstance(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .instance;
    }

    pub inline fn isBoundMethod(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .bound_method;
    }

    pub inline fn isObjType(self: Value, obj_type: ObjType) bool {
        return self.isObject() and self.asObj().obj_type == obj_type;
    }

    pub inline fn isNative(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .native;
    }

    pub inline fn isBrep(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .brep;
    }

    pub inline fn isGeometry(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .geometry;
    }

    pub inline fn isWorkplane(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .workplane;
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

    pub inline fn asString(self: Value) []const u8 {
        std.debug.assert(self.isString());
        const str_obj: *ObjString = @alignCast(@fieldParentPtr("obj", self.asObj()));
        return str_obj.chars;
    }

    pub inline fn asArray(self: Value) *ObjArray {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    pub inline fn asMap(self: Value) *ObjMap {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    pub inline fn asClosure(self: Value) *ObjClosure {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    pub inline fn asClass(self: Value) *ObjClass {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    pub inline fn asInstance(self: Value) *ObjInstance {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    pub inline fn asBoundMethod(self: Value) *ObjBoundMethod {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    pub inline fn asNative(self: Value) *ObjNative {
        std.debug.assert(self.isNative());
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    pub inline fn asGeometry(self: Value) *ObjGeometry {
        std.debug.assert(self.isGeometry());
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    pub inline fn asWorkplane(self: Value) *ObjWorkplane {
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

    /// Safely stringifies values recursively using the new Zig 0.16 Io.Writer interface.
    pub fn stringify(self: Value, is_inspect: bool, writer: *std.Io.Writer) !void {
        if (self.isNumber()) {
            try writer.print("{d}", .{self.asNumber()});
        } else if (self.isBool()) {
            try writer.writeAll(if (self.asBool()) "true" else "false");
        } else if (self.isNil()) {
            try writer.writeAll("nil");
        } else if (self.isObject()) {
            const obj = self.asObj();
            switch (obj.obj_type) {
                .string => {
                    const str_obj = @as(*ObjString, @alignCast(@fieldParentPtr("obj", obj)));
                    if (is_inspect) {
                        try writer.print("\"{s}\"", .{str_obj.chars});
                    } else {
                        try writer.writeAll(str_obj.chars);
                    }
                },
                .array => {
                    const arr = @as(*ObjArray, @alignCast(@fieldParentPtr("obj", obj)));
                    try writer.writeAll("[");
                    for (arr.items.items, 0..) |item, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try item.stringify(true, writer); // Force inspect mode for nested items
                    }
                    try writer.writeAll("]");
                },
                .map => {
                    const map = @as(*ObjMap, @alignCast(@fieldParentPtr("obj", obj)));
                    try writer.writeAll("{");
                    for (map.keys.items, 0..) |key, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try key.stringify(true, writer);
                        try writer.writeAll(": ");
                        try map.values.items[i].stringify(true, writer);
                    }
                    try writer.writeAll("}");
                },
                .class => {
                    const cls = @as(*ObjClass, @alignCast(@fieldParentPtr("obj", obj)));
                    try writer.print("<Class {s}>", .{cls.name.chars});
                },
                .instance => {
                    const inst = @as(*ObjInstance, @alignCast(@fieldParentPtr("obj", obj)));
                    try writer.print("<Instance of {s}>", .{inst.class.name.chars});
                },
                .closure, .function => try writer.writeAll("<Function>"),
                .native => try writer.writeAll("<Native Function>"),
                .bound_method => try writer.writeAll("<Bound Method>"),
                .geometry => try writer.print("<Geometry DAG:{d}>", .{@as(*ObjGeometry, @alignCast(@fieldParentPtr("obj", obj))).dag_idx}),
                .workplane => try writer.writeAll("<Workplane>"),
                else => try writer.writeAll("<Object>"),
            }
        }
    }
};

/// A dynamic array of Values (used for the VM Stack and constants arrays).
pub const ValueArray = std.ArrayListUnmanaged(Value);
