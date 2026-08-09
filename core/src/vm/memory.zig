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

    /// The main entry point for the Garbage Collector
    pub fn collectGarbage(self: *GC, vm: *VM, force_full: bool) void {
        // std.debug.print("-- GC Begin --\n", .{});
        const before = self.bytes_allocated;

        if (!force_full) {
            self.markRoots(vm);
        }
        self.sweep();

        self.next_gc_threshold = self.bytes_allocated * HEAP_GROW_FACTOR;
        _ = before;
        // std.debug.print("-- GC End (Freed {} bytes) --\n", .{before - self.bytes_allocated});
    }

    // --- Phase 1: Mark ---

    fn markRoots(self: *GC, vm: *VM) void {
        // 1. Mark the Shadow Stack (WASM-Safe!)
        for (vm.stack[0..vm.stack_top]) |val| {
            self.markValue(val);
        }

        // 2. Mark constants in active call frames
        for (vm.frames.items) |frame| {
            for (frame.chunk.constants.items) |val| {
                self.markValue(val);
            }
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

    fn sweep(self: *GC) void {
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

                self.freeObject(unreached);
            }
        }
    }

    fn freeObject(self: *GC, obj: *value.Obj) void {
        switch (obj.obj_type) {
            .string => {
                const str_obj: *value.ObjString = @alignCast(@fieldParentPtr("obj", obj));
                // Free the string slice buffer
                self.allocator.free(str_obj.chars);
                self.bytes_allocated -= str_obj.chars.len;
                // Free the struct wrapper
                self.allocator.destroy(str_obj);
                self.bytes_allocated -= @sizeOf(value.ObjString);
            },
            .array => {
                // Future Implementation
            },
        }
    }
};
