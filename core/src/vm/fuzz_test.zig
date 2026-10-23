//! Fuzzing the runtime: any input that parses and compiles runs on the VM without crashing,
//! leaking or failing with an error of the VM's own (a script's errors are its own business).
//! Each run is small and closed off: muted, with no files, an instruction and a memory
//! budget, and shapes built but never evaluated, so the time goes to the VM and the
//! built-ins, not to the kernel's C++, which the fuzzer can't see into. A plain test run
//! replays the corpus (frontend/fuzz_corpus.zig); `zig build fuzz --fuzz=<runs>` searches
//! from it along with the front end's fuzz test.

const std = @import("std");
const testing = std.testing;
const support = @import("../test_support.zig");
const corpus = @import("../frontend/fuzz_corpus.zig");
const program = @import("../frontend/fuzz_program.zig");
const Document = @import("../frontend/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const MemoryVfs = @import("../vfs/memory.zig").MemoryVfs;
const chunk = @import("chunk.zig");

/// Instructions a run may take: enough for the corpus programs, few enough that a loop the
/// fuzzer makes endless ends in milliseconds.
const RUN_INSTRUCTION_LIMIT = 50_000;
/// Script memory a run may hold (strings, arrays, maps): a doubling string ends here.
const RUN_MEMORY_LIMIT = 16 * 1024 * 1024;

/// Generated programs each plain test run runs.
const PLAIN_RUN_PROGRAMS = 100;

// The name is `-Dfuzz-target`'s filter in build.zig: renaming it means changing that.
test "fuzz: a script runs without crashing the VM" {
    const buf = try testing.allocator.create([corpus.MAX_INPUT_BYTES]u8);
    defer testing.allocator.destroy(buf);
    try testing.fuzz(buf, run, .{ .corpus = &corpus.CORPUS });
}

fn run(buf: *[corpus.MAX_INPUT_BYTES]u8, smith: *testing.Smith) anyerror!void {
    try runScript(buf[0..smith.slice(buf)]);
}

// The name is `-Dfuzz-target`'s filter in build.zig: renaming it means changing that.
test "fuzz: a generated program runs without crashing the VM" {
    try testing.fuzz({}, runGenerated, .{});
}

fn runGenerated(_: void, smith: *testing.Smith) anyerror!void {
    try runProgram(.{ .smith = smith });
}

fn runProgram(choices: program.Choices) !void {
    const source = try program.generate(testing.allocator, choices);
    defer testing.allocator.free(source);
    try runScript(source);
}

test "Fuzz programs: generated programs run on the VM" {
    // The programs the fuzzer would start from, on every test run.
    for (0..PLAIN_RUN_PROGRAMS) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        try runProgram(.{ .random = prng.random() });
    }
}

/// Runs `source`, if it compiles, on a VM closed off for it.
fn runScript(source: []const u8) !void {
    var doc = try Document.parse(testing.allocator, source);
    defer doc.deinit();
    if (doc.diagnostics.len > 0) return;

    var files = MemoryVfs.init(testing.allocator); // empty: an import or a file read fails
    defer files.deinit();
    var vm = try support.initVm();
    defer vm.deinit();
    vm.vfs = files.vfs();
    vm.evaluates_geometry = false;
    vm.hooks.setLimit(RUN_INSTRUCTION_LIMIT);
    vm.setMemoryLimit(RUN_MEMORY_LIMIT);

    var out_chunk = chunk.Chunk.init();
    defer out_chunk.free(testing.allocator);
    var comp = Compiler.forDocument(testing.allocator, &doc, &out_chunk, &vm);
    defer comp.deinit();
    // A script the compiler refuses is the front end's fuzz test's to judge.
    comp.compile(doc.tree.root) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };

    // Every outcome is the script's (a result, or an error it raised or ran into); what
    // this looks for is a crash, a failed assertion or a leak, which end the test.
    _ = vm.interpret(&out_chunk);
}
