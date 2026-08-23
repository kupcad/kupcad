const std = @import("std");
const testing = std.testing;
const chunk = @import("chunk.zig");
const registry = @import("../stdlib/registry.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const Document = @import("../core/document.zig").Document;
const VM = @import("vm.zig").VM;

/// Helper function that compiles a script and ASSERTS that it fails with a runtime error.
fn expectRuntimeError(source: []const u8) !void {
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();

    vm.mute_errors = true;
    try registry.registerStandardLibrary(&vm);

    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);

    var comp = Compiler.init(testing.allocator, &doc.tree, doc.symbols, doc.tokens.starts, &out_chunk, &vm);
    defer comp.deinit();

    // We expect it to compile fine
    try comp.compile(doc.tree.root);

    // But we expect it to fail gracefully during execution
    const result = vm.interpret(&out_chunk);
    try testing.expectEqual(.runtime_error, result);
}

test "VM Validation: Cube catches negative and zero dimensions" {
    try expectRuntimeError("cube(-10)");
    try expectRuntimeError("cube(x: 10, y: -5)");
    try expectRuntimeError("cube(0)");
}

test "VM Validation: Cylinder catches invalid radius and height" {
    try expectRuntimeError("cylinder(r: -5, h: 10)");
    try expectRuntimeError("cylinder(r: 5, h: 0)");
}

test "VM Validation: Sphere catches negative radius" {
    try expectRuntimeError("sphere(-1)");
    try expectRuntimeError("sphere(0)");
}

test "VM Validation: Square catches negative and zero dimensions" {
    try expectRuntimeError("square(-5)");
    try expectRuntimeError("square(x: 10, y: 0)");
}

test "VM Validation: Circle catches negative radius and negative segments" {
    try expectRuntimeError("circle(d: -10)");
    try expectRuntimeError("circle(r: 10, segments: -1)");
}

test "VM Validation: Text catches invalid size and tolerance" {
    try expectRuntimeError("text(\"test\", size: 0)");
    try expectRuntimeError("text(\"test\", size: -5)");
    try expectRuntimeError("text(\"test\", tolerance: -0.1)");
}
