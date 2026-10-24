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
