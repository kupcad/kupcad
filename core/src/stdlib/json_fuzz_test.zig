//! Fuzzing `import_json` (json.zig) on whatever a JSON file a script reads may hold. It must
//! take any bytes without crashing or leaking, refuse what it can't read with an error, and
//! give what a script may rely on: finite numbers, String keys, nesting within
//! MAX_JSON_DEPTH, the same values on every read (`==`), and a JsonObject that `to_h` turns
//! into Maps all the way down. A plain test run replays the files in json_fuzz_corpus/;
//! `zig build fuzz -Dfuzz-target=json --fuzz=<runs>` searches from them.

const std = @import("std");
const testing = std.testing;
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const limits = @import("../core/limits.zig");
const import_json = @import("json.zig");
const json_object = @import("classes/json_object.zig");

/// The longest input the fuzzer makes.
const MAX_INPUT_BYTES = 16 * 1024;
const Buffer = [MAX_INPUT_BYTES]u8;
const CORPUS_DIR = "src/stdlib/json_fuzz_corpus";
/// The file a fuzzed input is read from.
const FUZZ_PATH = "fuzz.json";

/// json_fuzz_corpus/<name>.json, and whether import_json reads it.
const SEEDS = [_]struct { name: []const u8, reads: bool }{
    .{ .name = "machine", .reads = true },
    .{ .name = "types", .reads = true },
    .{ .name = "strings", .reads = true },
    .{ .name = "deep", .reads = true },
    .{ .name = "duplicate_key", .reads = false },
    .{ .name = "huge_number", .reads = false },
    .{ .name = "truncated", .reads = false },
    .{ .name = "trailing_comma", .reads = false },
};

const CORPUS = blk: {
    var files: [SEEDS.len][]const u8 = undefined;
    for (SEEDS, &files) |seed, *file| {
        file.* = @embedFile("json_fuzz_corpus/" ++ seed.name ++ ".json");
        if (file.len > MAX_INPUT_BYTES) @compileError(seed.name ++ ".json is longer than MAX_INPUT_BYTES");
    }
    break :blk files;
};

test "fuzz: a JSON file a script reads" {
    const buf = try testing.allocator.create(Buffer);
    defer testing.allocator.destroy(buf);
    try testing.fuzz(buf, struct {
        fn one(b: *Buffer, smith: *testing.Smith) anyerror!void {
            _ = try checkJson(b[0..smith.slice(b)]);
        }
    }.one, .{ .corpus = &CORPUS });
}

test "json fuzz corpus: each seed is read or refused as it says, and every file is listed" {
    for (SEEDS, CORPUS) |seed, data| {
        errdefer std.debug.print("{s}.json\n", .{seed.name});
        try testing.expectEqual(seed.reads, try checkJson(data));
    }
    var dir = try std.Io.Dir.cwd().openDir(testing.io, CORPUS_DIR, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        const name = if (std.mem.endsWith(u8, entry.name, ".json")) entry.name[0 .. entry.name.len - ".json".len] else entry.name;
        const listed = for (SEEDS) |seed| {
            if (std.mem.eql(u8, name, seed.name)) break true;
        } else false;
        errdefer std.debug.print("{s}/{s} isn't listed in SEEDS, so the fuzzer never starts from it\n", .{ CORPUS_DIR, entry.name });
        try testing.expect(listed);
    }
}

/// Reads `data` as a script's JSON file, checking what it promises; false when it is
/// refused (with the error a script sees).
fn checkJson(data: []const u8) !bool {
    // A bare VM: import_json needs the heap and the file system, not the standard library
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    vm.mute_errors = true;
    var files = MemoryVfs.init(testing.allocator);
    defer files.deinit();
    try files.vfs().writeFile(FUZZ_PATH, data);
    vm.vfs = files.vfs();

    const first = import_json.nativeImportJson(&vm, FUZZ_PATH, null) catch |err| {
        if (err == error.RuntimeError) return false;
        return err;
    };
    vm.push(first); // rooted while the rest allocates
    try expectScriptData(first, limits.MAX_JSON_DEPTH);
    const second = try import_json.nativeImportJson(&vm, FUZZ_PATH, null);
    vm.push(second);
    try testing.expect(vm.valuesEqual(first, second));

    var printed: std.Io.Writer.Allocating = .init(testing.allocator);
    defer printed.deinit();
    try first.stringify(true, &printed.writer);
    if (first.isJsonObject()) try expectPlain(try json_object.jsonToH(&vm, first.asJsonObject()));
    return true;
}

/// What a script may rely on in import_json's data: finite numbers, String keys, nesting
/// of at most `depth` levels more.
fn expectScriptData(v: value.Value, depth: usize) !void {
    if (v.isNumber()) try testing.expect(std.math.isFinite(v.asNumber()));
    if (v.isArray()) {
        try testing.expect(depth > 0);
        for (v.asArray().items.items) |item| try expectScriptData(item, depth - 1);
    }
    if (v.isJsonObject()) {
        try testing.expect(depth > 0);
        const entries = &v.asJsonObject().map;
        for (entries.keys(), entries.values()) |key, item| {
            try testing.expect(key.isString());
            try expectScriptData(item, depth - 1);
        }
    }
}

/// `to_h`'s copy: Maps and Arrays, no JsonObject left in it.
fn expectPlain(v: value.Value) !void {
    try testing.expect(!v.isJsonObject());
    if (v.isArray()) for (v.asArray().items.items) |item| try expectPlain(item);
    if (v.isMap()) for (v.asMap().map.values()) |item| try expectPlain(item);
}
