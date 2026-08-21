const std = @import("std");
const value = @import("../core/value.zig");
const chunk = @import("chunk.zig");
const VM = @import("vm.zig").VM;
const kernel = @import("../kernel/kernel.zig");
const GeometryHandle = @import("../kernel/geometry_handle.zig").GeometryHandle;

pub const GC = struct {
    allocator: std.mem.Allocator,
    first_object: ?*value.Obj,

    // Explicit Grey Stack to prevent C-Stack Overflow
    gray_stack: std.ArrayListUnmanaged(*value.Obj) = .empty,

    // GC triggering metrics
    bytes_allocated: usize,
    next_gc_threshold: usize,

    // Hard Sandbox Memory Limit
    max_memory_limit: ?usize,

    const HEAP_GROW_FACTOR: usize = 2;

    pub fn init(allocator: std.mem.Allocator) GC {
        return .{
            .allocator = allocator,
            .first_object = null,
            .bytes_allocated = 0,
            .next_gc_threshold = 1024 * 1024, // 1MB starting threshold
            .max_memory_limit = null, // Can be configured post-init for sandboxing
        };
    }

    pub fn deinit(self: *GC) void {
        self.gray_stack.deinit(self.allocator);
    }

    /// The main entry point for the Garbage Collector
    pub fn collectGarbage(self: *GC, vm: *VM, force_full: bool) void {
        const before = self.bytes_allocated;

        if (!force_full) {
            self.markRoots(vm);
            // Process the Grey Stack
            self.traceReferences();
        }

        self.sweep(vm);
        self.next_gc_threshold = self.bytes_allocated * HEAP_GROW_FACTOR;
        _ = before;
    }

    inline fn allocateObject(self: *GC, vm: *VM, comptime T: type, obj_type: value.ObjType) !*T {
        // Soft Threshold: Trigger standard GC
        if (self.bytes_allocated + @sizeOf(T) > self.next_gc_threshold) {
            self.collectGarbage(vm, false);
        }

        // Hard Limit: Sandbox Check
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
            .next = self.first_object,
        };
        self.first_object = &ptr.obj;
        return ptr;
    }

    pub fn allocateArray(self: *GC, vm: *VM) !*value.ObjArray {
        const ptr = try self.allocateObject(vm, value.ObjArray, .array);
        ptr.items = .empty;
        return ptr;
    }

    pub fn allocateMap(self: *GC, vm: *VM) !*value.ObjMap {
        const ptr = try self.allocateObject(vm, value.ObjMap, .map);
        ptr.keys = .empty;
        ptr.values = .empty;
        return ptr;
    }

    pub fn allocateFunction(self: *GC, vm: *VM) !*value.ObjFunction {
        const ptr = try self.allocateObject(vm, value.ObjFunction, .function);
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
        const ptr = try self.allocateObject(vm, value.ObjClass, .class);
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
        const ptr = try self.allocateObject(vm, value.ObjModule, .module);
        ptr.name = name;
        ptr.methods = .empty;
        return ptr;
    }

    pub fn allocateInstance(self: *GC, vm: *VM, class: *value.ObjClass) !*value.ObjInstance {
        const ptr = try self.allocateObject(vm, value.ObjInstance, .instance);
        ptr.class = class;
        ptr.fields = .empty;
        return ptr;
    }

    pub fn allocateBoundMethod(self: *GC, vm: *VM, receiver: value.Value, method: *value.ObjClosure) !*value.ObjBoundMethod {
        const ptr = try self.allocateObject(vm, value.ObjBoundMethod, .bound_method);
        ptr.receiver = receiver;
        ptr.method = method;
        return ptr;
    }

    pub fn allocateNative(self: *GC, vm: *VM, function: value.NativeFn) !*value.ObjNative {
        const ptr = try self.allocateObject(vm, value.ObjNative, .native);
        ptr.function = function;
        return ptr;
    }

    pub fn allocateRange(self: *GC, vm: *VM, start: f64, end: f64, step: f64, is_exclusive: bool) !*value.ObjRange {
        const ptr = try self.allocateObject(vm, value.ObjRange, .range);
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

        const ptr = self.allocateObject(vm, value.ObjClosure, .closure) catch |err| {
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

        const ptr = self.allocateObject(vm, value.ObjString, .string) catch |err| {
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

        const ptr = self.allocateObject(vm, value.ObjSymbol, .symbol) catch |err| {
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

    // --- ARC Allocators (Bypasses GC Tracking) ---
    pub fn allocateGeometry(self: *GC, vm: *VM, state: value.GeometryState) !*value.ObjGeometry {
        const ptr = try self.allocateObject(vm, value.ObjGeometry, .geometry);
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
        const ptr = try self.allocateObject(vm, value.ObjCrossSection, .cross_section);
        ptr.dag_idx = dag_idx;
        ptr.cached_handle = null;
        return ptr;
    }

    pub fn allocateWorkplane(self: *GC, vm: *VM, parent: *value.ObjGeometry, origin: [3]f64, normal: [3]f64) !*value.ObjWorkplane {
        const ptr = try self.allocateObject(vm, value.ObjWorkplane, .workplane);
        ptr.parent = parent;
        ptr.origin = origin;
        ptr.normal = normal;
        return ptr;
    }

    pub fn allocateUpvalue(self: *GC, vm: *VM, local_ptr: *value.Value, next_upval: ?*value.ObjUpvalue) !*value.ObjUpvalue {
        const ptr = try self.allocateObject(vm, value.ObjUpvalue, .upvalue);
        ptr.location = local_ptr;
        ptr.closed = value.Value.initNil();
        ptr.next = next_upval;
        return ptr;
    }

    // --- Phase 1: Mark ---
    fn markRoots(self: *GC, vm: *VM) void {
        // Mark the Stack
        for (vm.stack[0..vm.stack_top]) |val| {
            self.markValue(val);
        }

        // Mark Call Frames
        for (vm.frames.items) |frame| {
            // Explicitly mark the closure running this frame
            self.markObject(&frame.closure.obj);

            const exec_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(frame.closure.function.chunk.?)));
            for (exec_chunk.constants.items) |val| {
                self.markValue(val);
            }
        }

        // Mark Open Upvalues
        var upval = vm.open_upvalues;
        while (upval) |u| {
            self.markObject(&u.obj);
            upval = u.next;
        }

        // Mark Script Globals
        var globals_it = vm.globals.valueIterator();
        while (globals_it.next()) |val| {
            self.markValue(val.*);
        }

        // Mark Parameter Registry
        for (vm.param_registry.items(.name)) |name| self.markValue(name);
        for (vm.param_registry.items(.current_value)) |val| self.markValue(val);
        for (vm.param_registry.items(.choices)) |choice| {
            if (choice) |arr| self.markObject(&arr.obj);
        }

        // Mark Built-in Primitive Classes
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
        } else if (val.isGeometry()) {
            self.markObject(&val.asGeometry().obj);
        } else if (val.isCrossSection()) {
            self.markObject(&val.asCrossSection().obj);
        } else if (val.isWorkplane()) {
            self.markObject(&val.asWorkplane().obj);
        }
    }

    fn markObject(self: *GC, obj: *value.Obj) void {
        if (obj.is_marked) return;
        obj.is_marked = true;
        // O(1) Push to Grey Stack. Avoids blowing C Call Stack.
        self.gray_stack.append(self.allocator, obj) catch @panic("OOM during GC Grey Stack tracking.");
    }

    fn traceReferences(self: *GC) void {
        while (self.gray_stack.items.len > 0) {
            const obj = self.gray_stack.pop();
            self.blackenObject(obj.?);
        }
    }

    fn blackenObject(self: *GC, obj: *value.Obj) void {
        switch (obj.obj_type) {
            .array => {
                const arr = @as(*value.ObjArray, @alignCast(@fieldParentPtr("obj", obj)));
                for (arr.items.items) |val| {
                    self.markValue(val);
                }
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
                    if (closure.upvalues[i]) |upvalue| {
                        self.markObject(&upvalue.obj);
                    }
                }
            },
            .upvalue => {
                const upval = @as(*value.ObjUpvalue, @alignCast(@fieldParentPtr("obj", obj)));
                self.markValue(upval.closed);
            },
            .function => {
                const func = @as(*value.ObjFunction, @alignCast(@fieldParentPtr("obj", obj)));
                if (func.name) |name| self.markObject(&name.obj);
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

    // --- Phase 2: Sweep ---
    fn sweep(self: *GC, vm: *VM) void {
        var str_iter = vm.strings.iterator();
        while (str_iter.next()) |entry| {
            if (!entry.value_ptr.*.obj.is_marked) {
                _ = vm.strings.remove(entry.key_ptr.*);
            }
        }

        var sym_iter = vm.symbols.iterator();
        while (sym_iter.next()) |entry| {
            if (!entry.value_ptr.*.obj.is_marked) {
                _ = vm.symbols.remove(entry.key_ptr.*);
            }
        }

        var previous: ?*value.Obj = null;
        var object = self.first_object;
        while (object) |obj| {
            if (obj.is_marked) {
                obj.is_marked = false; // Reset mark for next GC cycle
                previous = obj;
                object = obj.next;
            } else {
                const unreached = obj;
                object = obj.next;
                if (previous) |prev| {
                    prev.next = object;
                } else {
                    self.first_object = object;
                }
                self.freeObject(vm, unreached);
            }
        }
    }

    inline fn destroyObject(self: *GC, comptime T: type, ptr: *T) void {
        // Prevent integer underflow on double-free or size mismatch
        std.debug.assert(self.bytes_allocated >= @sizeOf(T));

        self.allocator.destroy(ptr);
        self.bytes_allocated -= @sizeOf(T);
    }

    fn freeObject(self: *GC, vm: *VM, obj: *value.Obj) void {
        switch (obj.obj_type) {
            .geometry => {
                const geom_obj = @as(*value.ObjGeometry, @alignCast(@fieldParentPtr("obj", obj)));

                if (geom_obj.cached_topology) |cache| {
                    self.allocator.destroy(cache);
                }

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
                if (cs_obj.cached_handle) |handle| {
                    kernel.destructCrossSection(handle);
                }
                self.destroyObject(value.ObjCrossSection, cs_obj);
            },
            .string => {
                const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", obj));
                _ = vm.strings.remove(str_obj.chars);
                self.allocator.free(str_obj.chars);
                self.bytes_allocated -= str_obj.chars.len;
                self.destroyObject(value.ObjString, str_obj);
            },
            .symbol => {
                const sym_obj: *value.ObjSymbol = @alignCast(@fieldParentPtr("obj", obj));
                _ = vm.symbols.remove(sym_obj.chars);
                self.allocator.free(sym_obj.chars);
                self.bytes_allocated -= sym_obj.chars.len;
                self.destroyObject(value.ObjSymbol, sym_obj);
            },
            .native => {
                const native_obj: *value.ObjNative = @alignCast(@fieldParentPtr("obj", obj));
                self.destroyObject(value.ObjNative, native_obj);
            },
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
            .upvalue => {
                const upvalue = @as(*value.ObjUpvalue, @alignCast(@fieldParentPtr("obj", obj)));
                self.destroyObject(value.ObjUpvalue, upvalue);
            },
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
            .bound_method => {
                const bound_obj = @as(*value.ObjBoundMethod, @alignCast(@fieldParentPtr("obj", obj)));
                self.destroyObject(value.ObjBoundMethod, bound_obj);
            },
            .range => {
                const range_obj = @as(*value.ObjRange, @alignCast(@fieldParentPtr("obj", obj)));
                self.destroyObject(value.ObjRange, range_obj);
            },
            .brep => {
                const brep_obj: *value.ObjBrep = @alignCast(@fieldParentPtr("obj", obj));
                brep_obj.data.deinit();
                self.allocator.destroy(brep_obj.data);
                self.destroyObject(value.ObjBrep, brep_obj);
            },
        }
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

        const ptr = self.allocateObject(vm, value.ObjString, .string) catch |err| {
            self.allocator.free(chars);
            return err;
        };

        self.bytes_allocated += chars.len;
        ptr.chars = chars; // Takes ownership directly

        vm.strings.put(self.allocator, ptr.chars, ptr) catch |err| {
            self.allocator.free(chars);
            return err;
        };
        return ptr;
    }
};
