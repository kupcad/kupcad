const std = @import("std");
const testing = std.testing;
const registry = @import("../stdlib/registry.zig");
const value = @import("../core/value.zig");
const VM = @import("vm.zig").VM;
const GC = @import("memory.zig").GC;
const GeometryHandle = @import("../kernel/geometry_handle.zig").GeometryHandle;

fn countObjects(gc: *GC) usize {
    var count: usize = 0;

    // Sum the length of every segregated object pool
    count += gc.strings.items.len;
    count += gc.symbols.items.len;
    count += gc.arrays.items.len;
    count += gc.maps.items.len;
    count += gc.functions.items.len;
    count += gc.classes.items.len;
    count += gc.modules.items.len;
    count += gc.instances.items.len;
    count += gc.closures.items.len;
    count += gc.upvalues.items.len;
    count += gc.bound_methods.items.len;
    count += gc.natives.items.len;
    count += gc.ranges.items.len;
    count += gc.breps.items.len;
    count += gc.geometries.items.len;
    count += gc.cross_sections.items.len;
    count += gc.workplanes.items.len;

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

test "GC: Basic sweep of unrooted objects" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    _ = try vm.gc.allocateString(&vm, "unrooted1");
    _ = try vm.gc.allocateArray(&vm);

    // We allocated 2 objects
    try testing.expectEqual(@as(usize, 2), countObjects(&vm.gc));

    vm.gc.collectGarbage(&vm, false);

    // Neither were pushed to the VM stack, so the sweep MUST destroy both
    try testing.expectEqual(@as(usize, 0), countObjects(&vm.gc));
}

test "GC: Rooted objects survive the sweep" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    const str_obj = try vm.gc.allocateString(&vm, "rooted");
    vm.push(value.Value.initObj(&str_obj.obj)); // Root it to the stack!

    _ = try vm.gc.allocateArray(&vm); // Leave unrooted

    try testing.expectEqual(@as(usize, 2), countObjects(&vm.gc));

    vm.gc.collectGarbage(&vm, false);

    // The string was pushed to the stack, so it survives. The array dies.
    try testing.expectEqual(@as(usize, 1), countObjects(&vm.gc));
    try testing.expectEqual(@as(usize, 1), vm.gc.strings.items.len);
    try testing.expectEqual(@as(usize, 0), vm.gc.arrays.items.len);
}

test "GC Stress: High volume allocations and segmented sweeps" {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    // We will allocate 10,000 Arrays and 10,000 Strings (20,000 total objects)
    const total_allocs = 10_000;

    // We will only root exactly 500 of each type
    const rooted_amount = 500;

    for (0..total_allocs) |i| {
        // Allocate unique strings to bypass the intern cache
        var buf: [16]u8 = undefined;
        const str_val = std.fmt.bufPrint(&buf, "str{d}", .{i}) catch unreachable;

        // Take ownership of a duped string
        const s = try vm.gc.takeString(&vm, try testing.allocator.dupe(u8, str_val));

        // Allocate empty array
        const a = try vm.gc.allocateArray(&vm);

        // Root only the first `rooted_amount` objects
        if (i < rooted_amount) {
            vm.push(value.Value.initObj(&s.obj));
            vm.push(value.Value.initObj(&a.obj));
        }
    }

    // Verify pre-GC counts. We should have exactly 20,000 objects in memory.
    try testing.expectEqual(total_allocs * 2, countObjects(&vm.gc));

    // The specific DOD tracking arrays must match exactly
    try testing.expectEqual(total_allocs, vm.gc.strings.items.len);
    try testing.expectEqual(total_allocs, vm.gc.arrays.items.len);

    // Run the massive Sweep
    vm.gc.collectGarbage(&vm, false);

    // Verify post-GC counts precisely match the rooted amounts!
    // The GC should have deleted exactly 19,000 objects in a fraction of a millisecond.
    try testing.expectEqual(rooted_amount * 2, countObjects(&vm.gc));

    // The segregated arrays must have shrunk using `swapRemove` down to 500.
    try testing.expectEqual(rooted_amount, vm.gc.strings.items.len);
    try testing.expectEqual(rooted_amount, vm.gc.arrays.items.len);
}
