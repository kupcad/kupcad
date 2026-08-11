const std = @import("std");
const value = @import("../core/value.zig");
const chunk = @import("chunk.zig");
const VM = @import("vm.zig").VM;
const GeometryHandle = @import("../kernel/geometry_handle.zig").GeometryHandle;

pub const GC = struct {
    allocator: std.mem.Allocator,
    first_object: ?*value.Obj,

    // GC triggering metrics
    bytes_allocated: usize,
    next_gc_threshold: usize,

    const HEAP_GROW_FACTOR: usize = 2;

    pub fn init(allocator: std.mem.Allocator) GC {
        return .{
            .allocator = allocator,
            .first_object = null,
            .bytes_allocated = 0,
            .next_gc_threshold = 1024 * 1024, // 1MB starting threshold
        };
    }

    /// Allocates an ObjString, registers it with the GC, and duplicates the string payload.
    pub fn allocateString(self: *GC, vm: *VM, chars: []const u8) !*value.ObjString {
        if (vm.strings.get(chars)) |existing| {
            return existing;
        }

        const ptr = try self.allocator.create(value.ObjString);
        const owned_chars = try self.allocator.dupe(u8, chars);

        self.bytes_allocated += @sizeOf(value.ObjString) + owned_chars.len;

        ptr.obj = .{
            .obj_type = .string,
            .is_marked = false,
            .next = self.first_object,
        };
        self.first_object = &ptr.obj;
        ptr.chars = owned_chars;

        // --- NEW: Register in String Table ---
        try vm.strings.put(self.allocator, ptr.chars, ptr);

        return ptr;
    }

    /// Allocates an ObjNative, registering it with the GC.
    pub fn allocateNative(self: *GC, function: value.NativeFn) !*value.ObjNative {
        const ptr = try self.allocator.create(value.ObjNative);
        self.bytes_allocated += @sizeOf(value.ObjNative);

        ptr.obj = .{
            .obj_type = .native,
            .is_marked = false,
            .next = self.first_object,
        };
        self.first_object = &ptr.obj;
        ptr.function = function;

        return ptr;
    }

    /// The main entry point for the Garbage Collector
    pub fn collectGarbage(self: *GC, vm: *VM, force_full: bool) void {
        // std.debug.print("-- GC Begin --\n", .{});
        const before = self.bytes_allocated;

        if (!force_full) {
            self.markRoots(vm);
        }
        self.sweep(vm);

        self.next_gc_threshold = self.bytes_allocated * HEAP_GROW_FACTOR;
        _ = before;
        // std.debug.print("-- GC End (Freed {} bytes) --\n", .{before - self.bytes_allocated});
    }

    pub fn allocateArray(self: *GC, vm: *VM) !*value.ObjArray {
        if (self.bytes_allocated > self.next_gc_threshold) {
            self.collectGarbage(vm, false);
        }
        const ptr = try self.allocator.create(value.ObjArray);
        self.bytes_allocated += @sizeOf(value.ObjArray);
        ptr.obj = .{
            .obj_type = .array,
            .is_marked = false,
            .next = self.first_object,
        };
        self.first_object = &ptr.obj;
        ptr.items = .empty;
        return ptr;
    }

    pub fn allocateMap(self: *GC, vm: *VM) !*value.ObjMap {
        if (self.bytes_allocated > self.next_gc_threshold) {
            self.collectGarbage(vm, false);
        }
        const ptr = try self.allocator.create(value.ObjMap);
        self.bytes_allocated += @sizeOf(value.ObjMap);
        ptr.obj = .{
            .obj_type = .map,
            .is_marked = false,
            .next = self.first_object,
        };
        self.first_object = &ptr.obj;
        ptr.keys = .empty;
        ptr.values = .empty;
        return ptr;
    }

    pub fn allocateFunction(self: *GC, vm: *VM) !*value.ObjFunction {
        if (self.bytes_allocated > self.next_gc_threshold) {
            self.collectGarbage(vm, false);
        }
        const ptr = try self.allocator.create(value.ObjFunction);
        self.bytes_allocated += @sizeOf(value.ObjFunction);
        ptr.obj = .{
            .obj_type = .function,
            .is_marked = false,
            .next = self.first_object,
        };
        self.first_object = &ptr.obj;
        ptr.name = null;
        return ptr;
    }

    pub fn allocateClosure(self: *GC, vm: *VM, function: *value.ObjFunction) !*value.ObjClosure {
        if (self.bytes_allocated > self.next_gc_threshold) {
            self.collectGarbage(vm, false);
        }
        const ptr = try self.allocator.create(value.ObjClosure);
        const upvalues = try self.allocator.alloc(?*value.ObjUpvalue, function.upvalue_count);
        @memset(upvalues, null);

        self.bytes_allocated += @sizeOf(value.ObjClosure) + (@sizeOf(?*value.ObjUpvalue) * upvalues.len);
        ptr.obj = .{
            .obj_type = .closure,
            .is_marked = false,
            .next = self.first_object,
        };
        self.first_object = &ptr.obj;
        ptr.function = function;
        ptr.upvalues = upvalues.ptr;
        return ptr;
    }

    // --- Phase 1: Mark ---

    fn markRoots(self: *GC, vm: *VM) void {
        // Mark the Shadow Stack (WASM-Safe!)
        for (vm.stack[0..vm.stack_top]) |val| {
            self.markValue(val);
        }

        // Extract chunk through the closure
        for (vm.frames.items) |frame| {
            const exec_chunk = @as(*chunk.Chunk, @ptrCast(@alignCast(frame.closure.function.chunk)));
            for (exec_chunk.constants.items) |val| {
                self.markValue(val);
            }
        }

        // Mark Global Variables (Built-ins and Script Globals)
        var globals_it = vm.globals.valueIterator();
        while (globals_it.next()) |val| {
            self.markValue(val.*);
        }
    }

    fn markValue(self: *GC, val: value.Value) void {
        if (!val.isObject()) return;
        self.markObject(val.asObj());
    }

    fn markObject(self: *GC, obj: *value.Obj) void {
        if (obj.is_marked) return;
        obj.is_marked = true;

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
                // Trace captured upvalues to prevent them from being swept
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
                // Note: The function's Chunk constants are traced via CallFrames
            },
            else => {},
        }
    }

    // --- Phase 2: Sweep ---

    fn sweep(self: *GC, vm: *VM) void {
        var previous: ?*value.Obj = null;
        var current: ?*value.Obj = self.first_object;

        while (current) |obj| {
            if (obj.is_marked) {
                // Object is alive. Unmark it for the next GC cycle and move on.
                obj.is_marked = false;
                previous = obj;
                current = obj.next;
            } else {
                // Object is dead. Unlink and free it.
                const unreached = obj;
                current = obj.next;

                if (previous) |prev| {
                    prev.next = current;
                } else {
                    self.first_object = current;
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
                self.allocator.free(closure.upvalues[0..closure.function.upvalue_count]);
                self.allocator.destroy(closure);
                self.bytes_allocated -= @sizeOf(value.ObjClosure);
            },
            .function => {
                const func = @as(*value.ObjFunction, @alignCast(@fieldParentPtr("obj", obj)));
                self.allocator.destroy(func);
                self.bytes_allocated -= @sizeOf(value.ObjFunction);
            },
            .upvalue => {
                const upvalue = @as(*value.ObjUpvalue, @alignCast(@fieldParentPtr("obj", obj)));
                self.allocator.destroy(upvalue);
                self.bytes_allocated -= @sizeOf(value.ObjUpvalue);
            },
            .brep => {
                const brep_obj: *value.ObjBrep = @alignCast(@fieldParentPtr("obj", obj));
                // TODO: Call brep_obj.data.deinit() when Brep memory management is fleshed out
                self.allocator.destroy(brep_obj.data); // Free the inner struct
                self.allocator.destroy(brep_obj); // Free the wrapper
                self.bytes_allocated -= @sizeOf(value.ObjBrep);
            },
            .geometry, .workplane => {
                // Ignored by tracing GC. Managed via ARC or not implemented yet.
            },
        }
    }
};
