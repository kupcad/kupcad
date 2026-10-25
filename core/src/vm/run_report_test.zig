const std = @import("std");
const testing = std.testing;
const run_report = @import("run_report.zig");
const RunReport = run_report.RunReport;
const VM = @import("vm.zig").VM;
const support = @import("../test_support.zig");
const Document = @import("../frontend/document.zig").Document;
const chunk = @import("chunk.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;

/// Runs `source` on `vm` as a host does, its positions known (the VM has the line index).
fn run(vm: *VM, source: []const u8) !@import("vm.zig").InterpretResult {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var program = chunk.Chunk.init();
    defer program.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &program, vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);
    vm.line_index = &doc.line_index;
    defer vm.line_index = null;
    return vm.interpret(&program);
}

test "run report: warnings past the most kept are freed, and a refusal replaces the last" {
    var report: RunReport = .{};
    defer report.deinit(testing.allocator);
    for (0..run_report.MAX_WARNINGS + 5) |i| {
        try report.addWarning(testing.allocator, try std.fmt.allocPrint(testing.allocator, "warning {d}", .{i}), .{ .line = 1, .column = 1 });
    }
    try testing.expectEqual(@as(usize, run_report.MAX_WARNINGS), report.warnings.items.len);
    try testing.expectEqualStrings("warning 0", report.warnings.items[0].message);
    try report.refuse(testing.allocator, "width");
    try report.refuse(testing.allocator, "depth");
    try testing.expectEqualStrings("depth", report.refused_param.?);
    report.clear(testing.allocator);
    try testing.expectEqual(@as(usize, 0), report.warnings.items.len);
    try testing.expect(report.refused_param == null);
}

test "run report: a warning is kept once a run, wherever it is given again" {
    var report: RunReport = .{};
    defer report.deinit(testing.allocator);
    try report.addWarning(testing.allocator, try testing.allocator.dupe(u8, "mended 'a.stl'"), .{ .line = 2, .column = 1 });
    try report.addWarning(testing.allocator, try testing.allocator.dupe(u8, "mended 'a.stl'"), .{ .line = 7, .column = 1 });
    try report.addWarning(testing.allocator, try testing.allocator.dupe(u8, "mended 'b.stl'"), .{ .line = 7, .column = 1 });
    try testing.expectEqual(@as(usize, 2), report.warnings.items.len);
    try testing.expectEqual(@as(u32, 2), report.warnings.items[0].position.?.line);
}

test "run report: a warning is kept at the line the script was at" {
    const expected = support.expectWarnings();
    defer expected.restore();
    var vm = try support.initVm();
    defer vm.deinit();
    var files = MemoryVfs.init(testing.allocator);
    defer files.deinit();
    // A cube's triangles but its top's: mended on import, with a warning
    const open_box = comptime "solid b\n" ++ facet("0 0 0", "0 1 0", "1 1 0") ++ facet("0 0 0", "1 1 0", "1 0 0") ++
        facet("0 0 0", "1 0 0", "1 0 1") ++ facet("0 0 0", "1 0 1", "0 0 1") ++ facet("1 1 0", "0 1 0", "0 1 1") ++
        facet("1 1 0", "0 1 1", "1 1 1") ++ facet("0 1 0", "0 0 0", "0 0 1") ++ facet("0 1 0", "0 0 1", "0 1 1") ++
        facet("1 0 0", "1 1 0", "1 1 1") ++ facet("1 0 0", "1 1 1", "1 0 1") ++ "endsolid b\n";
    try files.vfs().writeFile("open.stl", open_box);
    vm.vfs = files.vfs();
    try testing.expectEqual(.ok, try run(&vm, "x = 1\nbox = import_stl(\"open.stl\")\n"));
    try testing.expectEqual(@as(usize, 1), vm.report.warnings.items.len);
    const warning = vm.report.warnings.items[0];
    try testing.expect(std.mem.find(u8, warning.message, "mended the mesh of 'open.stl'") != null);
    try testing.expectEqual(@as(u32, 2), warning.position.?.line);
}

fn facet(comptime a: []const u8, comptime b: []const u8, comptime c: []const u8) []const u8 {
    return "facet normal 0 0 0\nouter loop\nvertex " ++ a ++ "\nvertex " ++ b ++ "\nvertex " ++ c ++ "\nendloop\nendfacet\n";
}

test "run report: a refused parameter is named, and the error kept where it was raised" {
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.runtime_error, try run(&vm, "a = 1\nw = param(:width, default: 5, validate: { min: 10 })\n"));
    try testing.expectEqualStrings("width", vm.report.refused_param.?);
    try testing.expectEqual(@as(u32, 2), vm.last_error_position.?.line);
    try testing.expect(std.mem.startsWith(u8, vm.last_error.?, "ValueError: parameter :width value 5"));

    // An error the script raises itself, uncaught, is placed too; no parameter is named
    vm.resetRunOutput();
    try testing.expectEqual(.runtime_error, try run(&vm, "a = 1\nb = 2\nraise \"boom\"\n"));
    try testing.expectEqual(@as(u32, 3), vm.last_error_position.?.line);
    try testing.expect(vm.report.refused_param == null);
}

test "run report: a run's parameters are its own, after the output is reset" {
    var vm = try support.initVm();
    defer vm.deinit();
    try testing.expectEqual(.ok, try run(&vm, "w = param(:width, default: 5)\n"));
    try testing.expectEqual(@as(usize, 1), vm.param_registry.len);
    // The next module of a session: reading :width without declaring it is an error, as in
    // a run of its own (it read the module before's)
    vm.resetRunOutput();
    try testing.expectEqual(@as(usize, 0), vm.param_registry.len);
    try testing.expectEqual(.runtime_error, try run(&vm, "w = param(:width)\n"));
    try testing.expect(std.mem.startsWith(u8, vm.last_error.?, "NameError: parameter :width is used before it is defined"));
}

/// The modules the script imports, by path.
const MODULES = [_]struct { path: []const u8, source: []const u8 }{
    // Its function warns of what it is given: the script's call is where
    .{ .path = "tint.kup", .source = "def tinted(s)\n  s.material(color: \"#3333cc\")\nend\nexport tinted\n" },
    // It warns as it runs: the script's import is where
    .{ .path = "shaded.kup", .source = "CAD.config(engine: :brep)\nshade = cube(1).material(color: \"#cc3333\")\nexport shade\n" },
    .{ .path = "boom.kup", .source = "def boom\n  raise \"boom\"\nend\nexport boom\n" },
};

/// A VM whose file system has MODULES.
fn importingVm(files: *MemoryVfs) !VM {
    var vm = try support.initVm();
    errdefer vm.deinit();
    for (MODULES) |module| try files.vfs().writeFile(module.path, module.source);
    vm.vfs = files.vfs();
    return vm;
}

test "run report: what an imported module's function warns of is placed at the script's call of it" {
    var files = MemoryVfs.init(testing.allocator);
    defer files.deinit();
    var vm = try importingVm(&files);
    defer vm.deinit();
    // The module's offset of its warning is on the script's line 1: it was placed there
    try testing.expectEqual(.ok, try run(&vm, "CAD.config(engine: :brep)\nimport { tinted } from \"./tint.kup\"\nx = 1\ny = 2\npart = tinted(cube(1))\n"));
    try testing.expectEqual(@as(usize, 1), vm.report.warnings.items.len);
    try testing.expectEqual(@as(u32, 5), vm.report.warnings.items[0].position.?.line);
}

test "run report: what a module warns of as it runs is placed at its import, and given again by an import from the cache, once" {
    var files = MemoryVfs.init(testing.allocator);
    defer files.deinit();
    var vm = try importingVm(&files);
    defer vm.deinit();
    const script = "x = 1\nimport { shade } from \"./shaded.kup\"\nimport \"./shaded.kup\"\n";
    try testing.expectEqual(.ok, try run(&vm, script));
    try testing.expectEqual(@as(usize, 1), vm.report.warnings.items.len);
    try testing.expect(std.mem.find(u8, vm.report.warnings.items[0].message, "brep") != null);
    try testing.expectEqual(@as(u32, 2), vm.report.warnings.items[0].position.?.line);

    // The session's next run: the module comes from the cache, and doesn't run
    vm.resetRunOutput();
    try testing.expectEqual(.ok, try run(&vm, script));
    try testing.expectEqual(@as(usize, 1), vm.report.warnings.items.len);
    try testing.expectEqual(@as(u32, 2), vm.report.warnings.items[0].position.?.line);
}

test "run report: an error raised in an imported module's code is placed at the script's call, its backtrace naming the module" {
    var files = MemoryVfs.init(testing.allocator);
    defer files.deinit();
    var vm = try importingVm(&files);
    defer vm.deinit();
    try testing.expectEqual(.ok, try run(&vm, "import { boom } from \"./boom.kup\"\ntrace = begin\n  boom\nrescue => e\n  e.backtrace\nend\n"));
    const trace = (vm.globals.get("trace") orelse return error.MissingGlobal).asArray().items.items;
    try testing.expectEqualStrings("    from boom.kup:in 'boom'", trace[0].asString().chars);
    try testing.expect(std.mem.startsWith(u8, trace[1].asString().chars, "    from script:3:"));

    var uncaught = try importingVm(&files);
    defer uncaught.deinit();
    try testing.expectEqual(.runtime_error, try run(&uncaught, "import { boom } from \"./boom.kup\"\nx = 1\nboom\n"));
    try testing.expectEqual(@as(u32, 3), uncaught.last_error_position.?.line);
}

test "run report: a warning or an error in a call is placed at the call, not at its last argument" {
    var vm = try support.initVm();
    defer vm.deinit();
    // It was column 23, the colour's
    try testing.expectEqual(.ok, try run(&vm, "CAD.config(engine: :brep)\npart = cube(1)\npart.material(color: \"#cc3333\")\n"));
    try testing.expectEqual(run_report.LinePosition{ .line = 3, .column = 1 }, vm.report.warnings.items[0].position.?);
    vm.resetRunOutput();
    try testing.expectEqual(.runtime_error, try run(&vm, "x = 1\ny = cube(\"a\")\n"));
    try testing.expectEqual(run_report.LinePosition{ .line = 2, .column = 5 }, vm.last_error_position.?);
}

test "run report: a refused value whose error was rescued names no parameter" {
    var vm = try support.initVm();
    defer vm.deinit();
    const refused_then_rescued = "w = begin\n  param(:width, default: 5, validate: { min: 10 })\nrescue\n  10\nend\n";
    try testing.expectEqual(.ok, try run(&vm, refused_then_rescued));
    try testing.expect(vm.report.refused_param == null);
    // A later error isn't the refusal's
    vm.resetRunOutput();
    try testing.expectEqual(.runtime_error, try run(&vm, refused_then_rescued ++ "raise \"boom\"\n"));
    try testing.expect(vm.report.refused_param == null);
}

test "run report: what a run printed is kept up to the most it keeps, cut between characters" {
    var report: RunReport = .{};
    defer report.deinit(testing.allocator);
    try report.addOutput(testing.allocator, "a\n");
    try testing.expectEqualStrings("a\n", report.output.items);
    // Up to one byte short of the most, then a character of two bytes: it doesn't fit, whole
    const filler = try testing.allocator.alloc(u8, run_report.MAX_OUTPUT_BYTES - report.output.items.len - 1);
    defer testing.allocator.free(filler);
    @memset(filler, 'x');
    try report.addOutput(testing.allocator, filler);
    try testing.expect(!report.output_cut);
    try report.addOutput(testing.allocator, "é");
    try testing.expect(report.output_cut);
    try testing.expectEqual(run_report.MAX_OUTPUT_BYTES - 1, report.output.items.len);
    try testing.expect(std.unicode.utf8ValidateSlice(report.output.items));
    // A run's report starts empty
    report.clear(testing.allocator);
    try testing.expectEqual(@as(usize, 0), report.output.items.len);
    try testing.expect(!report.output_cut);
}

test "run report: a preview's run keeps what it prints, any other run writes it out" {
    var shown = try VM.init(testing.allocator, testing.io);
    defer shown.deinit();
    shown.previewing = true;
    try @import("../stdlib/registry.zig").registerStandardLibrary(&shown);
    try testing.expectEqual(.ok, try run(&shown, "puts 1 + 1"));
    try testing.expectEqualStrings("2\n", shown.report.output.items);

    var built = try support.initVm();
    defer built.deinit();
    try testing.expectEqual(.ok, try run(&built, "puts 1 + 1"));
    try testing.expectEqualStrings("", built.report.output.items);
}
