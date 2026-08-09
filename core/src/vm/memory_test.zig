const std = @import("std");
const testing = std.testing;
const value = @import("../core/value.zig");
const VM = @import("vm.zig").VM;
const GC = @import("memory.zig").GC;

test "GC: Mark and Sweep reclaims unreferenced objects" {
    var vm = try VM.init(testing.allocator);
    defer vm.deinit();

    // 1. Allocate a string but DO NOT push it to the stack
    // Pass string literals directly. The GC handles allocating its own heap memory.
    _ = try vm.allocateString("I am dead");

    // 2. Allocate a string and DO push it to the stack (keeping it alive)
    const alive_val = try vm.allocateString("I am alive");
    try vm.push(alive_val);

    // Verify both objects are in the linked list
    try testing.expectEqual(@as(usize, 2), countObjects(&vm.gc));

    // 3. Run the Garbage Collector
    vm.gc.collectGarbage(&vm, false);

    // 4. Verify the orphaned string was destroyed, but the stacked one survived
    try testing.expectEqual(@as(usize, 1), countObjects(&vm.gc));

    const surviving_obj = vm.gc.first_object.?;
    try testing.expectEqual(value.ObjType.string, surviving_obj.obj_type);
}

// Helper to count objects in the intrusive linked list
fn countObjects(gc: *GC) usize {
    var count: usize = 0;
    var current = gc.first_object;
    while (current) |obj| {
        count += 1;
        current = obj.next;
    }
    return count;
}
