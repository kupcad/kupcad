const std = @import("std");
const testing = std.testing;
const support = @import("../test_support.zig");
const exports_fingerprint = @import("exports_fingerprint.zig");

/// The fingerprint of what `source` exports, or null when a value isn't hashed by content.
fn fingerprint(source: []const u8) !?u64 {
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try support.runOn(&vm, source));
    var hasher = std.hash.Wyhash.init(0);
    if (!exports_fingerprint.hashExports(&hasher, &vm)) return null;
    return hasher.final();
}

test "exports fingerprint: an export's value changes it, the same values keep it" {
    // An importer re-runs only when this changes: a number changed in a module (w = 10 to
    // w = 12) must change it, or importers keep the old value
    const ten = (try fingerprint("w = 10\nexport { w }")).?;
    try testing.expectEqual(ten, (try fingerprint("w = 10\nexport { w }")).?);
    try testing.expect(ten != (try fingerprint("w = 12\nexport { w }")).?);
    // By name too, and by kind: a String and a Symbol of one name differ
    try testing.expect(ten != (try fingerprint("v = 10\nexport { v }")).?);
    try testing.expect((try fingerprint("w = \"a\"\nexport { w }")).? != (try fingerprint("w = :a\nexport { w }")).?);
    // Containers by their content, a shape by its node
    try testing.expectEqual((try fingerprint("w = [1, { a: 2 }]\nexport { w }")).?, (try fingerprint("w = [1, { a: 2 }]\nexport { w }")).?);
    try testing.expect((try fingerprint("w = [1, 2]\nexport { w }")).? != (try fingerprint("w = [2, 1]\nexport { w }")).?);
    try testing.expect((try fingerprint("w = cube(1)\nexport { w }")).? != (try fingerprint("w = cube(2)\nexport { w }")).?);
}

test "exports fingerprint: a function or an object counts as changed whenever its module runs" {
    try testing.expectEqual(@as(?u64, null), try fingerprint("def f\n  1\nend\nexport { f }"));
    try testing.expectEqual(@as(?u64, null), try fingerprint("class P\nend\nexport { P }"));
}
