//! The VM's runtime values: `Value`, a NaN-boxed 8-byte number, nil, boolean or object
//! pointer, and the heap objects it points to (`ObjString`, `ObjArray`, `ObjClosure`,
//! `ObjClass`, `ObjGeometry`, ...), with number formatting and `Value.stringify` printing.

const std = @import("std");
const dag = @import("../vm/dag.zig");
const geom = @import("../kernel/geometry_handle.zig");
const owned_keys = @import("owned_keys.zig");
const path_mod = @import("path.zig");
const lexer = @import("../frontend/lexer.zig");

/// Below this magnitude plain notation prints a long run of zeros (0.0000001), so numbers
/// print in scientific notation instead (1e-7), as in JavaScript.
const MIN_PLAIN_MAGNITUDE = 1e-6;
/// From this magnitude plain notation prints a long digit string (1e300 had 301 digits).
/// It is the first power of ten past 2^53, where f64 stops holding every integer exactly:
/// plain digits above it look exact but aren't (2^60 printed as 1152921504606846976).
/// Ruby and Crystal switch at the same point.
const MAX_PLAIN_MAGNITUDE = 1e16;

/// Containers nested deeper than this print as `[...]`; see Printing.
const MAX_STRINGIFY_DEPTH = 256;

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
/// The one NaN a number Value holds. Any other NaN may carry payload bits that QNAN
/// tests for (bit 50 is one of them), which made it read as nil, a boolean or a pointer.
const CANONICAL_NAN: u64 = 0x7FF8000000000000;
comptime {
    if (CANONICAL_NAN & QNAN == QNAN) @compileError("the canonical NaN must not look like a tagged value");
}

/// Identifies the specific type of a heap-allocated Object.
pub const ObjType = enum(u8) {
    string,
    symbol,
    native,
    array,
    map,
    json_object,
    function,
    upvalue,
    closure,
    class,
    module,
    instance,
    bound_method,
    range,
    bbox,
    cross_section,
    /// An open 2D path (core/path.zig): lines and arcs from a start.
    path,
    geometry,
    assembly,
    workplane,
    font,
};

/// The Base Header for ALL heap-allocated objects.
pub const Obj = struct {
    obj_type: ObjType,
    is_marked: bool,

    /// The object this header begins: `obj.as(ObjArray)` for one whose obj_type is .array.
    pub inline fn as(self: *Obj, comptime T: type) *T {
        return @alignCast(@fieldParentPtr("obj", self));
    }
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
    items: std.ArrayList(Value),
};

/// Defines the Hashing and Equality rules for O(1) Map lookups
pub const ValueContext = struct {
    pub fn hash(self: ValueContext, key: Value) u32 {
        _ = self;
        var x = key.val;

        // SplitMix64 / MurmurHash3 avalanche step.
        // These "magic numbers" are statistically chosen large odd constants.
        // Multiplying by them forces a high degree of bit diffusion (the avalanche effect),
        // ensuring tightly clustered keys (like 1.0, 2.0, 3.0) produce wildly different hashes.
        x ^= x >> 30;
        x *%= 0xbf58476d1ce4e5b9;
        x ^= x >> 27;
        x *%= 0x94d049bb133111eb;
        x ^= x >> 31;

        return @truncate(x);
    }

    pub fn eql(self: ValueContext, a: Value, b: Value, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return a.isEqual(b);
    }
};

/// Values by Value, in insertion order: a Map's entries, a JsonObject's.
pub const ValueMap = std.array_hash_map.Custom(Value, Value, ValueContext, false);

pub const ObjMap = struct {
    obj: Obj,
    map: ValueMap,
};

/// A JSON object `import_json` read (class JsonObject): read-only, its keys Strings as the
/// file has them, each found by that String or by the Symbol of the same name
/// (VM.jsonObjectGet). `source` (the file) and `path` (where in it, as `gears[0]`; empty
/// for the file's own object) are for the errors `fetch` and `dig` raise.
pub const ObjJsonObject = struct {
    obj: Obj,
    map: ValueMap,
    source: *ObjString,
    path: *ObjString,
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
    /// A lambda or block: a value, called with `.call(...)`. A `def` is called by name.
    is_lambda: bool,
    /// A `def`. Neither this nor `is_lambda`: a script's or module's top-level code.
    is_method: bool,
    /// Positional parameters without a default: the fewest arguments a def accepts.
    min_args: u8,
    /// Declares keyword parameters or `**opts`: the slot after the positionals (the last
    /// of `arity`) holds the call's keyword Map.
    has_kwargs: bool,
    /// Top-level scope this function's global reads/writes go to: null for the main
    /// script (VM.globals), otherwise the namespace of the imported module it came from.
    namespace: ?*Namespace,
};

/// The top-level variables of one imported module. Each module gets its own, so its
/// top-level names never leak into (or get overwritten by) the importer: only exported
/// names cross files. Owned by the VM (VM.module_namespaces); values are GC roots.
pub const Namespace = struct {
    globals: std.StringHashMapUnmanaged(Value) = .empty,

    pub fn define(self: *Namespace, allocator: std.mem.Allocator, name: []const u8, val: Value) !void {
        (try owned_keys.getOrPutOwned(&self.globals, allocator, name)).value_ptr.* = val;
    }

    pub fn remove(self: *Namespace, allocator: std.mem.Allocator, name: []const u8) void {
        const kv = self.globals.fetchRemove(name) orelse return;
        allocator.free(kv.key);
    }

    pub fn deinit(self: *Namespace, allocator: std.mem.Allocator) void {
        var it = self.globals.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        self.globals.deinit(allocator);
    }
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
    /// A method's: the class it was defined in (set when `def` binds it), so `super`
    /// starts above that class and a private call is allowed from inside it.
    home_class: ?*ObjClass,
    /// A block's or lambda's: the method it was written in (null at top level), and that
    /// method's receiver and block, so `yield`, `super`, `self` and a private call inside
    /// the block mean what they mean in the method. They used to read the block's own
    /// frame, where slot 0 is the block and the block slot is empty.
    home: ?*ObjClosure,
    home_self: Value,
    home_block: Value,
};

pub const ObjClass = struct {
    obj: Obj,
    name: *ObjString,
    superclass: ?*ObjClass = null,
    methods: std.array_hash_map.Custom(Value, Value, ValueContext, false),
    class_methods: std.array_hash_map.Custom(Value, Value, ValueContext, false),
    class_fields: std.array_hash_map.Custom(Value, Value, ValueContext, false),
    included_modules: std.ArrayList(*ObjModule),
    instance_layout: std.array_hash_map.Custom(Value, usize, ValueContext, false),
    /// The class of a built-in kind of value (Array, Number, NilClass, Proc, ...), made by
    /// literals and methods, not by `.new`: a generic instance of it is no such value (it
    /// used to be: `Array.new` was an empty object, not an Array). Such a class may still
    /// define a `new` class method of its own.
    is_value_class: bool = false,
};

pub const ObjModule = struct {
    obj: Obj,
    name: *ObjString,
    methods: std.array_hash_map.Custom(Value, Value, ValueContext, false),
    /// The file whose exports these are, as op_import read it (null for a script's own
    /// `module M`), for the error about a name it doesn't export.
    exports_of: ?*ObjString = null,
};

pub const ObjInstance = struct {
    obj: Obj,
    class: *ObjClass,
    fields: std.ArrayList(Value),
};

pub const ObjBoundMethod = struct {
    obj: Obj,
    receiver: Value,
    method: Value,
};

/// Formats a script number for anything a user reads (puts, to_s, interpolation, error
/// messages): `NaN`, `Infinity` and `-Infinity` for non-finite values, as Ruby spells them,
/// otherwise `{d}`. Plain `{d}` prints the NaN's sign bit, which is platform-dependent
/// (`inf - inf` is `nan` on ARM but `-nan` on x86), so output differed between machines.
pub fn fmtNumber(n: f64) NumberFormat {
    return .{ .n = n };
}

/// `%` as in Ruby: floored, so the result takes the divisor's sign (7 % -3 is -2, -7 % 3
/// is 2). Shared by the VM and the compiler's constant folding. Zig's @mod on floats
/// gave 7 % -3 = 1.
pub fn flooredMod(a: f64, b: f64) f64 {
    const r = @rem(a, b);
    return if (r != 0 and (r < 0) != (b < 0)) r + b else r;
}

pub const NumberFormat = struct {
    n: f64,

    pub fn format(self: NumberFormat, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (std.math.isNan(self.n)) return w.writeAll("NaN");
        if (std.math.isInf(self.n)) return w.writeAll(if (self.n > 0) "Infinity" else "-Infinity");
        const mag = @abs(self.n);
        if (mag != 0.0 and (mag < MIN_PLAIN_MAGNITUDE or mag >= MAX_PLAIN_MAGNITUDE)) return w.print("{e}", .{self.n});
        return w.print("{d}", .{self.n});
    }
};

pub const ObjRange = struct {
    obj: Obj,
    start: f64,
    end: f64,
    step: f64,
    is_exclusive: bool,
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

    pub fn isConcrete(self: *const ObjGeometry) bool {
        return self.cached_handle != null;
    }
};

pub const ObjCrossSection = struct {
    obj: Obj,
    dag_idx: u32,
};

/// A Path: open 2D geometry, its segments owned by the GC's tracking allocator, with the
/// name and material it carries for a drawing (as a Sketch's `named` and `material`).
pub const ObjPath = struct {
    obj: Obj,
    start: [2]f64,
    segments: []path_mod.Segment,
    name: ?*ObjString,
    /// The material's index in the VM's, or null.
    material_id: ?u32,

    pub fn end(self: *const ObjPath) [2]f64 {
        return path_mod.endOf(self.start, self.segments);
    }
};

pub const ObjAssembly = struct {
    obj: Obj,
    name: *ObjString,
    parts: *ObjArray,
};

/// A font file a script imported (`import label from "./Inter.ttf"`, class Font), for
/// `text(font:)`: its bytes as read, owned and counted against the VM's memory, which a
/// face is parsed from at each use (a face borrows them), and its name, the font's own.
pub const ObjFont = struct {
    obj: Obj,
    bytes: []u8,
    name: *ObjString,
};

/// Signature for all Native CAD Built-ins. Takes an opaque VM pointer to avoid circular
/// imports. Most natives are typed Zig functions turned into this by stdlib/classes/common.zig.
pub const NativeFn = *const fn (vm: *anyopaque, args: NativeArgs) anyerror!Value;

/// A native call's arguments, on the VM stack: `count` values at `ptr`, the receiver (or
/// callee) just below at `ptr[-1]`, and the call's block last when `has_block` (see
/// chunk.CallFlags) — a lambda passed as an ordinary argument is never taken for it.
pub const NativeArgs = struct {
    ptr: [*]Value,
    count: u8,
    has_block: bool = false,
    /// The native's script name, for error messages.
    name: []const u8,

    pub fn receiver(self: NativeArgs) Value {
        return (self.ptr - 1)[0];
    }

    /// The arguments without the block.
    pub fn positional(self: NativeArgs) []Value {
        return self.ptr[0 .. self.count - @intFromBool(self.has_block)];
    }

    pub fn block(self: NativeArgs) ?*ObjClosure {
        return if (self.has_block) self.ptr[self.count - 1].asClosure() else null;
    }
};

pub const ObjNative = struct {
    obj: Obj,
    function: NativeFn,
    /// The name scripts call it by (static: names come from the stdlib tables).
    name: []const u8,
};

pub const ObjBBox = struct {
    obj: Obj,
    min: [3]f64,
    max: [3]f64,
};

/// A completely unboxed, 8-byte value payload.
pub const Value = packed struct {
    val: u64,

    // --- Constructors ---

    pub inline fn initNumber(num: f64) Value {
        // Every NaN is the canonical one (see CANONICAL_NAN).
        if (std.math.isNan(num)) return .{ .val = CANONICAL_NAN };
        // Normalize -0.0 to +0.0 to protect Map invariants
        const normalized: f64 = if (num == 0.0) 0.0 else num;
        return .{ .val = @bitCast(normalized) };
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

    pub inline fn isMap(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .map;
    }

    pub inline fn isJsonObject(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .json_object;
    }

    pub inline fn isFunction(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .function;
    }

    pub inline fn isRange(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .range;
    }

    pub inline fn isGeometry(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .geometry;
    }
    pub inline fn isCrossSection(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .cross_section;
    }
    pub inline fn isPath(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .path;
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
    pub inline fn isSymbol(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .symbol;
    }
    pub inline fn isBBox(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .bbox;
    }
    pub inline fn isAssembly(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .assembly;
    }
    pub inline fn isFont(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .font;
    }
    pub inline fn isBoundMethod(self: Value) bool {
        return self.isObject() and self.asObj().obj_type == .bound_method;
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

    pub inline fn asGeometry(self: Value) *ObjGeometry {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asCrossSection(self: Value) *ObjCrossSection {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asPath(self: Value) *ObjPath {
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
        std.debug.assert(self.isArray());
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asMap(self: Value) *ObjMap {
        std.debug.assert(self.isMap());
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asJsonObject(self: Value) *ObjJsonObject {
        std.debug.assert(self.isJsonObject());
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asString(self: Value) *ObjString {
        std.debug.assert(self.isString());
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    pub inline fn asSymbol(self: Value) *ObjSymbol {
        std.debug.assert(self.isObject() and self.asObj().obj_type == .symbol);
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }
    /// The text of a String or a Symbol, which a script writes a name as either way
    /// (`halign: :center` or `"center"`); null for any other value.
    pub fn nameChars(self: Value) ?[]const u8 {
        if (self.isString()) return self.asString().chars;
        if (self.isSymbol()) return self.asSymbol().chars;
        return null;
    }
    pub inline fn asFunction(self: Value) *ObjFunction {
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    pub inline fn asRange(self: Value) *ObjRange {
        std.debug.assert(self.isRange());
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    pub inline fn asBBox(self: Value) *ObjBBox {
        std.debug.assert(self.isBBox());
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    pub inline fn asAssembly(self: Value) *ObjAssembly {
        std.debug.assert(self.isAssembly());
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    pub inline fn asFont(self: Value) *ObjFont {
        std.debug.assert(self.isFont());
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
    }

    pub inline fn asBoundMethod(self: Value) *ObjBoundMethod {
        std.debug.assert(self.isBoundMethod());
        return @alignCast(@fieldParentPtr("obj", self.asObj()));
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

    pub inline fn isFalsey(self: Value) bool {
        return self.isNil() or (self.isBool() and !self.asBool());
    }

    pub fn stringify(self: Value, is_inspect: bool, writer: *std.Io.Writer) !void {
        return self.stringifyNested(is_inspect, writer, null);
    }

    fn stringifyNested(self: Value, is_inspect: bool, writer: *std.Io.Writer, up: ?*const Printing) !void {
        if (self.isNumber()) {
            try writer.print("{f}", .{fmtNumber(self.asNumber())});
        } else if (self.isBool()) {
            try writer.writeAll(if (self.asBool()) "true" else "false");
        } else if (self.isNil()) {
            try writer.writeAll("nil");
        } else if (self.isObject()) {
            const obj = self.asObj();
            switch (obj.obj_type) {
                .string => {
                    const str_obj: *ObjString = @alignCast(@fieldParentPtr("obj", obj));
                    if (is_inspect) {
                        try writeQuoted(writer, str_obj.chars);
                    } else {
                        try writer.writeAll(str_obj.chars);
                    }
                },
                .symbol => {
                    // As in Ruby: `:name` when inspected, the bare name otherwise (puts,
                    // interpolation, join), which used to keep the colon too. A name `:name`
                    // wouldn't read back as is quoted, `:"a b"`; it was `:a b`.
                    const sym: *ObjSymbol = @alignCast(@fieldParentPtr("obj", obj));
                    if (!is_inspect) return writer.writeAll(sym.chars);
                    try writer.writeAll(":");
                    if (lexer.isBareSymbol(sym.chars)) try writer.writeAll(sym.chars) else try writeQuoted(writer, sym.chars);
                },
                .array => {
                    const arr: *ObjArray = @alignCast(@fieldParentPtr("obj", obj));
                    const here = Printing.enter(up, obj) orelse return writer.writeAll("[...]");
                    try writer.writeAll("[");
                    for (arr.items.items, 0..) |item, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try item.stringifyNested(true, writer, &here); // Force inspect mode for nested items
                    }
                    try writer.writeAll("]");
                },
                .map => {
                    const map = &obj.as(ObjMap).map;
                    try writeEntries(map.keys(), map.values(), writer, Printing.enter(up, obj) orelse return writer.writeAll("{...}"));
                },
                // As a Map of its entries: `{"teeth" => 12}`
                .json_object => {
                    const map = &obj.as(ObjJsonObject).map;
                    try writeEntries(map.keys(), map.values(), writer, Printing.enter(up, obj) orelse return writer.writeAll("{...}"));
                },
                .class => {
                    const cls: *ObjClass = @alignCast(@fieldParentPtr("obj", obj));
                    try writer.writeAll(cls.name.chars); // `puts 5.class` prints Number, as in Ruby
                },
                .instance => {
                    const inst: *ObjInstance = @alignCast(@fieldParentPtr("obj", obj));
                    try writer.print("#<{s}>", .{inst.class.name.chars});
                },
                .closure, .function => try writer.writeAll("<Function>"),
                .native => try writer.writeAll("<Native Function>"),
                .bound_method => try writer.writeAll("<Bound Method>"),
                .range => {
                    const r: *ObjRange = @alignCast(@fieldParentPtr("obj", obj));
                    const op_str = if (r.is_exclusive) "..." else "..";
                    try writer.print("{f}{s}{f}", .{ fmtNumber(r.start), op_str, fmtNumber(r.end) });
                },
                .geometry => try writer.print("<Geometry DAG:{d}>", .{@as(*ObjGeometry, @alignCast(@fieldParentPtr("obj", obj))).dag_idx}),
                .cross_section => {
                    const cs: *ObjCrossSection = @alignCast(@fieldParentPtr("obj", obj));
                    try writer.print("<CrossSection DAG:{d}>", .{cs.dag_idx});
                },
                .path => {
                    const p: *ObjPath = @alignCast(@fieldParentPtr("obj", obj));
                    const end = p.end();
                    try writer.print("<Path {d} segment{s} from [{f}, {f}] to [{f}, {f}]>", .{ p.segments.len, if (p.segments.len == 1) "" else "s", fmtNumber(p.start[0]), fmtNumber(p.start[1]), fmtNumber(end[0]), fmtNumber(end[1]) });
                },
                .workplane => try writer.writeAll("<Workplane>"),
                // puts and interpolation give its name, inspect says what it is too
                .font => {
                    const name = obj.as(ObjFont).name.chars;
                    if (is_inspect) try writer.print("#<Font {s}>", .{name}) else try writer.writeAll(name);
                },
                .bbox => {
                    const bx: *ObjBBox = @alignCast(@fieldParentPtr("obj", obj));
                    const f = fmtNumber;
                    try writer.print("BoundingBox(min: [{f}, {f}, {f}], max: [{f}, {f}, {f}])", .{ f(bx.min[0]), f(bx.min[1]), f(bx.min[2]), f(bx.max[0]), f(bx.max[1]), f(bx.max[2]) });
                },
                else => try writer.writeAll("<Object>"),
            }
        }
    }
};

/// A Map's entries in braces, as written in a script: `{x: 1}` for a Symbol key,
/// `{"x" => 1}` otherwise. `here` is the Map being printed.
fn writeEntries(keys: []const Value, values: []const Value, writer: *std.Io.Writer, here: Printing) std.Io.Writer.Error!void {
    try writer.writeAll("{");
    for (keys, values, 0..) |key, v, i| {
        if (i > 0) try writer.writeAll(", ");
        // `k: 1` as a script writes it; a Symbol that isn't a name keeps `=>` (`:"a b" => 1`)
        if (key.isSymbol() and lexer.isLabelName(key.asSymbol().chars)) {
            try writer.print("{s}: ", .{key.asSymbol().chars});
        } else {
            try key.stringifyNested(true, writer, &here);
            try writer.writeAll(" => ");
        }
        try v.stringifyNested(true, writer, &here);
    }
    try writer.writeAll("}");
}

/// The containers being printed, outermost first, so one that holds itself (directly or
/// through others) prints as `[...]` / `{...}`, as in Ruby: it recursed off the native
/// stack. Nesting past MAX_STRINGIFY_DEPTH prints the same, for the same reason.
const Printing = struct {
    obj: *const Obj,
    up: ?*const Printing,
    depth: u32,

    /// Null when `obj` is already being printed, or the nesting is too deep.
    fn enter(up: ?*const Printing, obj: *const Obj) ?Printing {
        const depth = if (up) |u| u.depth + 1 else 1;
        if (depth > MAX_STRINGIFY_DEPTH) return null;
        var cur = up;
        while (cur) |p| : (cur = p.up) {
            if (p.obj == obj) return null;
        }
        return .{ .obj = obj, .up = up, .depth = depth };
    }
};

/// `s` as a script writes it: quoted, with the lexer's escapes for `"`, `\`, `#{` and
/// control characters (`inspect` wrote the bytes raw, so `"say \"hi\""` came out as
/// `"say "hi""`). A control character the lexer has no escape for is shown as `\xHH`.
pub fn writeQuoted(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s, 0..) |c, i| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\t' => try writer.writeAll("\\t"),
            '\r' => try writer.writeAll("\\r"),
            0x0c => try writer.writeAll("\\f"),
            0x0b => try writer.writeAll("\\v"),
            0x08 => try writer.writeAll("\\b"),
            0x07 => try writer.writeAll("\\a"),
            0x1b => try writer.writeAll("\\e"),
            0 => try writer.writeAll("\\0"),
            '#' => try writer.writeAll(if (i + 1 < s.len and s[i + 1] == '{') "\\#" else "#"),
            else => if (c < 0x20 or c == 0x7f) try writer.print("\\x{X:0>2}", .{c}) else try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

/// A dynamic array of Values (used for the VM Stack and constants arrays).
pub const ValueArray = std.ArrayList(Value);
