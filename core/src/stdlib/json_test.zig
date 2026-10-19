//! `import_json` and the JsonObject it gives: keys found by String or Symbol, read-only,
//! `fetch` and `dig` raising errors that name the place in the file, `to_h` a Map to change.

const std = @import("std");
const testing = std.testing;
const support = @import("../test_support.zig");
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const limits = @import("../core/limits.zig");

const MACHINE =
    \\{"name": "braider", "count": 12, "hollow": true, "note": null,
    \\ "gears": [{"module": 1.5, "teeth": 12}, {"module": 2, "teeth": 20}],
    \\ "frame": {"w": 40, "h": 30}, "empty": {}}
;
const LOAD = "d = import_json(\"machine.json\")\n";
const FILES = [_]support.ScriptFile{
    .{ .path = "machine.json", .data = MACHINE },
    .{ .path = "list.json", .data = "[{\"a\": 1}, 2]" },
    .{ .path = "n.json", .data = "42" },
    .{ .path = "u.json", .data = "{\"größe\": 2, \"big\": 123456789012345678901234567890}" },
    .{ .path = "many.json", .data = "{\"k1\": 1, \"k2\": 2, \"k3\": 3, \"k4\": 4, \"k5\": 5, \"k6\": 6, \"k7\": 7, \"k8\": 8, \"k9\": 9}" },
    .{ .path = "bad.json", .data = "{\"a\": 1,\n \"b\" 2}" },
    .{ .path = "dup.json", .data = "{\"a\": 1, \"a\": 2}" },
    .{ .path = "huge.json", .data = "{\"w\": [1, 1e400]}" },
    // As deep as it reads: limits_test.zig has the one level more it refuses
    .{ .path = "deep.json", .data = nested(limits.MAX_JSON_DEPTH) },
};

/// `levels` Arrays, each the only element of the one around it.
fn nested(comptime levels: usize) []const u8 {
    return repeat("[", levels) ++ repeat("]", levels);
}

fn repeat(comptime text: []const u8, comptime times: usize) []const u8 {
    @setEvalBranchQuota(10 * times);
    var out: []const u8 = "";
    for (0..times) |_| out = out ++ text;
    return out;
}

fn case(comptime src: []const u8, expected: support.Expected) support.ScriptCase {
    return .{ .src = src, .expected = expected, .files = &FILES };
}

fn failure(comptime src: []const u8, comptime message: []const u8) support.ScriptCase {
    return case(support.rescued(src), .{ .str = message });
}

test "import_json: an object's keys are found by String and by Symbol, all the way down" {
    try support.expectScripts(&.{
        case(LOAD ++ "r = d[\"count\"] == d[:count] && d[:count] == 12", .{ .boolean = true }),
        case(LOAD ++ "r = d[:gears][1][:teeth]", .{ .num = 20 }),
        case(LOAD ++ "r = \"#{d[:count].class} #{d[:name].class} #{d[:hollow].class} #{d[:note].class} #{d[:gears].class} #{d[:frame].class}\"", .{ .str = "Number String Boolean NilClass Array JsonObject" }),
        // A missing key is nil, as a Map's is; a Symbol no String was ever made of too
        case(LOAD ++ "r = d[:a_name_no_string_has] == nil && d[\"missing\"] == nil", .{ .boolean = true }),
        case("r = import_json(\"list.json\")[0][:a] + import_json(\"list.json\")[1] + import_json(\"n.json\")", .{ .num = 45 }),
        // A file that is a list: an Array, the objects in it JsonObjects
        case("l = import_json(\"list.json\")\nr = \"#{l.class} #{l[0].class} #{l[1].class}\"", .{ .str = "Array JsonObject Number" }),
        case("r = import_json(\"u.json\")[\"größe\"]", .{ .num = 2 }),
        case("r = import_json(\"u.json\")[:big]", .{ .num = 1.2345678901234568e29 }),
        // `import name from "file.json"` reads it the same way
        case("import m from \"./machine.json\"\nr = m[:frame][:w]", .{ .num = 40 }),
    });
}

test "JsonObject: prints, compares and iterates like a Map of its entries" {
    try support.expectScripts(&.{
        case(LOAD ++ "r = d[:frame].inspect", .{ .str = "{\"w\" => 40, \"h\" => 30}" }),
        case(LOAD ++ "r = d == import_json(\"machine.json\") && d[:frame] != d.to_h[\"frame\"]", .{ .boolean = true }),
        case(LOAD ++
            \\r = d.is_a?(JsonObject) && case d
            \\  when Map then false
            \\  when JsonObject then true
            \\end
        , .{ .boolean = true }),
        case(LOAD ++
            \\s = ""
            \\for k, v in d[:frame]
            \\  s += "#{k}=#{v};"
            \\end
            \\r = s
        , .{ .str = "w=40;h=30;" }),
        case(LOAD ++ "r = d.each { |k, v| break k }", .{ .str = "name" }),
        case(LOAD ++ "r = d[:frame].each { |k, v| k }.size", .{ .num = 2 }),
        case(LOAD ++ "r = d[:frame].keys.join(\",\") + \" \" + d[:frame].values.join(\",\")", .{ .str = "w,h 40,30" }),
        case(LOAD ++ "r = [d.size, d[:frame].length, d[:empty].size]", .{ .nums = &.{ 7, 2, 0 } }),
        case(LOAD ++ "r = d[:empty].empty? && !d.empty? && d.key?(:note) && d.key?(\"frame\") && !d.key?(:nope)", .{ .boolean = true }),
    });
}

test "JsonObject: fetch and dig find what [] does, or a default" {
    try support.expectScripts(&.{
        case(LOAD ++ "r = [d.fetch(:count), d.fetch(:nope, 5), d.fetch(\"count\", 5)]", .{ .nums = &.{ 12, 5, 12 } }),
        // A default of nil is a default; a key holding null holds nil
        case(LOAD ++ "r = d.fetch(:nope, nil)", .nil),
        case(LOAD ++ "r = d.fetch(:note, 1)", .nil),
        case(LOAD ++ "r = [d.dig(:gears, 0, :module), d.dig(\"gears\", -1, \"teeth\"), d.dig(:count)]", .{ .nums = &.{ 1.5, 20, 12 } }),
    });
}

test "JsonObject: to_h is a Map that can change, its Arrays and objects copies" {
    try support.expectScripts(&.{
        case(LOAD ++
            \\h = d.to_h
            \\h["count"] = 99
            \\h["frame"]["w"] = 1
            \\h["gears"].push(3)
            \\r = [d[:count], d[:frame][:w], d[:gears].size, h["count"], h["frame"]["w"]]
        , .{ .nums = &.{ 12, 40, 2, 99, 1 } }),
        case(LOAD ++ "r = \"#{d.to_h.class} #{d.to_h[\"gears\"][0].class}\"", .{ .str = "Map Map" }),
        // Its keys are the file's Strings: a Map doesn't find them by Symbol
        case(LOAD ++ "r = d.to_h.key?(\"count\") && d.to_h[:count] == nil", .{ .boolean = true }),
    });
}

test "import_json: every value it makes stays rooted while the rest is read" {
    try support.expectScripts(&.{.{
        .src = LOAD ++ "r = d.to_h[\"gears\"][1][\"teeth\"] + d.dig(:gears, 1, :teeth) + import_json(\"deep.json\").size",
        .expected = .{ .num = 41 },
        .files = &FILES,
        .gc_stress = true,
    }});
}

test "JsonObject: a missing key, index or entry names the place in the file" {
    try support.expectScripts(&.{
        failure(LOAD ++ "d.fetch(:nope)", "KeyError: machine.json has no key \"nope\" (its keys: name, count, hollow, note, gears, frame, empty)"),
        failure(LOAD ++ "d[:frame].fetch(:depth)", "KeyError: machine.json: frame has no key \"depth\" (its keys: w, h)"),
        failure(LOAD ++ "d[:empty].fetch(:x)", "KeyError: machine.json: empty has no key \"x\" (it has none)"),
        failure("import_json(\"many.json\").fetch(:x)", "KeyError: many.json has no key \"x\" (its keys: k1, k2, k3, k4, k5, k6, k7, k8, ...)"),
        failure(LOAD ++ "d.dig(:gears, 1, :pitch)", "KeyError: machine.json: gears[1] has no key \"pitch\" (its keys: module, teeth)"),
        failure(LOAD ++ "d[:gears][0].dig(:x)", "KeyError: machine.json: gears[0] has no key \"x\" (its keys: module, teeth)"),
        failure(LOAD ++ "d.dig(:gears, 5)", "IndexError: dig: machine.json: gears has no element 5 (size 2)"),
        failure(LOAD ++ "d.dig(:count, 0)", "TypeError: dig: machine.json: count is a Number value, not a JsonObject or an Array"),
        failure(LOAD ++ "d.dig(:gears, \"first\")", "TypeError: dig: machine.json: gears is an Array, indexed by an integer, got String"),
    });
}

test "JsonObject: is read-only, and its keys are Strings or Symbols" {
    try support.expectScripts(&.{
        failure(LOAD ++ "d[:count] = 1", "TypeError: a JsonObject is read-only; its to_h is a Map that can be changed"),
        failure(LOAD ++ "d[0]", "TypeError: a JsonObject's keys are Strings or Symbols, got Number"),
        failure(LOAD ++ "d.fetch(1)", "TypeError: a JsonObject's keys are Strings or Symbols, got Number"),
        failure(LOAD ++ "d.dig(nil)", "TypeError: a JsonObject's keys are Strings or Symbols, got nil"),
        failure(LOAD ++ "d.fetch(:a, 1, 2)", "ArgumentError: JsonObject#fetch takes at most 2 positional arguments (key, default), got 3"),
        failure(LOAD ++ "d.dig", "ArgumentError: JsonObject#dig expects at least 1 argument, got 0"),
        // An Array a script made hold itself has no end to copy
        failure(LOAD ++ "a = d[:gears]\na.push(a)\nd.to_h", "ValueError: to_h: the data nests deeper than 256 levels (an Array holding itself?)"),
    });
}

test "import_json: a file it can't read as data is an ImportError naming the file" {
    try support.expectScripts(&.{
        failure("import_json(\"nope.json\")", "ImportError: could not read JSON file 'nope.json': FileNotFound"),
        failure("import_json(\"bad.json\")", "ImportError: bad.json: line 2, column 6: invalid JSON"),
        failure("import_json(\"dup.json\")", "ImportError: dup.json: line 1, column 16: a key is written twice"),
        failure("import_json(\"huge.json\")", "ImportError: huge.json: w[1] is a number past the largest (1.8e308)"),
        failure("import_json(5)", "TypeError: import_json expects a String for argument 1, got Number"),
    });
}

test "import_json: the run notes the files it read, one it couldn't too, for a host that watches them" {
    var vm = try support.initVm();
    defer vm.deinit();
    var files = MemoryVfs.init(testing.allocator);
    defer files.deinit();
    try files.vfs().writeFile("machine.json", MACHINE);
    vm.vfs = files.vfs();
    try testing.expectEqual(.ok, try support.runOn(&vm,
        \\import_json("machine.json")
        \\import_json("machine.json")
        \\begin
        \\  import_json("later.json")
        \\rescue ImportError
        \\end
        \\begin
        \\  import_stl("part.stl")
        \\rescue ImportError
        \\end
    ));
    try testing.expectEqual(@as(u32, 3), vm.files_read.count());
    for ([_][]const u8{ "machine.json", "later.json", "part.stl" }) |path| try testing.expect(vm.files_read.contains(path));
    // The next run notes its own
    vm.resetRunOutput();
    try testing.expectEqual(@as(u32, 0), vm.files_read.count());
}
