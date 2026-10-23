//! `GC`: the VM's mark-and-sweep collector and object allocator. It keeps each object type
//! in its own list, counts the bytes it hands out to trigger collections and enforce the
//! sandbox's memory limit, and holds the natives and names that live as long as the VM in
//! an arena.

const std = @import("std");
const path_mod = @import("../core/path.zig");
const builtin = @import("builtin");
const value = @import("../core/value.zig");
const chunk = @import("chunk.zig");
const VM = @import("vm.zig").VM;
const kernel = @import("../kernel/kernel.zig");
const geom = @import("../core/geometry_handle.zig");
const CONCRETE_NODE_SENTINEL = @import("dag.zig").CONCRETE_NODE_SENTINEL;
const build_info = @import("build_info");

/// How far past the memory limit an OutOfMemoryError may allocate while it is raised (its
/// instance, message and backtrace), so a script that filled the limit is still told why, and
/// can rescue it. Raising it used to fail too, and the run ended with "out of memory while
/// raising an error". Only the raise gets it: the heap never passes the limit by more.
pub const OUT_OF_MEMORY_RESERVE: usize = 64 * 1024;

pub const GC = struct {
    allocator: std.mem.Allocator,

    // Explicit Grey Stack to prevent C-Stack Overflow
    gray_stack: std.ArrayList(*value.Obj) = .empty,

    /// Objects that live as long as the VM: every native (they come from the standard
    /// library's tables) and the static names the library registers things under
    /// (internStatic). They are allocated from this arena, freed with the GC, and never
    /// swept: they are created marked and kept out of the lists the sweep walks, so the mark
    /// phase passes over them (they reference no other object). One allocation each, and
    /// its free at teardown, made a VM cost about 850 allocations before it ran anything.
    builtins: std.heap.ArenaAllocator,

    // --- Segregated Object Tracking Arrays (Data-Oriented Design) ---
    strings: std.ArrayList(*value.ObjString) = .empty,
    symbols: std.ArrayList(*value.ObjSymbol) = .empty,
    arrays: std.ArrayList(*value.ObjArray) = .empty,
    maps: std.ArrayList(*value.ObjMap) = .empty,
    json_objects: std.ArrayList(*value.ObjJsonObject) = .empty,
    functions: std.ArrayList(*value.ObjFunction) = .empty,
    classes: std.ArrayList(*value.ObjClass) = .empty,
    modules: std.ArrayList(*value.ObjModule) = .empty,
    instances: std.ArrayList(*value.ObjInstance) = .empty,
    closures: std.ArrayList(*value.ObjClosure) = .empty,
    upvalues: std.ArrayList(*value.ObjUpvalue) = .empty,
    bound_methods: std.ArrayList(*value.ObjBoundMethod) = .empty,
    ranges: std.ArrayList(*value.ObjRange) = .empty,
    bboxes: std.ArrayList(*value.ObjBBox) = .empty,

    geometries: std.ArrayList(*value.ObjGeometry) = .empty,
    cross_sections: std.ArrayList(*value.ObjCrossSection) = .empty,
    paths: std.ArrayList(*value.ObjPath) = .empty,
    assemblies: std.ArrayList(*value.ObjAssembly) = .empty,
    workplanes: std.ArrayList(*value.ObjWorkplane) = .empty,
    fonts: std.ArrayList(*value.ObjFont) = .empty,
    randoms: std.ArrayList(*value.ObjRandom) = .empty,

    // GC triggering metrics
    bytes_allocated: usize,
    next_gc_threshold: usize,

    // Hard Sandbox Memory Limit
    max_memory_limit: ?usize,
    /// An OutOfMemoryError is being raised: it may use OUT_OF_MEMORY_RESERVE past the limit.
    raising_out_of_memory: bool = false,

    // --- GC State ---
    is_gc_running: bool = false,

    /// Collect on every object allocation, so unrooted temporaries are swept at once
    /// instead of only past the byte threshold: set by a test, or for every VM by a
    /// `-Dgc-stress` build.
    stress: bool = build_info.gc_stress,

    /// Chunks whose constant pools are roots (see chunk.ChunkRegistry).
    live_chunks: chunk.ChunkRegistry = .{},

    const HEAP_GROW_FACTOR: usize = 2;

    pub fn init(allocator: std.mem.Allocator) GC {
        return .{
            .allocator = allocator,
            .builtins = std.heap.ArenaAllocator.init(allocator),
            .bytes_allocated = 0,
            .is_gc_running = false,
            .next_gc_threshold = 1024 * 1024, // 1MB starting threshold
            .max_memory_limit = null,
        };
    }

    pub fn deinit(self: *GC) void {
        self.gray_stack.deinit(self.allocator);
        self.live_chunks.deinit(self.allocator);

        // Clean up tracking arrays
        self.strings.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.arrays.deinit(self.allocator);
        self.maps.deinit(self.allocator);
        self.json_objects.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.classes.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.instances.deinit(self.allocator);
        self.closures.deinit(self.allocator);
        self.upvalues.deinit(self.allocator);
        self.bound_methods.deinit(self.allocator);
        self.ranges.deinit(self.allocator);
        self.bboxes.deinit(self.allocator);
        self.geometries.deinit(self.allocator);
        self.cross_sections.deinit(self.allocator);
        self.paths.deinit(self.allocator);
        self.assemblies.deinit(self.allocator);
        self.workplanes.deinit(self.allocator);
        self.fonts.deinit(self.allocator);
        self.randoms.deinit(self.allocator);
        self.builtins.deinit();
    }

    /// Registers a chunk's constant pool as a GC root until the chunk is freed.
    pub fn trackChunk(self: *GC, c: *chunk.Chunk) !void {
        try self.live_chunks.track(self.allocator, c);
    }

    // --- Dynamic Tracking Allocator Interface ---

    pub fn trackingAllocator(self: *GC) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = trackAlloc,
                .resize = trackResize,
                .remap = trackRemap,
                .free = trackFree,
            },
        };
    }

    fn trackAlloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *GC = @ptrCast(@alignCast(ctx));
        if (self.memoryCap()) |cap| {
            if (self.bytes_allocated + len > cap) return null;
        }
        const res = self.allocator.rawAlloc(len, ptr_align, ret_addr) orelse return null;
        self.bytes_allocated += len;
        return res;
    }

    fn trackResize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *GC = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) {
            const diff = new_len - buf.len;
            if (self.memoryCap()) |cap| {
                if (self.bytes_allocated + diff > cap) return false;
            }
            if (self.allocator.rawResize(buf, buf_align, new_len, ret_addr)) {
                self.bytes_allocated += diff;
                return true;
            }
            return false;
        } else {
            if (self.allocator.rawResize(buf, buf_align, new_len, ret_addr)) {
                self.bytes_allocated -= (buf.len - new_len);
                return true;
            }
            return false;
        }
    }

    fn trackRemap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *GC = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) {
            const diff = new_len - buf.len;
            if (self.memoryCap()) |cap| {
                if (self.bytes_allocated + diff > cap) return null;
            }
            if (self.allocator.rawRemap(buf, buf_align, new_len, ret_addr)) |new_ptr| {
                self.bytes_allocated += diff;
                return new_ptr;
            }
            return null;
        } else {
            if (self.allocator.rawRemap(buf, buf_align, new_len, ret_addr)) |new_ptr| {
                self.bytes_allocated -= (buf.len - new_len);
                return new_ptr;
            }
            return null;
        }
    }

    fn trackFree(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *GC = @ptrCast(@alignCast(ctx));
        self.allocator.rawFree(buf, buf_align, ret_addr);
        self.bytes_allocated -= buf.len;
    }

    pub fn collectGarbage(self: *GC, vm: *VM, force_full: bool) void {
        // Prevent catastrophic nested GC sweeps
        std.debug.assert(!self.is_gc_running);
        self.is_gc_running = true;
        defer self.is_gc_running = false;

        if (!force_full) {
            // Pre-allocate gray stack to absolute worst-case capacity to avoid mid-trace OOM
            const worst_case_size = self.strings.items.len + self.symbols.items.len +
                self.arrays.items.len + self.maps.items.len + self.json_objects.items.len + self.functions.items.len +
                self.classes.items.len + self.modules.items.len + self.instances.items.len +
                self.closures.items.len + self.upvalues.items.len + self.bound_methods.items.len +
                self.ranges.items.len +
                self.bboxes.items.len + self.geometries.items.len + self.cross_sections.items.len +
                self.assemblies.items.len + self.workplanes.items.len + self.fonts.items.len +
                self.randoms.items.len;

            self.gray_stack.ensureTotalCapacity(self.allocator, worst_case_size) catch {
                vm.reportError("Fatal: Out of memory during garbage collection. Aborting script execution.", .{});
                // Halt the script now, so a long-lived host (the LSP, `kupcad watch`) stays alive
                vm.cancel_token.store(true, .release);
                return;
            };

            self.markRoots(vm);
            self.traceReferences();

            // Ensure the tracing phase perfectly exhausted the mark queue
            std.debug.assert(self.gray_stack.items.len == 0);
        }

        self.sweep(vm);
        self.next_gc_threshold = self.bytes_allocated * HEAP_GROW_FACTOR;
    }

    /// The most the heap may hold now: the memory limit, and the reserve on top while an
    /// OutOfMemoryError is raised; null without a limit.
    fn memoryCap(self: *const GC) ?usize {
        const limit = self.max_memory_limit orelse return null;
        return if (self.raising_out_of_memory) limit +| OUT_OF_MEMORY_RESERVE else limit;
    }

    /// The heap size past which the next allocation collects first: the growth threshold, or
    /// the memory cap when that is lower, so a script whose garbage reaches the limit has it
    /// collected instead of stopping while it holds almost nothing.
    fn collectionThreshold(self: *const GC) usize {
        return @min(self.next_gc_threshold, self.memoryCap() orelse std.math.maxInt(usize));
    }

    /// Generic allocator that appends directly to the specific tracking list
    inline fn allocateObject(self: *GC, vm: *VM, comptime T: type, list: *std.ArrayList(*T), obj_type: value.ObjType) !*T {
        if (self.stress or self.bytes_allocated + @sizeOf(T) > self.collectionThreshold()) {
            self.collectGarbage(vm, false);
        }

        // The run raises the OutOfMemoryError that names the limit (VM.allocationFailed).
        if (self.memoryCap()) |cap| {
            if (self.bytes_allocated + @sizeOf(T) > cap) return error.OutOfMemory;
        }

        const ptr = try self.allocator.create(T);
        // Not in its list yet: nothing would ever sweep it (it leaked, and stayed counted).
        errdefer self.allocator.destroy(ptr);
        try list.append(self.allocator, ptr);
        self.bytes_allocated += @sizeOf(T);

        ptr.obj = .{
            .obj_type = obj_type,
            .is_marked = false,
        };
        return ptr;
    }

    // --- Allocators ---

    pub fn allocateBBox(self: *GC, vm: *VM, min_x: f64, min_y: f64, min_z: f64, max_x: f64, max_y: f64, max_z: f64) !*value.ObjBBox {
        const ptr = try self.allocateObject(vm, value.ObjBBox, &self.bboxes, .bbox);
        ptr.min = .{ min_x, min_y, min_z };
        ptr.max = .{ max_x, max_y, max_z };
        return ptr;
    }

    pub fn allocateArray(self: *GC, vm: *VM) !*value.ObjArray {
        const ptr = try self.allocateObject(vm, value.ObjArray, &self.arrays, .array);
        ptr.items = .empty;
        return ptr;
    }

    /// An Array of `items`. The caller roots what they hold.
    pub fn allocateArrayOf(self: *GC, vm: *VM, items: []const value.Value) !*value.ObjArray {
        const ptr = try self.allocateArray(vm);
        // No collection runs from here on: only allocateObject collects
        try ptr.items.appendSlice(self.trackingAllocator(), items);
        return ptr;
    }

    pub fn allocateMap(self: *GC, vm: *VM) !*value.ObjMap {
        const ptr = try self.allocateObject(vm, value.ObjMap, &self.maps, .map);
        ptr.map = .empty;
        return ptr;
    }

    /// An empty JsonObject at `path` in `source` (see ObjJsonObject); the caller roots both.
    pub fn allocateJsonObject(self: *GC, vm: *VM, source: *value.ObjString, path: *value.ObjString) !*value.ObjJsonObject {
        const ptr = try self.allocateObject(vm, value.ObjJsonObject, &self.json_objects, .json_object);
        ptr.map = .empty;
        ptr.source = source;
        ptr.path = path;
        return ptr;
    }

    pub fn allocateFunction(self: *GC, vm: *VM) !*value.ObjFunction {
        const ptr = try self.allocateObject(vm, value.ObjFunction, &self.functions, .function);
        ptr.name = null;
        ptr.arity = 0;
        ptr.upvalue_count = 0;
        ptr.local_count = 0;
        ptr.splat_pos = null;
        ptr.chunk = null;
        ptr.owns_chunk = true;
        ptr.is_lambda = false;
        ptr.is_method = false;
        ptr.min_args = 0;
        ptr.has_kwargs = false;
        ptr.namespace = null;
        return ptr;
    }

    pub fn allocateClass(self: *GC, vm: *VM, name: *value.ObjString, superclass: ?*value.ObjClass) !*value.ObjClass {
        const ptr = try self.allocateObject(vm, value.ObjClass, &self.classes, .class);
        ptr.name = name;
        ptr.superclass = superclass;
        ptr.methods = .empty;
        ptr.class_methods = .empty;
        ptr.class_fields = .empty;
        ptr.included_modules = .empty;
        ptr.instance_layout = .empty;
        ptr.is_value_class = false;
        return ptr;
    }

    pub fn allocateModule(self: *GC, vm: *VM, name: *value.ObjString) !*value.ObjModule {
        const ptr = try self.allocateObject(vm, value.ObjModule, &self.modules, .module);
        ptr.name = name;
        ptr.methods = .empty;
        ptr.exports_of = null;
        return ptr;
    }

    pub fn allocateInstance(self: *GC, vm: *VM, class: *value.ObjClass) !*value.ObjInstance {
        const ptr = try self.allocateObject(vm, value.ObjInstance, &self.instances, .instance);
        ptr.class = class;
        ptr.fields = .empty;
        return ptr;
    }

    pub fn allocateBoundMethod(self: *GC, vm: *VM, receiver: value.Value, method: value.Value) !*value.ObjBoundMethod {
        const ptr = try self.allocateObject(vm, value.ObjBoundMethod, &self.bound_methods, .bound_method);
        ptr.receiver = receiver;
        ptr.method = method;
        return ptr;
    }

    /// A native, alive as long as the VM (see `builtins`); `name` must live as long.
    pub fn allocateNative(self: *GC, name: []const u8, function: value.NativeFn) !*value.ObjNative {
        const ptr = try self.builtins.allocator().create(value.ObjNative);
        ptr.* = .{ .obj = .{ .obj_type = .native, .is_marked = true }, .function = function, .name = name };
        return ptr;
    }

    pub fn allocateRange(self: *GC, vm: *VM, start: f64, end: f64, step: f64, is_exclusive: bool) !*value.ObjRange {
        const ptr = try self.allocateObject(vm, value.ObjRange, &self.ranges, .range);
        ptr.start = start;
        ptr.end = end;
        ptr.step = step;
        ptr.is_exclusive = is_exclusive;
        return ptr;
    }

    pub fn allocateClosure(self: *GC, vm: *VM, function: *value.ObjFunction) !*value.ObjClosure {
        const upvalues = try self.trackingAllocator().alloc(?*value.ObjUpvalue, function.upvalue_count);
        @memset(upvalues, null);

        const ptr = self.allocateObject(vm, value.ObjClosure, &self.closures, .closure) catch |err| {
            self.trackingAllocator().free(upvalues);
            return err;
        };

        ptr.function = function;
        ptr.upvalues = upvalues.ptr;
        ptr.home_class = null;
        ptr.home = null;
        ptr.home_self = value.Value.initNil();
        ptr.home_block = value.Value.initNil();
        return ptr;
    }

    pub fn allocateString(self: *GC, vm: *VM, chars: []const u8) !*value.ObjString {
        if (vm.strings.get(chars)) |existing| return existing;

        const owned_chars = try self.trackingAllocator().dupe(u8, chars);

        const ptr = self.allocateObject(vm, value.ObjString, &self.strings, .string) catch |err| {
            self.trackingAllocator().free(owned_chars);
            return err;
        };
        ptr.chars = owned_chars;

        try vm.strings.put(self.allocator, ptr.chars, ptr);
        return ptr;
    }

    pub fn allocateSymbol(self: *GC, vm: *VM, chars: []const u8) !*value.ObjSymbol {
        if (vm.symbols.get(chars)) |existing| return existing;

        const owned_chars = try self.trackingAllocator().dupe(u8, chars);

        const ptr = self.allocateObject(vm, value.ObjSymbol, &self.symbols, .symbol) catch |err| {
            self.trackingAllocator().free(owned_chars);
            return err;
        };
        ptr.chars = owned_chars;

        try vm.symbols.put(self.allocator, ptr.chars, ptr);
        return ptr;
    }

    /// `chars`, a name that outlives the VM (a literal of the standard library), as an
    /// interned string alive as long as the VM (see `builtins`): no copy, never swept. The
    /// string already interned under that text, if there is one.
    pub fn internStatic(self: *GC, vm: *VM, chars: []const u8) !*value.ObjString {
        if (vm.strings.get(chars)) |existing| return existing;
        const ptr = try self.builtins.allocator().create(value.ObjString);
        ptr.* = .{ .obj = .{ .obj_type = .string, .is_marked = true }, .chars = chars };
        try vm.strings.put(self.allocator, chars, ptr);
        return ptr;
    }

    /// The string of `chars` (allocated with the tracking allocator), interned. It takes
    /// `chars` whatever happens: a duplicate's and a failure's are freed here, so a caller
    /// must not free them (four natives did, on failure, a second time).
    pub fn takeString(self: *GC, vm: *VM, chars: []u8) !*value.ObjString {
        if (vm.strings.get(chars)) |existing| {
            self.trackingAllocator().free(chars); // Safely free the duplicate via tracker
            return existing;
        }

        const ptr = self.allocateObject(vm, value.ObjString, &self.strings, .string) catch |err| {
            self.trackingAllocator().free(chars);
            return err;
        };
        ptr.chars = chars;

        try vm.strings.put(self.allocator, ptr.chars, ptr);
        return ptr;
    }

    pub fn allocateGeometry(self: *GC, vm: *VM, state: value.GeometryState) !*value.ObjGeometry {
        const ptr = try self.allocateObject(vm, value.ObjGeometry, &self.geometries, .geometry);
        ptr.dag_idx = switch (state) {
            .symbolic => |idx| idx,
            .concrete => CONCRETE_NODE_SENTINEL, // no DAG node
        };
        ptr.cached_handle = switch (state) {
            .symbolic => null,
            .concrete => |h| h,
        };
        ptr.cached_bbox = null;
        return ptr;
    }

    pub fn allocateCrossSection(self: *GC, vm: *VM, dag_idx: u32) !*value.ObjCrossSection {
        const ptr = try self.allocateObject(vm, value.ObjCrossSection, &self.cross_sections, .cross_section);
        ptr.dag_idx = dag_idx;
        return ptr;
    }

    /// A Path of `segments` from `start`, which it takes (allocated by trackingAllocator);
    /// the caller roots `name`.
    pub fn allocatePath(self: *GC, vm: *VM, start: [2]f64, segments: []path_mod.Segment, name: ?*value.ObjString, material_id: ?u32) !*value.ObjPath {
        const ptr = try self.allocateObject(vm, value.ObjPath, &self.paths, .path);
        ptr.start = start;
        ptr.segments = segments;
        ptr.name = name;
        ptr.material_id = material_id;
        return ptr;
    }

    pub fn allocateAssembly(self: *GC, vm: *VM, name: *value.ObjString, parts: *value.ObjArray) !*value.ObjAssembly {
        const ptr = try self.allocateObject(vm, value.ObjAssembly, &self.assemblies, .assembly);
        ptr.name = name;
        ptr.parts = parts;
        return ptr;
    }

    /// A Font of the font file `bytes`, which it takes (allocated by trackingAllocator, so
    /// they count against the memory limit and are freed with it), named `name`; the caller
    /// roots `name`.
    pub fn allocateFont(self: *GC, vm: *VM, bytes: []u8, name: *value.ObjString) !*value.ObjFont {
        const ptr = try self.allocateObject(vm, value.ObjFont, &self.fonts, .font);
        ptr.bytes = bytes;
        ptr.name = name;
        return ptr;
    }

    /// A Random seeded with `seed` (a whole number), its state `state`.
    pub fn allocateRandom(self: *GC, vm: *VM, seed: f64, state: u64) !*value.ObjRandom {
        const ptr = try self.allocateObject(vm, value.ObjRandom, &self.randoms, .random);
        ptr.seed = seed;
        ptr.state = state;
        return ptr;
    }

    pub fn allocateWorkplane(self: *GC, vm: *VM, parent: *value.ObjGeometry, origin: [3]f64, normal: [3]f64) !*value.ObjWorkplane {
        const ptr = try self.allocateObject(vm, value.ObjWorkplane, &self.workplanes, .workplane);
        ptr.parent = parent;
        ptr.origin = origin;
        ptr.normal = normal;
        return ptr;
    }

    pub fn allocateUpvalue(self: *GC, vm: *VM, local_ptr: *value.Value, next_upval: ?*value.ObjUpvalue) !*value.ObjUpvalue {
        const ptr = try self.allocateObject(vm, value.ObjUpvalue, &self.upvalues, .upvalue);
        ptr.location = local_ptr;
        ptr.closed = value.Value.initNil();
        ptr.next = next_upval;
        return ptr;
    }

    // --- Phase 1: Mark ---

    fn markRoots(self: *GC, vm: *VM) void {
        for (vm.stack[0..vm.stack_top]) |val| {
            self.markValue(val);
        }

        // Protect error values held across native boundary unwinds
        for (vm.unwind_stack.items) |u_frame| {
            self.markValue(u_frame.err_val);
        }
        if (vm.pending_break) |pending| self.markValue(pending.value);

        // Constants of chunks still being compiled (or not yet wrapped in a function)
        for (self.live_chunks.chunks.items) |c| {
            for (c.constants.items) |val| self.markValue(val);
        }

        // Import cache: a module's result is only referenced from here once its
        // top-level closure has returned, and later imports push it straight from the cache.
        var modules_it = vm.modules.valueIterator();
        while (modules_it.next()) |val| {
            self.markValue(val.*);
        }

        // --- Protect static interned strings ---
        if (vm.static_true) |s| self.markObject(&s.obj);
        if (vm.static_false) |s| self.markObject(&s.obj);
        if (vm.static_nil) |s| self.markObject(&s.obj);

        for (vm.frames.items) |frame| {
            self.markObject(&frame.closure.obj);
        }

        var upval = vm.open_upvalues;
        while (upval) |u| {
            self.markObject(&u.obj);
            upval = u.next;
        }

        var globals_it = vm.globals.valueIterator();
        while (globals_it.next()) |val| {
            self.markValue(val.*);
        }
        var shadowed_it = vm.shadowed_builtins.valueIterator();
        while (shadowed_it.next()) |val| self.markValue(val.*);
        for (vm.module_namespaces.items) |ns| {
            var ns_it = ns.globals.valueIterator();
            while (ns_it.next()) |val| self.markValue(val.*);
        }

        for (vm.param_registry.items(.name)) |name| self.markValue(name);
        for (vm.param_registry.items(.current_value)) |val| self.markValue(val);
        for (vm.param_registry.items(.choices)) |choice| {
            if (choice) |arr| self.markObject(&arr.obj);
        }

        if (vm.string_class) |c| self.markObject(&c.obj);
        if (vm.array_class) |c| self.markObject(&c.obj);
        if (vm.map_class) |c| self.markObject(&c.obj);
        if (vm.number_class) |c| self.markObject(&c.obj);
        if (vm.symbol_class) |c| self.markObject(&c.obj);
        if (vm.boolean_class) |c| self.markObject(&c.obj);
        if (vm.bbox_class) |c| self.markObject(&c.obj);
    }

    fn markValue(self: *GC, val: value.Value) void {
        if (val.isObject()) {
            self.markObject(val.asObj());
        }
    }

    fn markObject(self: *GC, obj: *value.Obj) void {
        if (obj.is_marked) return;
        obj.is_marked = true;
        self.gray_stack.appendAssumeCapacity(obj);
    }

    fn traceReferences(self: *GC) void {
        while (self.gray_stack.items.len > 0) {
            const obj = self.gray_stack.pop().?;
            self.blackenObject(obj);
        }
    }

    fn blackenObject(self: *GC, obj: *value.Obj) void {
        switch (obj.obj_type) {
            .array => {
                const arr = obj.as(value.ObjArray);
                for (arr.items.items) |val| self.markValue(val);
            },
            .map => {
                const map = obj.as(value.ObjMap);
                for (map.map.keys()) |k| self.markValue(k);
                for (map.map.values()) |v| self.markValue(v);
            },
            .json_object => {
                const object = obj.as(value.ObjJsonObject);
                for (object.map.keys()) |k| self.markValue(k);
                for (object.map.values()) |v| self.markValue(v);
                self.markObject(&object.source.obj);
                self.markObject(&object.path.obj);
            },
            .closure => {
                const closure_obj = obj.as(value.ObjClosure);
                self.markObject(&closure_obj.function.obj);
                for (0..closure_obj.function.upvalue_count) |i| {
                    if (closure_obj.upvalues[i]) |u| self.markObject(&u.obj);
                }
                if (closure_obj.home_class) |c| self.markObject(&c.obj);
                if (closure_obj.home) |h| self.markObject(&h.obj);
                self.markValue(closure_obj.home_self);
                self.markValue(closure_obj.home_block);
            },
            .upvalue => {
                const upval = obj.as(value.ObjUpvalue);
                self.markValue(upval.closed);
            },
            .function => {
                const func = obj.as(value.ObjFunction);
                if (func.name) |name| self.markObject(&name.obj);
                if (func.chunk) |c_ptr| {
                    const exec_chunk: *chunk.Chunk = @ptrCast(@alignCast(c_ptr));
                    for (exec_chunk.constants.items) |val| self.markValue(val);
                    // The caches hold classes and methods; an unmarked one could be swept
                    // and its address reused while a site still trusts the cache.
                    for (exec_chunk.inline_caches.items) |ic| {
                        if (ic.cached_class_1) |c| self.markObject(&c.obj);
                        if (ic.cached_class_2) |c| self.markObject(&c.obj);
                        self.markValue(ic.cached_val_1);
                        self.markValue(ic.cached_val_2);
                    }
                }
            },
            .module => {
                const module_obj = obj.as(value.ObjModule);
                self.markObject(&module_obj.name.obj);
                if (module_obj.exports_of) |file| self.markObject(&file.obj);
                for (module_obj.methods.keys()) |k| self.markValue(k);
                for (module_obj.methods.values()) |v| self.markValue(v);
            },
            .class => {
                const class_obj = obj.as(value.ObjClass);
                self.markObject(&class_obj.name.obj);
                if (class_obj.superclass) |sup| self.markObject(&sup.obj);
                for (class_obj.included_modules.items) |mod| self.markObject(&mod.obj);

                // Trace all map keys and values to prevent Use-After-Free
                for (class_obj.methods.keys()) |k| self.markValue(k);
                for (class_obj.methods.values()) |v| self.markValue(v);

                for (class_obj.class_methods.keys()) |k| self.markValue(k);
                for (class_obj.class_methods.values()) |v| self.markValue(v);

                for (class_obj.class_fields.keys()) |k| self.markValue(k);
                for (class_obj.class_fields.values()) |v| self.markValue(v);

                for (class_obj.instance_layout.keys()) |k| self.markValue(k);
            },
            .instance => {
                const instance_obj = obj.as(value.ObjInstance);
                self.markObject(&instance_obj.class.obj);
                for (instance_obj.fields.items) |val| self.markValue(val);
            },
            .bound_method => {
                const bound_obj = obj.as(value.ObjBoundMethod);
                self.markValue(bound_obj.receiver);
                self.markValue(bound_obj.method);
            },
            .assembly => {
                const assembly = obj.as(value.ObjAssembly);
                self.markObject(&assembly.name.obj);
                self.markObject(&assembly.parts.obj);
            },
            .workplane => {
                const wp_obj = obj.as(value.ObjWorkplane);
                self.markObject(&wp_obj.parent.obj);
            },
            .font => self.markObject(&obj.as(value.ObjFont).name.obj),
            .path => if (obj.as(value.ObjPath).name) |name| self.markObject(&name.obj),
            else => {},
        }
    }

    // --- DOD Segmented Sweep ---

    fn sweepList(self: *GC, vm: *VM, comptime T: type, list: *std.ArrayList(*T)) void {
        var i: usize = 0;
        while (i < list.items.len) {
            const ptr = list.items[i];

            // Assert the pointer is valid before checking its mark status
            std.debug.assert(@intFromPtr(ptr) > 0);

            if (ptr.obj.is_marked) {
                ptr.obj.is_marked = false; // Reset for next GC cycle
                i += 1;
            } else {
                // Instantly remove unmarked objects using O(1) swapRemove
                _ = list.swapRemove(i);
                self.freeObject(vm, &ptr.obj);
            }
        }
    }

    fn sweep(self: *GC, vm: *VM) void {
        // --- SAFE ZERO-ALLOCATION MAP EVICTION ---
        // By iterating the backing arrays directly, we can safely remove from
        // the VM hashmaps without invalidating iterators or allocating temporary tracking lists.
        for (self.strings.items) |str| {
            if (!str.obj.is_marked) _ = vm.strings.remove(str.chars);
        }
        for (self.symbols.items) |sym| {
            if (!sym.obj.is_marked) _ = vm.symbols.remove(sym.chars);
        }

        // Sweep dependent objects before their referenced functions/primitives
        self.sweepList(vm, value.ObjBoundMethod, &self.bound_methods);
        self.sweepList(vm, value.ObjInstance, &self.instances);
        self.sweepList(vm, value.ObjClosure, &self.closures);
        self.sweepList(vm, value.ObjClass, &self.classes);
        self.sweepList(vm, value.ObjModule, &self.modules);
        self.sweepList(vm, value.ObjFunction, &self.functions);
        self.sweepList(vm, value.ObjArray, &self.arrays);
        self.sweepList(vm, value.ObjMap, &self.maps);
        self.sweepList(vm, value.ObjJsonObject, &self.json_objects);
        self.sweepList(vm, value.ObjUpvalue, &self.upvalues);
        self.sweepList(vm, value.ObjRange, &self.ranges);
        self.sweepList(vm, value.ObjBBox, &self.bboxes);
        self.sweepList(vm, value.ObjString, &self.strings);
        self.sweepList(vm, value.ObjSymbol, &self.symbols);

        self.sweepList(vm, value.ObjGeometry, &self.geometries);
        self.sweepList(vm, value.ObjCrossSection, &self.cross_sections);
        self.sweepList(vm, value.ObjPath, &self.paths);
        self.sweepList(vm, value.ObjAssembly, &self.assemblies);
        self.sweepList(vm, value.ObjWorkplane, &self.workplanes);
        self.sweepList(vm, value.ObjFont, &self.fonts);
        self.sweepList(vm, value.ObjRandom, &self.randoms);

        // --- CACHE EVICTION ---
        // Results no live solid or sketch refers to. Without room to work it out, nothing
        // is evicted this cycle: the next collection tries again.
        var live: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer live.deinit(self.allocator);
        live.ensureTotalCapacity(self.allocator, @intCast(self.geometries.items.len + self.cross_sections.items.len)) catch return;
        const hashes = vm.dag_builder.node_hashes.items;
        for (self.geometries.items) |geom_ptr| {
            if (geom_ptr.dag_idx != CONCRETE_NODE_SENTINEL and geom_ptr.dag_idx < hashes.len) live.putAssumeCapacity(hashes[geom_ptr.dag_idx], {});
        }
        for (self.cross_sections.items) |cs_ptr| {
            if (cs_ptr.dag_idx < hashes.len) live.putAssumeCapacity(hashes[cs_ptr.dag_idx], {});
        }
        self.evictUnreferenced(geom.GeometryHandle, &vm.dag_cache, &live, kernel.destruct);
        self.evictUnreferenced(geom.CrossSectionHandle, &vm.cs_cache, &live, kernel.destructCrossSection);
    }

    /// Destroys the results in `cache` whose node isn't `live`, and drops them.
    fn evictUnreferenced(self: *GC, comptime Handle: type, cache: *std.AutoHashMapUnmanaged(u64, Handle), live: *const std.AutoHashMapUnmanaged(u64, void), comptime destroy: anytype) void {
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(self.allocator);
        stale.ensureTotalCapacity(self.allocator, cache.count()) catch return;
        var it = cache.iterator();
        while (it.next()) |entry| {
            if (live.contains(entry.key_ptr.*)) continue;
            destroy(entry.value_ptr.*);
            stale.appendAssumeCapacity(entry.key_ptr.*);
        }
        for (stale.items) |key| _ = cache.remove(key);
    }

    inline fn destroyObject(self: *GC, comptime T: type, ptr: *T) void {
        std.debug.assert(self.bytes_allocated >= @sizeOf(T));
        self.allocator.destroy(ptr);
        self.bytes_allocated -= @sizeOf(T);
    }

    fn freeObject(self: *GC, vm: *VM, obj: *value.Obj) void {
        switch (obj.obj_type) {
            .assembly => {
                const assembly_obj = obj.as(value.ObjAssembly);
                self.destroyObject(value.ObjAssembly, assembly_obj);
            },
            .geometry => {
                const geom_obj = obj.as(value.ObjGeometry);
                if (geom_obj.cached_handle) |handle| {
                    if (vm.host.mesh_destructor) |destructor| destructor(handle);
                }
                self.destroyObject(value.ObjGeometry, geom_obj);
            },
            .workplane => {
                const wp_obj = obj.as(value.ObjWorkplane);
                self.destroyObject(value.ObjWorkplane, wp_obj);
            },
            .font => {
                const font = obj.as(value.ObjFont);
                self.trackingAllocator().free(font.bytes);
                self.destroyObject(value.ObjFont, font);
            },
            .random => self.destroyObject(value.ObjRandom, obj.as(value.ObjRandom)),
            .cross_section => {
                self.destroyObject(value.ObjCrossSection, obj.as(value.ObjCrossSection));
            },
            .path => {
                const p = obj.as(value.ObjPath);
                self.trackingAllocator().free(p.segments);
                self.destroyObject(value.ObjPath, p);
            },
            .string => {
                const str_obj = obj.as(value.ObjString);
                // Debug Memory Poisoning: Instantly crash any lingering references to this string's bytes
                if (builtin.is_test or builtin.mode == .debug) {
                    @memset(@constCast(str_obj.chars), 0xAA);
                }
                self.trackingAllocator().free(str_obj.chars);
                self.destroyObject(value.ObjString, str_obj);
            },
            .symbol => {
                const sym_obj = obj.as(value.ObjSymbol);
                self.trackingAllocator().free(sym_obj.chars);
                self.destroyObject(value.ObjSymbol, sym_obj);
            },
            .native => {}, // in no sweep list: natives live in `builtins`
            .array => {
                const arr_obj = obj.as(value.ObjArray);
                arr_obj.items.deinit(self.trackingAllocator());
                self.destroyObject(value.ObjArray, arr_obj);
            },
            .map => {
                const map_obj = obj.as(value.ObjMap);
                map_obj.map.deinit(self.trackingAllocator());
                self.destroyObject(value.ObjMap, map_obj);
            },
            .json_object => {
                const object = obj.as(value.ObjJsonObject);
                object.map.deinit(self.trackingAllocator());
                self.destroyObject(value.ObjJsonObject, object);
            },
            .instance => {
                const instance_obj = obj.as(value.ObjInstance);
                instance_obj.fields.deinit(self.trackingAllocator());
                self.destroyObject(value.ObjInstance, instance_obj);
            },
            .closure => {
                const closure_obj = obj.as(value.ObjClosure);
                const upvalue_count = closure_obj.function.upvalue_count;
                self.trackingAllocator().free(closure_obj.upvalues[0..upvalue_count]);
                self.destroyObject(value.ObjClosure, closure_obj);
            },
            .function => {
                const func = obj.as(value.ObjFunction);
                if (func.owns_chunk) {
                    if (func.chunk) |c| {
                        const chnk: *chunk.Chunk = @ptrCast(@alignCast(c));
                        chnk.free(self.allocator);
                        self.allocator.destroy(chnk);
                    }
                }
                self.destroyObject(value.ObjFunction, func);
            },
            .upvalue => self.destroyObject(value.ObjUpvalue, obj.as(value.ObjUpvalue)),
            .module => {
                const module_obj = obj.as(value.ObjModule);
                module_obj.methods.deinit(self.trackingAllocator());
                self.destroyObject(value.ObjModule, module_obj);
            },
            .class => {
                const class_obj = obj.as(value.ObjClass);
                class_obj.methods.deinit(self.trackingAllocator());
                class_obj.included_modules.deinit(self.trackingAllocator());
                class_obj.class_methods.deinit(self.trackingAllocator());
                class_obj.class_fields.deinit(self.trackingAllocator());
                class_obj.instance_layout.deinit(self.trackingAllocator());
                self.destroyObject(value.ObjClass, class_obj);
            },
            .bound_method => self.destroyObject(value.ObjBoundMethod, obj.as(value.ObjBoundMethod)),
            .range => self.destroyObject(value.ObjRange, obj.as(value.ObjRange)),
            .bbox => self.destroyObject(value.ObjBBox, obj.as(value.ObjBBox)),
        }
    }
};
