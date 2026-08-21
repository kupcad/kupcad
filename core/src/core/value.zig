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
    symbol,
    native,
    brep,
    array,
    map,
    function,
    upvalue,
    closure,
    class,
    module,
    instance,
    bound_method,
    range,
    cross_section,
    geometry,
    workplane,
};

/// The Base Header for ALL heap-allocated objects.
pub const Obj = struct {
    obj_type: ObjType,
    is_marked: bool,
};

/// A heap-allocated String Object.
pub const ObjString = struct {
    obj: Obj,
    chars: []const u8,
};

pub const ObjSymbol = struct {
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
    local_count: usize,
    splat_pos: ?u8,
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
    superclass: ?*ObjClass = null,
    methods: std.StringHashMapUnmanaged(Value),
    class_methods: std.StringHashMapUnmanaged(Value),
    class_fields: std.StringHashMapUnmanaged(Value),
    included_modules: std.ArrayListUnmanaged(*ObjModule),
    instance_layout: std.StringHashMapUnmanaged(usize),
};

pub const ObjModule = struct {
    obj: Obj,
    name: *ObjString,
    methods: std.StringHashMapUnmanaged(Value),
};

pub const ObjInstance = struct {
    obj: Obj,
    class: *ObjClass,
    fields: std.ArrayListUnmanaged(Value),
};

pub const ObjBoundMethod = struct {
    obj: Obj,
    receiver: Value,
    method: *ObjClosure,
};

pub const ObjRange = struct {
    obj: Obj,
    start: f64,
    end: f64,
    step: f64,
    is_exclusive: bool,
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
    parent: *ObjGeometry,
    origin: [3]f64,
    normal: [3]f64,
};

/// The Hybrid ARC-managed Geometry Object.
pub const ObjGeometry = struct {
    obj: Obj, // Must be first field for safe casting

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

pub const ObjCrossSection = struct {
    obj: Obj,
    dag_idx: u32,
    cached_handle: ?@import("../kernel/geometry_handle.zig").CrossSectionHandle,
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

// --- NaN Tagging Constants ---
const QNAN: u64 = 0x7FFC000000000000;
const SIGN_BIT: u64 = 0x8000000000000000;

const TAG_NIL: u64 = 1;
const TAG_FALSE: u64 = 2;
const TAG_TRUE: u64 = 3;

const VAL_NIL: u64 = QNAN | TAG_NIL;
const VAL_FALSE: u64 = QNAN | TAG_FALSE;
const VAL_TRUE: u64 = QNAN | TAG_TRUE;
const TAG_OBJ: u64 = SIGN_BIT | QNAN;

/// A completely unboxed, 8-byte value payload.
pub const Value = packed struct {
    val: u64,

    // --- Constructors ---

    pub inline fn initNumber(num: f64) Value {
        return .{ .val = @bitCast(num) };
    }

    pub inline fn initNil() Value {
        return .{ .val = VAL_NIL };
    }

    pub inline fn initBool(b: bool) Value {
        return .{ .val = if (b) VAL_TRUE else VAL_FALSE };
    }

    pub inline fn initObj(obj: *Obj) Value {
        // Embed the pointer (32-bit in WASM, 48-bit on Desktop) into the 52-bit mantissa space
        return .{ .val = TAG_OBJ | @as(u64, @intFromPtr(obj)) };
    }

    pub inline fn initGeometry(geom_obj: *ObjGeometry) Value {
        return initObj(&geom_obj.obj);
    }

    pub inline fn initCrossSection(cs: *ObjCrossSection) Value {
        return initObj(&cs.obj);
    }

    pub inline fn initWorkplane(wp: *ObjWorkplane) Value {
        return initObj(&wp.obj);
    }

    // --- Type Checkers ---

    pub inline fn isNumber(self: Value) bool {
        // If it isn't completely matching the QNAN mask, it's a valid IEEE float!
        return (self.val & QNAN) != QNAN;
    }

    pub inline fn isNil(self: Value) bool {
        return self.val == VAL_NIL;
    }

    pub inline fn isBool(self: Value) bool {
        return self.val == VAL_TRUE or self.val == VAL_FALSE;
    }

    pub inline fn isObject(self: Value) bool {
        // Check if the Sign Bit and QNAN bits are set, indicating a Heap Pointer
        return (self.val & TAG_OBJ) == TAG_OBJ;
    }

    // --- Data Extractors ---

    pub inline fn asNumber(self: Value) f64 {
        std.debug.assert(self.isNumber());
        return @bitCast(self.val);
    }

    pub inline fn asBool(self: Value) bool {
        std.debug.assert(self.isBool());
        return self.val == VAL_TRUE;
    }

    pub inline fn asObj(self: Value) *Obj {
        std.debug.assert(self.isObject());
        // Mask out the TAG_OBJ bits to reveal the raw memory pointer
        const ptr_val = self.val & ~TAG_OBJ;
        // Explicitly cast to `usize` so WASM32 safely accepts it
        return @ptrFromInt(@as(usize, @intCast(ptr_val)));
    }

    // --- Sub-type Checkers (Convenience) ---

    pub inline fn isGeometry(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .geometry;
    }
    pub inline fn isCrossSection(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .cross_section;
    }
    pub inline fn isWorkplane(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .workplane;
    }
    pub inline fn isInstance(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .instance;
    }
    pub inline fn isClass(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .class;
    }
    pub inline fn isModule(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .module;
    }
    pub inline fn isClosure(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .closure;
    }
    pub inline fn isNative(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .native;
    }
    pub inline fn isArray(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .array;
    }
    pub inline fn isString(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .string;
    }

    // --- Sub-type Extractors ---

    pub inline fn asGeometry(self: Value) *ObjGeometry {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asCrossSection(self: Value) *ObjCrossSection {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asWorkplane(self: Value) *ObjWorkplane {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asInstance(self: Value) *ObjInstance {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asClass(self: Value) *ObjClass {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asModule(self: Value) *ObjModule {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asClosure(self: Value) *ObjClosure {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asNative(self: Value) *ObjNative {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asArray(self: Value) *ObjArray {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asMap(self: Value) *ObjMap {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    // Safely unwrap String and Symbol objects directly to their inner char slices
    pub inline fn asString(self: Value) []const u8 {
        std.debug.assert(self.isString());
        return @as(*ObjString, @alignCast(@fieldParentPtr("obj", self.asObj()))).chars;
    }
    pub inline fn asSymbol(self: Value) []const u8 {
        std.debug.assert(self.isObject() and self.asObj().obj_type == .symbol);
        return @as(*ObjSymbol, @alignCast(@fieldParentPtr("obj", self.asObj()))).chars;
    }

    // --- Operations & Equality ---

    pub inline fn isEqual(self: Value, other: Value) bool {
        // Direct register comparison for fast-path equality!
        // Handles interned Strings, Symbols, Booleans, Nils, and exact Object instances in O(1).
        if (self.val == other.val) return true;

        // Fallback for IEEE 754 float nuances (+0.0 == -0.0)
        if (self.isNumber() and other.isNumber()) {
            return self.asNumber() == other.asNumber();
        }
        return false;
    }

    // Alias eql to isEqual to support any lingering tests using the old naming convention
    pub inline fn eql(self: Value, other: Value) bool {
        return self.isEqual(other);
    }

    pub inline fn isFalsey(self: Value) bool {
        return self.isNil() or (self.isBool() and !self.asBool());
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
                .symbol => {
                    const sym = @as(*ObjSymbol, @alignCast(@fieldParentPtr("obj", obj)));
                    try writer.print(":{s}", .{sym.chars});
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
                .range => {
                    const r = @as(*ObjRange, @alignCast(@fieldParentPtr("obj", obj)));
                    const op_str = if (r.is_exclusive) "..." else "..";
                    try writer.print("{d}{s}{d}", .{ r.start, op_str, r.end });
                },
                .geometry => try writer.print("<Geometry DAG:{d}>", .{@as(*ObjGeometry, @alignCast(@fieldParentPtr("obj", obj))).dag_idx}),
                .cross_section => {
                    const cs = @as(*ObjCrossSection, @alignCast(@fieldParentPtr("obj", obj)));
                    try writer.print("<CrossSection DAG:{d}>", .{cs.dag_idx});
                },
                .workplane => try writer.writeAll("<Workplane>"),
                else => try writer.writeAll("<Object>"),
            }
        }
    }
};

/// A dynamic array of Values (used for the VM Stack and constants arrays).
pub const ValueArray = std.ArrayListUnmanaged(Value);
