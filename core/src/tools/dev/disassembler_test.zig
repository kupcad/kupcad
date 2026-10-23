const std = @import("std");
const testing = std.testing;
const chunk = @import("../../vm/chunk.zig");
const registry = @import("../../stdlib/registry.zig");
const Compiler = @import("../../compiler/compiler.zig").Compiler;
const Document = @import("../../frontend/document.zig").Document;
const VM = @import("../../vm/vm.zig").VM;
const disassembler = @import("disassembler.zig");

test "Disassembler: decodes inline-cache operands, 32-bit jumps, switch tables and for loops" {
    // Regression: every operand width (inline-cache index, 32-bit jump offset,
    // switch table) must be decoded or the listing drifts out of sync.
    const source =
        \\x = 1
        \\if x
        \\  x.foo
        \\end
        \\case x
        \\when 1 then 10
        \\when 2, 3 then 20
        \\else 30
        \\end
        \\for i in [1, 2]
        \\  x = i
        \\end
    ;
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    var vm = try VM.init(testing.allocator, testing.io);
    defer vm.deinit();
    try registry.registerStandardLibrary(&vm);
    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    try comp.compile(doc.tree.root);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try disassembler.disassembleChunk(testing.allocator, &out_chunk, "main", &out.writer);
    const text = out.written();
    try testing.expect(std.mem.find(u8, text, "| ic 0") != null);
    try testing.expect(std.mem.find(u8, text, "op_switch        3 cases") != null);
    try testing.expect(std.mem.find(u8, text, "op_for_next      slot:") != null);
    // Staying in sync means the final instruction is decoded as op_return
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, text, "\n"), "op_return"));

    // Every printed jump / switch target must land on an instruction boundary
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(testing.allocator);
    var targets: std.ArrayList(usize) = .empty;
    defer targets.deinit(testing.allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len > 4 and std.ascii.isDigit(line[0])) {
            try starts.append(testing.allocator, try std.fmt.parseInt(usize, line[0..4], 10));
        }
        if (std.mem.findLast(u8, line, "-> ")) |arrow| {
            try targets.append(testing.allocator, try std.fmt.parseInt(usize, line[arrow + 3 ..], 10));
        }
    }
    // At least the two `if` jumps plus the switch's three entries and default
    try testing.expect(targets.items.len >= 6);
    for (targets.items) |t| {
        try testing.expect(std.mem.findScalar(usize, starts.items, t) != null);
    }
}
