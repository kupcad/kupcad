const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("vm.zig").VM;

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
    pub fn allocateString(self: *GC, chars: []const u8) !*value.ObjString {
        // Allocate the memory for the wrapper
        const ptr = try self.allocator.create(value.ObjString);

        // The GC MUST own the string memory, so we duplicate the bytes into a new allocation.
        const owned_chars = try self.allocator.dupe(u8, chars);

        // Track the total memory allocated (Wrapper Struct + String Slice)
        self.bytes_allocated += @sizeOf(value.ObjString) + owned_chars.len;

        // Initialize the Obj header and link it to the GC list
        ptr.obj = .{
            .obj_type = .string,
            .is_marked = false,
            .next = self.first_object,
        };
        self.first_object = &ptr.obj;

        // Set the payload to the GC-owned memory
        ptr.chars = owned_chars;

        return ptr;
    }

    /// Allocates an ObjMesh, registering it with the VM's Garbage Collector.
    pub fn allocateMesh(self: *GC, handle: ?*anyopaque, vertices: []const value.Vec3, faces: []const [3]u32) !*value.ObjMesh {
        const ptr = try self.allocator.create(value.ObjMesh);

        // Deep copy the geometry so the VM safely owns the memory
        const owned_vertices = try self.allocator.dupe(value.Vec3, vertices);
        const owned_faces = try self.allocator.dupe([3]u32, faces);

        self.bytes_allocated += @sizeOf(value.ObjMesh) +
            (owned_vertices.len * @sizeOf(value.Vec3)) +
            (owned_faces.len * @sizeOf([3]u32));

        ptr.obj = .{
            .obj_type = .mesh,
            .is_marked = false,
            .next = self.first_object,
        };
        self.first_object = &ptr.obj;

        ptr.kernel_handle = handle;
        ptr.vertices = owned_vertices;
        ptr.faces = owned_faces;

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

    // --- Phase 1: Mark ---

    fn markRoots(self: *GC, vm: *VM) void {
        // Mark the Shadow Stack (WASM-Safe!)
        for (vm.stack[0..vm.stack_top]) |val| {
            self.markValue(val);
        }

        // Mark constants in active call frames
        for (vm.frames.items) |frame| {
            for (frame.chunk.constants.items) |val| {
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
        _ = self;

        if (obj.is_marked) return; // Prevent infinite loops on circular references

        obj.is_marked = true;

        // If this object contained references to other objects (like an Array or Map),
        // we would recursively call markValue on its children here.
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
            .mesh => {
                const mesh_obj: *value.ObjMesh = @alignCast(@fieldParentPtr("obj", obj));
                self.allocator.free(mesh_obj.vertices);
                self.allocator.free(mesh_obj.faces);
                self.bytes_allocated -= (mesh_obj.vertices.len * @sizeOf(value.Vec3)) +
                    (mesh_obj.faces.len * @sizeOf([3]u32));

                if (mesh_obj.kernel_handle) |handle| {
                    if (vm.mesh_destructor) |destructor| {
                        destructor(handle);
                    }
                }

                self.allocator.destroy(mesh_obj);
                self.bytes_allocated -= @sizeOf(value.ObjMesh);
            },
            .brep => {
                const brep_obj: *value.ObjBrep = @alignCast(@fieldParentPtr("obj", obj));
                // TODO: Call brep_obj.data.deinit() when Brep memory management is fleshed out
                self.allocator.destroy(brep_obj.data); // Free the inner struct
                self.allocator.destroy(brep_obj); // Free the wrapper
                self.bytes_allocated -= @sizeOf(value.ObjBrep);
            },
            .array => {
                // Future Implementation
            },
        }
    }
};
