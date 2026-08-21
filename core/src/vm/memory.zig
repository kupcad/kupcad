const std = @import("std");
const value = @import("../core/value.zig");
const chunk = @import("chunk.zig");
const VM = @import("vm.zig").VM;
const kernel = @import("../kernel/kernel.zig");
const GeometryHandle = @import("../kernel/geometry_handle.zig").GeometryHandle;

pub const GC = struct {
    allocator: std.mem.Allocator,

    // Explicit Grey Stack to prevent C-Stack Overflow
    gray_stack: std.ArrayListUnmanaged(*value.Obj) = .empty,

    // --- Segregated Object Tracking Arrays (Data-Oriented Design) ---
    strings: std.ArrayListUnmanaged(*value.ObjString) = .empty,
    symbols: std.ArrayListUnmanaged(*value.ObjSymbol) = .empty,
    arrays: std.ArrayListUnmanaged(*value.ObjArray) = .empty,
    maps: std.ArrayListUnmanaged(*value.ObjMap) = .empty,
    functions: std.ArrayListUnmanaged(*value.ObjFunction) = .empty,
    classes: std.ArrayListUnmanaged(*value.ObjClass) = .empty,
    modules: std.ArrayListUnmanaged(*value.ObjModule) = .empty,
    instances: std.ArrayListUnmanaged(*value.ObjInstance) = .empty,
    closures: std.ArrayListUnmanaged(*value.ObjClosure) = .empty,
    upvalues: std.ArrayListUnmanaged(*value.ObjUpvalue) = .empty,
    bound_methods: std.ArrayListUnmanaged(*value.ObjBoundMethod) = .empty,
    natives: std.ArrayListUnmanaged(*value.ObjNative) = .empty,
    ranges: std.ArrayListUnmanaged(*value.ObjRange) = .empty,
    breps: std.ArrayListUnmanaged(*value.ObjBrep) = .empty,

    geometries: std.ArrayListUnmanaged(*value.ObjGeometry) = .empty,
    cross_sections: std.ArrayListUnmanaged(*value.ObjCrossSection) = .empty,
    workplanes: std.ArrayListUnmanaged(*value.ObjWorkplane) = .empty,

    // GC triggering metrics
    bytes_allocated: usize,
    next_gc_threshold: usize,

    // Hard Sandbox Memory Limit
    max_memory_limit: ?usize,

    const HEAP_GROW_FACTOR: usize = 2;

    pub fn init(allocator: std.mem.Allocator) GC {
        return .{
            .allocator = allocator,
            .bytes_allocated = 0,
            .next_gc_threshold = 1024 * 1024, // 1MB starting threshold
            .max_memory_limit = null,
        };
    }

    pub fn deinit(self: *GC) void {
        self.gray_stack.deinit(self.allocator);

        // Clean up tracking arrays
        self.strings.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.arrays.deinit(self.allocator);
        self.maps.deinit(self.allocator);
        self.functions.deinit(self.allocator);
        self.classes.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.instances.deinit(self.allocator);
        self.closures.deinit(self.allocator);
        self.upvalues.deinit(self.allocator);
        self.bound_methods.deinit(self.allocator);
        self.natives.deinit(self.allocator);
        self.ranges.deinit(self.allocator);
        self.breps.deinit(self.allocator);
        self.geometries.deinit(self.allocator);
        self.cross_sections.deinit(self.allocator);
        self.workplanes.deinit(self.allocator);
    }

    pub fn collectGarbage(self: *GC, vm: *VM, force_full: bool) void {
        const before = self.bytes_allocated;

        if (!force_full) {
            self.markRoots(vm);
            self.traceReferences();
        }

        self.sweep(vm);
        self.next_gc_threshold = self.bytes_allocated * HEAP_GROW_FACTOR;
        _ = before;
    }

    /// Generic allocator that appends directly to the specific tracking list
    inline fn allocateObject(self: *GC, vm: *VM, comptime T: type, list: *std.ArrayListUnmanaged(*T), obj_type: value.ObjType) !*T {
        if (self.bytes_allocated + @sizeOf(T) > self.next_gc_threshold) {
            self.collectGarbage(vm, false);
        }

        if (self.max_memory_limit) |limit| {
            if (self.bytes_allocated + @sizeOf(T) > limit) {
                vm.reportError("Sandbox Error: Script exceeded maximum memory limit of {d} bytes.\n", .{limit});
                return error.OutOfMemory;
            }
        }

        const ptr = try self.allocator.create(T);
        self.bytes_allocated += @sizeOf(T);

        ptr.obj = .{
            .obj_type = obj_type,
            .is_marked = false,
        };

        try list.append(self.allocator, ptr);
        return ptr;
    }

    // --- Allocators ---

    pub fn allocateArray(self: *GC, vm: *VM) !*value.ObjArray {
        const ptr = try self.allocateObject(vm, value.ObjArray, &self.arrays, .array);
        ptr.items = .empty;
        return ptr;
    }

    pub fn allocateMap(self: *GC, vm: *VM) !*value.ObjMap {
        const ptr = try self.allocateObject(vm, value.ObjMap, &self.maps, .map);
        ptr.keys = .empty;
        ptr.values = .empty;
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
        return ptr;
    }

    pub fn allocateModule(self: *GC, vm: *VM, name: *value.ObjString) !*value.ObjModule {
        const ptr = try self.allocateObject(vm, value.ObjModule, &self.modules, .module);
        ptr.name = name;
        ptr.methods = .empty;
        return ptr;
    }

    pub fn allocateInstance(self: *GC, vm: *VM, class: *value.ObjClass) !*value.ObjInstance {
        const ptr = try self.allocateObject(vm, value.ObjInstance, &self.instances, .instance);
        ptr.class = class;
        ptr.fields = .empty;
        return ptr;
    }

    pub fn allocateBoundMethod(self: *GC, vm: *VM, receiver: value.Value, method: *value.ObjClosure) !*value.ObjBoundMethod {
        const ptr = try self.allocateObject(vm, value.ObjBoundMethod, &self.bound_methods, .bound_method);
        ptr.receiver = receiver;
        ptr.method = method;
        return ptr;
    }

    pub fn allocateNative(self: *GC, vm: *VM, function: value.NativeFn) !*value.ObjNative {
        const ptr = try self.allocateObject(vm, value.ObjNative, &self.natives, .native);
        ptr.function = function;
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
        const upvals_size = @sizeOf(?*value.ObjUpvalue) * function.upvalue_count;

        if (self.max_memory_limit) |limit| {
            if (self.bytes_allocated + upvals_size + @sizeOf(value.ObjClosure) > limit) {
                vm.reportError("Sandbox Error: Script exceeded maximum memory limit.\n", .{});
                return error.OutOfMemory;
            }
        }

        const upvalues = try self.allocator.alloc(?*value.ObjUpvalue, function.upvalue_count);
        @memset(upvalues, null);

        const ptr = self.allocateObject(vm, value.ObjClosure, &self.closures, .closure) catch |err| {
            self.allocator.free(upvalues);
            return err;
        };

        self.bytes_allocated += upvals_size;
        ptr.function = function;
        ptr.upvalues = upvalues.ptr;
        return ptr;
    }

    pub fn allocateString(self: *GC, vm: *VM, chars: []const u8) !*value.ObjString {
        if (vm.strings.get(chars)) |existing| return existing;

        if (self.max_memory_limit) |limit| {
            if (self.bytes_allocated + chars.len + @sizeOf(value.ObjString) > limit) {
                vm.reportError("Sandbox Error: Script exceeded maximum memory limit.\n", .{});
                return error.OutOfMemory;
            }
        }

        const owned_chars = try self.allocator.dupe(u8, chars);

        const ptr = self.allocateObject(vm, value.ObjString, &self.strings, .string) catch |err| {
            self.allocator.free(owned_chars);
            return err;
        };

        self.bytes_allocated += owned_chars.len;
        ptr.chars = owned_chars;

        vm.strings.put(self.allocator, ptr.chars, ptr) catch |err| {
            return err;
        };
        return ptr;
    }

    pub fn allocateSymbol(self: *GC, vm: *VM, chars: []const u8) !*value.ObjSymbol {
        if (vm.symbols.get(chars)) |existing| return existing;

        if (self.max_memory_limit) |limit| {
            if (self.bytes_allocated + chars.len + @sizeOf(value.ObjSymbol) > limit) {
                vm.reportError("Sandbox Error: Script exceeded maximum memory limit.\n", .{});
                return error.OutOfMemory;
            }
        }

        const owned_chars = try self.allocator.dupe(u8, chars);

        const ptr = self.allocateObject(vm, value.ObjSymbol, &self.symbols, .symbol) catch |err| {
            self.allocator.free(owned_chars);
            return err;
        };

        self.bytes_allocated += owned_chars.len;
        ptr.chars = owned_chars;

        vm.symbols.put(self.allocator, ptr.chars, ptr) catch |err| {
            return err;
        };
        return ptr;
    }

    pub fn takeString(self: *GC, vm: *VM, chars: []u8) !*value.ObjString {
        if (vm.strings.get(chars)) |existing| {
            self.allocator.free(chars); // Free the duplicate
            return existing;
        }

        if (self.max_memory_limit) |limit| {
            if (self.bytes_allocated + chars.len + @sizeOf(value.ObjString) > limit) {
                self.allocator.free(chars);
                return error.OutOfMemory;
            }
        }

        const ptr = self.allocateObject(vm, value.ObjString, &self.strings, .string) catch |err| {
            self.allocator.free(chars);
            return err;
        };

        self.bytes_allocated += chars.len;
        ptr.chars = chars;

        vm.strings.put(self.allocator, ptr.chars, ptr) catch |err| {
            self.allocator.free(chars);
            return err;
        };
        return ptr;
    }

    pub fn allocateGeometry(self: *GC, vm: *VM, state: value.GeometryState) !*value.ObjGeometry {
        const ptr = try self.allocateObject(vm, value.ObjGeometry, &self.geometries, .geometry);
        ptr.dag_idx = switch (state) {
            .symbolic => |idx| idx,
            .concrete => 0,
        };
        ptr.cached_handle = switch (state) {
            .symbolic => null,
            .concrete => |h| h,
        };
        ptr.cached_bbox = null;
        ptr.cached_topology = null;
        return ptr;
    }

    pub fn allocateCrossSection(self: *GC, vm: *VM, dag_idx: u32) !*value.ObjCrossSection {
        const ptr = try self.allocateObject(vm, value.ObjCrossSection, &self.cross_sections, .cross_section);
        ptr.dag_idx = dag_idx;
        ptr.cached_handle = null;
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
        self.gray_stack.append(self.allocator, obj) catch @panic("OOM during GC Grey Stack tracking.");
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
                const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", obj)));
                for (arr.items.items) |val| self.markValue(val);
            },
            .map => {
                const map = @as(*value.ObjMap, @alignCast(@fieldParentPtr("obj", obj)));
                for (map.keys.items) |k| self.markValue(k);
                for (map.values.items) |v| self.markValue(v);
            },
            .closure => {
                const closure = @as(*value.ObjClosure, @alignCast(@fieldParentPtr("obj", obj)));
                self.markObject(&closure.function.obj);
                for (0..closure.function.upvalue_count) |i| {
                    if (closure.upvalues[i]) |upvalue| self.markObject(&upvalue.obj);
                }
            },
            .upvalue => {
                const upval = @as(*value.ObjUpvalue, @alignCast(@fieldParentPtr("obj", obj)));
                self.markValue(upval.closed);
            },
            .function => {
                const func = @as(*value.ObjFunction, @alignCast(@fieldParentPtr("obj", obj)));
                if (func.name) |name| self.markObject(&name.obj);
                if (func.chunk) |c_ptr| {
                    const exec_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(c_ptr)));
                    for (exec_chunk.constants.items) |val| self.markValue(val);
                }
            },
            .module => {
                const module_obj = @as(*value.ObjModule, @alignCast(@fieldParentPtr("obj", obj)));
                self.markObject(&module_obj.name.obj);
                var it = module_obj.methods.valueIterator();
                while (it.next()) |val| self.markValue(val.*);
            },
            .class => {
                const class_obj = @as(*value.ObjClass, @alignCast(@fieldParentPtr("obj", obj)));
                self.markObject(&class_obj.name.obj);
                if (class_obj.superclass) |sup| self.markObject(&sup.obj);
                for (class_obj.included_modules.items) |mod| self.markObject(&mod.obj);

                var it = class_obj.methods.valueIterator();
                while (it.next()) |val| self.markValue(val.*);

                var c_it = class_obj.class_methods.valueIterator();
                while (c_it.next()) |val| self.markValue(val.*);

                var f_it = class_obj.class_fields.valueIterator();
                while (f_it.next()) |val| self.markValue(val.*);
            },
            .instance => {
                const instance_obj = @as(*value.ObjInstance, @alignCast(@fieldParentPtr("obj", obj)));
                self.markObject(&instance_obj.class.obj);
                for (instance_obj.fields.items) |val| self.markValue(val);
            },
            .bound_method => {
                const bound_obj = @as(*value.ObjBoundMethod, @alignCast(@fieldParentPtr("obj", obj)));
                self.markValue(bound_obj.receiver);
                self.markObject(&bound_obj.method.obj);
            },
            .workplane => {
                const wp_obj = @as(*value.ObjWorkplane, @alignCast(@fieldParentPtr("obj", obj)));
                self.markObject(&wp_obj.parent.obj);
            },
            else => {},
        }
    }

    // --- Phase 2: DOD Segmented Sweep ---

    fn sweepList(self: *GC, vm: *VM, comptime T: type, list: *std.ArrayListUnmanaged(*T)) void {
        var i: usize = 0;
        while (i < list.items.len) {
            const ptr = list.items[i];
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
        // Clean weak string/symbol intern references first
        var str_iter = vm.strings.iterator();
        while (str_iter.next()) |entry| {
            if (!entry.value_ptr.*.obj.is_marked) _ = vm.strings.remove(entry.key_ptr.*);
        }

        var sym_iter = vm.symbols.iterator();
        while (sym_iter.next()) |entry| {
            if (!entry.value_ptr.*.obj.is_marked) _ = vm.symbols.remove(entry.key_ptr.*);
        }

        // Blazingly fast contiguous memory iterations!
        self.sweepList(vm, value.ObjString, &self.strings);
        self.sweepList(vm, value.ObjSymbol, &self.symbols);
        self.sweepList(vm, value.ObjArray, &self.arrays);
        self.sweepList(vm, value.ObjMap, &self.maps);
        self.sweepList(vm, value.ObjFunction, &self.functions);
        self.sweepList(vm, value.ObjClass, &self.classes);
        self.sweepList(vm, value.ObjModule, &self.modules);
        self.sweepList(vm, value.ObjInstance, &self.instances);
        self.sweepList(vm, value.ObjClosure, &self.closures);
        self.sweepList(vm, value.ObjUpvalue, &self.upvalues);
        self.sweepList(vm, value.ObjBoundMethod, &self.bound_methods);
        self.sweepList(vm, value.ObjNative, &self.natives);
        self.sweepList(vm, value.ObjRange, &self.ranges);
        self.sweepList(vm, value.ObjBrep, &self.breps);

        self.sweepList(vm, value.ObjGeometry, &self.geometries);
        self.sweepList(vm, value.ObjCrossSection, &self.cross_sections);
        self.sweepList(vm, value.ObjWorkplane, &self.workplanes);
    }

    inline fn destroyObject(self: *GC, comptime T: type, ptr: *T) void {
        std.debug.assert(self.bytes_allocated >= @sizeOf(T));
        self.allocator.destroy(ptr);
        self.bytes_allocated -= @sizeOf(T);
    }

    fn freeObject(self: *GC, vm: *VM, obj: *value.Obj) void {
        switch (obj.obj_type) {
            .geometry => {
                const geom_obj = @as(*value.ObjGeometry, @alignCast(@fieldParentPtr("obj", obj)));
                if (geom_obj.cached_topology) |cache| self.allocator.destroy(cache);
                if (geom_obj.cached_handle) |handle| {
                    if (vm.host.mesh_destructor) |destructor| destructor(handle);
                }
                self.destroyObject(value.ObjGeometry, geom_obj);
            },
            .workplane => {
                const wp_obj = @as(*value.ObjWorkplane, @alignCast(@fieldParentPtr("obj", obj)));
                self.destroyObject(value.ObjWorkplane, wp_obj);
            },
            .cross_section => {
                const cs_obj = @as(*value.ObjCrossSection, @alignCast(@fieldParentPtr("obj", obj)));
                if (cs_obj.cached_handle) |handle| kernel.destructCrossSection(handle);
                self.destroyObject(value.ObjCrossSection, cs_obj);
            },
            .string => {
                const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", obj));
                self.allocator.free(str_obj.chars);
                self.bytes_allocated -= str_obj.chars.len;
                self.destroyObject(value.ObjString, str_obj);
            },
            .symbol => {
                const sym_obj: *value.ObjSymbol = @alignCast(@fieldParentPtr("obj", obj));
                self.allocator.free(sym_obj.chars);
                self.bytes_allocated -= sym_obj.chars.len;
                self.destroyObject(value.ObjSymbol, sym_obj);
            },
            .native => self.destroyObject(value.ObjNative, @alignCast(@fieldParentPtr("obj", obj))),
            .array => {
                const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", obj));
                arr_obj.items.deinit(self.allocator);
                self.destroyObject(value.ObjArray, arr_obj);
            },
            .map => {
                const map_obj: *value.ObjMap = @alignCast(@fieldParentPtr("obj", obj));
                map_obj.keys.deinit(self.allocator);
                map_obj.values.deinit(self.allocator);
                self.destroyObject(value.ObjMap, map_obj);
            },
            .instance => {
                const instance_obj = @as(*value.ObjInstance, @alignCast(@fieldParentPtr("obj", obj)));
                instance_obj.fields.deinit(self.allocator);
                self.destroyObject(value.ObjInstance, instance_obj);
            },
            .closure => {
                const closure = @as(*value.ObjClosure, @alignCast(@fieldParentPtr("obj", obj)));
                const upvals_size = @sizeOf(?*value.ObjUpvalue) * closure.function.upvalue_count;
                self.allocator.free(closure.upvalues[0..closure.function.upvalue_count]);
                self.bytes_allocated -= upvals_size;
                self.destroyObject(value.ObjClosure, closure);
            },
            .function => {
                const func = @as(*value.ObjFunction, @alignCast(@fieldParentPtr("obj", obj)));
                if (func.owns_chunk) {
                    if (func.chunk) |c| {
                        const chnk = @as(*chunk.Chunk, @ptrCast(@alignCast(c)));
                        chnk.free(self.allocator);
                        self.allocator.destroy(chnk);
                    }
                }
                self.destroyObject(value.ObjFunction, func);
            },
            .upvalue => self.destroyObject(value.ObjUpvalue, @alignCast(@fieldParentPtr("obj", obj))),
            .module => {
                const module_obj = @as(*value.ObjModule, @alignCast(@fieldParentPtr("obj", obj)));
                module_obj.methods.deinit(self.allocator);
                self.destroyObject(value.ObjModule, module_obj);
            },
            .class => {
                const class_obj = @as(*value.ObjClass, @alignCast(@fieldParentPtr("obj", obj)));
                class_obj.methods.deinit(self.allocator);
                class_obj.included_modules.deinit(self.allocator);
                class_obj.class_methods.deinit(self.allocator);
                class_obj.class_fields.deinit(self.allocator);
                class_obj.instance_layout.deinit(self.allocator);
                self.destroyObject(value.ObjClass, class_obj);
            },
            .bound_method => self.destroyObject(value.ObjBoundMethod, @alignCast(@fieldParentPtr("obj", obj))),
            .range => self.destroyObject(value.ObjRange, @alignCast(@fieldParentPtr("obj", obj))),
            .brep => {
                const brep_obj: *value.ObjBrep = @alignCast(@fieldParentPtr("obj", obj));
                brep_obj.data.deinit();
                self.allocator.destroy(brep_obj.data);
                self.destroyObject(value.ObjBrep, brep_obj);
            },
        }
    }
};
