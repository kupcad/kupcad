const std = @import("std");
const testing = std.testing;
const names_mod = @import("names.zig");
const UniqueNames = names_mod.UniqueNames;

test "names: a name taken again is numbered, past any number already taken" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var names: UniqueNames = .{ .arena = arena.allocator() };
    try testing.expectEqualStrings("plate", try names.take("plate"));
    try testing.expectEqualStrings("plate_2", try names.take("plate"));
    try testing.expectEqualStrings("lid", try names.take("lid"));
    // A name that already is "plate_3" takes that number, and the next "plate" skips it
    try testing.expectEqualStrings("plate_3", try names.take("plate_3"));
    try testing.expectEqualStrings("plate_4", try names.take("plate"));
}

test "names: a name is itself the first time, numbered after it from the second" {
    const first = try names_mod.numberedName(testing.allocator, "lid", 1);
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("lid", first);
    const third = try names_mod.numberedName(testing.allocator, "lid", 3);
    defer testing.allocator.free(third);
    try testing.expectEqualStrings("lid_3", third);
}
