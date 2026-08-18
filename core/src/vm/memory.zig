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
        ptr.has_splat = false;
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
    pub fn allocateGeometry(self: *GC, state: value.GeometryState) !*value.ObjGeometry {
        if (self.max_memory_limit) |limit| {
            if (self.bytes_allocated + @sizeOf(value.ObjGeometry) > limit) return error.OutOfMemory;
        }
        const ptr = try self.allocator.create(value.ObjGeometry);
        self.bytes_allocated += @sizeOf(value.ObjGeometry);

        ptr.* = .{
            .obj = .{ .obj_type = .geometry, .is_marked = false, .next = null },
            .ref_count = 1,
            .dag_idx = switch (state) {
                .symbolic => |idx| idx,
                .concrete => 0,
            },
            .cached_handle = switch (state) {
                .symbolic => null,
                .concrete => |h| h,
            },
            .cached_bbox = null,
            .cached_topology = null,
        };
        return ptr;
    }

    pub fn allocateCrossSection(self: *GC, dag_idx: u32) !*value.ObjCrossSection {
        if (self.max_memory_limit) |limit| {
            if (self.bytes_allocated + @sizeOf(value.ObjCrossSection) > limit) return error.OutOfMemory;
        }
        const ptr = try self.allocator.create(value.ObjCrossSection);
        self.bytes_allocated += @sizeOf(value.ObjCrossSection);

        ptr.* = .{
            .obj = .{ .obj_type = .cross_section, .is_marked = false, .next = null },
            .ref_count = 1,
            .dag_idx = dag_idx,
            .cached_handle = null,
        };
        return ptr;
    }

    pub fn allocateWorkplane(self: *GC, parent: *value.ObjGeometry, origin: [3]f64, normal: [3]f64) !*value.ObjWorkplane {
        if (self.max_memory_limit) |limit| {
            if (self.bytes_allocated + @sizeOf(value.ObjWorkplane) > limit) return error.OutOfMemory;
        }
        const ptr = try self.allocator.create(value.ObjWorkplane);
        self.bytes_allocated += @sizeOf(value.ObjWorkplane);

        ptr.* = .{
            .obj = .{ .obj_type = .workplane, .is_marked = false, .next = null },
            .ref_count = 1,
            .parent = parent,
            .origin = origin,
            .normal = normal,
        };
        parent.ref_count += 1;
        return ptr;
    }

    pub fn allocateUpvalue(self: *GC, vm: *VM, local_ptr: *value.Value, next_upval: ?*value.ObjUpvalue) !*value.ObjUpvalue {
        const ptr = try self.allocateObject(vm, value.ObjUpvalue, .upvalue);
        ptr.location = local_ptr;
        ptr.closed = value.Value.initNil();
        ptr.next = next_upval;
        return ptr;
    }

    // --- ARC Deallocators ---
    pub fn freeWorkplane(self: *GC, vm: *VM, wp_obj: *value.ObjWorkplane) void {
        const parent_val = value.Value.initGeometry(wp_obj.parent);
        vm.releaseValue(parent_val);
        self.allocator.destroy(wp_obj);
        self.bytes_allocated -= @sizeOf(value.ObjWorkplane);
    }

    pub fn freeGeometry(self: *GC, vm: *VM, geom_obj: *value.ObjGeometry) void {
        if (geom_obj.cached_topology) |cache| {
            self.allocator.destroy(cache);
        }
        if (geom_obj.cached_handle) |handle| {
            if (vm.host.mesh_destructor) |destructor| destructor(handle);
        }
        self.allocator.destroy(geom_obj);
        self.bytes_allocated -= @sizeOf(value.ObjGeometry);
    }

    pub fn freeCrossSection(self: *GC, vm: *VM, cs_obj: *value.ObjCrossSection) void {
        _ = vm;

        if (cs_obj.cached_handle) |handle| {
            kernel.destructCrossSection(handle);
        }
        self.allocator.destroy(cs_obj);
        self.bytes_allocated -= @sizeOf(value.ObjCrossSection);
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
        if (!val.isObject()) return;
        self.markObject(val.asObj());
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
                var it = instance_obj.fields.valueIterator();
                while (it.next()) |val| self.markValue(val.*);
            },
            .bound_method => {
                const bound_obj = @as(*value.ObjBoundMethod, @alignCast(@fieldParentPtr("obj", obj)));
                self.markValue(bound_obj.receiver);
                self.markObject(&bound_obj.method.obj);
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

    fn freeObject(self: *GC, vm: *VM, obj: *value.Obj) void {
        switch (obj.obj_type) {
            .string => {
                const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", obj));
                _ = vm.strings.remove(str_obj.chars);
                self.allocator.free(str_obj.chars);
                self.bytes_allocated -= str_obj.chars.len;
                self.allocator.destroy(str_obj);
                self.bytes_allocated -= @sizeOf(value.ObjString);
            },
            .symbol => {
                const sym_obj: *value.ObjSymbol = @alignCast(@fieldParentPtr("obj", obj));
                _ = vm.symbols.remove(sym_obj.chars);
                self.allocator.free(sym_obj.chars);
                self.bytes_allocated -= sym_obj.chars.len;
                self.allocator.destroy(sym_obj);
                self.bytes_allocated -= @sizeOf(value.ObjSymbol);
            },
            .native => {
                const native_obj: *value.ObjNative = @alignCast(@fieldParentPtr("obj", obj));
                self.allocator.destroy(native_obj);
                self.bytes_allocated -= @sizeOf(value.ObjNative);
            },
            .array => {
                const arr_obj: *value.ObjArray = @alignCast(@fieldParentPtr("obj", obj));
                arr_obj.items.deinit(self.allocator);
                self.allocator.destroy(arr_obj);
                self.bytes_allocated -= @sizeOf(value.ObjArray);
            },
            .map => {
                const map_obj: *value.ObjMap = @alignCast(@fieldParentPtr("obj", obj));
                map_obj.keys.deinit(self.allocator);
                map_obj.values.deinit(self.allocator);
                self.allocator.destroy(map_obj);
                self.bytes_allocated -= @sizeOf(value.ObjMap);
            },
            .closure => {
                const closure = @as(*value.ObjClosure, @alignCast(@fieldParentPtr("obj", obj)));
                const upvals_size = @sizeOf(?*value.ObjUpvalue) * closure.function.upvalue_count;
                self.allocator.free(closure.upvalues[0..closure.function.upvalue_count]);
                self.allocator.destroy(closure);
                self.bytes_allocated -= (@sizeOf(value.ObjClosure) + upvals_size);
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
                self.allocator.destroy(func);
                self.bytes_allocated -= @sizeOf(value.ObjFunction);
            },
            .upvalue => {
                const upvalue = @as(*value.ObjUpvalue, @alignCast(@fieldParentPtr("obj", obj)));
                self.allocator.destroy(upvalue);
                self.bytes_allocated -= @sizeOf(value.ObjUpvalue);
            },
            .module => {
                const module_obj = @as(*value.ObjModule, @alignCast(@fieldParentPtr("obj", obj)));
                module_obj.methods.deinit(self.allocator);
                self.allocator.destroy(module_obj);
                self.bytes_allocated -= @sizeOf(value.ObjModule);
            },
            .class => {
                const class_obj = @as(*value.ObjClass, @alignCast(@fieldParentPtr("obj", obj)));
                class_obj.methods.deinit(self.allocator);
                class_obj.included_modules.deinit(self.allocator);
                class_obj.class_methods.deinit(self.allocator);
                class_obj.class_fields.deinit(self.allocator);
                self.allocator.destroy(class_obj);
                self.bytes_allocated -= @sizeOf(value.ObjClass);
            },
            .instance => {
                const instance_obj = @as(*value.ObjInstance, @alignCast(@fieldParentPtr("obj", obj)));
                instance_obj.fields.deinit(self.allocator);
                self.allocator.destroy(instance_obj);
                self.bytes_allocated -= @sizeOf(value.ObjInstance);
            },
            .bound_method => {
                const bound_obj = @as(*value.ObjBoundMethod, @alignCast(@fieldParentPtr("obj", obj)));
                self.allocator.destroy(bound_obj);
                self.bytes_allocated -= @sizeOf(value.ObjBoundMethod);
            },
            .range => {
                const range_obj = @as(*value.ObjRange, @alignCast(@fieldParentPtr("obj", obj)));
                self.allocator.destroy(range_obj);
                self.bytes_allocated -= @sizeOf(value.ObjRange);
            },
            .brep => {
                const brep_obj: *value.ObjBrep = @alignCast(@fieldParentPtr("obj", obj));
                brep_obj.data.deinit();

                self.allocator.destroy(brep_obj.data);
                self.allocator.destroy(brep_obj);
                self.bytes_allocated -= @sizeOf(value.ObjBrep);
            },
            .geometry, .workplane, .cross_section => {},
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
