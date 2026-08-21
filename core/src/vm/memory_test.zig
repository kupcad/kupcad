const std = @import("std");
const testing = std.testing;
const registry = @import("../stdlib/registry.zig");
const value = @import("../core/value.zig");
const VM = @import("vm.zig").VM;
const GC = @import("memory.zig").GC;
const GeometryHandle = @import("../kernel/geometry_handle.zig").GeometryHandle;

fn countObjects(gc: *GC) usize {
    var count: usize = 0;
    var current = gc.first_object;
    while (current) |obj| {
        count += 1;
        current = obj.next;
    }
    return count;
}

test "GC: Mark and Sweep reclaims unreferenced primitive objects" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    _ = try vm.allocateString("I am dead");
    const alive_val = try vm.allocateString("I am alive");

    vm.push(alive_val);

    const count_before = countObjects(&vm.gc);
    vm.gc.collectGarbage(&vm, false);
    const count_after = countObjects(&vm.gc);

    try testing.expect(count_before > count_after);
}

test "GC: allocateRange correctly registers and sweeps" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);

    const count_before = countObjects(&vm.gc);

    // Allocate a new range primitive
    const range = try vm.gc.allocateRange(&vm, 1.0, 10.0, 1.0, false);

    // Verify it was added to the GC linked list
    try testing.expectEqual(count_before + 1, countObjects(&vm.gc));
    try testing.expectEqual(@as(f64, 1.0), range.start);
    try testing.expectEqual(@as(f64, 10.0), range.end);
    try testing.expectEqual(false, range.is_exclusive);

    // Trigger a garbage collection cycle.
    // Because we NEVER pushed the range to the VM Stack (vm.push),
    // the GC's markRoots phase will see it as unreachable/dead memory.
    vm.gc.collectGarbage(&vm, false);

    // Verify it was cleanly swept from the heap
    try testing.expectEqual(count_before, countObjects(&vm.gc));
}
