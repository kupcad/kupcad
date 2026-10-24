//! `kupcad dev bench`: times a script's phases, parse, compile, VM run and the evaluation of
//! the geometry it builds, over several repetitions, and reports the medians (one cold run
//! with the profiler attached, which it used to be, measured the profiler as much as the
//! script, and never evaluated the DAG, so the kernel's share stayed invisible).

const std = @import("std");
const Document = @import("../frontend/document.zig").Document;
const Compiler = @import("../compiler/compiler.zig").Compiler;
const chunk = @import("../vm/chunk.zig");
const VM = @import("../vm/vm.zig").VM;
const registry = @import("../stdlib/registry.zig");
const profiler_mod = @import("../vm/profiler.zig");
const Stopwatch = @import("../core/stopwatch.zig").Stopwatch;

pub const Options = struct {
    /// Runs to time; the report gives each phase's median.
    repeat: usize = 5,
    /// Evaluate the geometry the script left (the kernel's work) as a phase of its own.
    evaluate: bool = true,
    /// Attach the tracing profiler to one extra run and include its table.
    profile: bool = true,
};

pub const Phase = enum { parse, compile, run, evaluate };

pub const Report = struct {
    /// Median nanoseconds per phase.
    median_ns: std.EnumArray(Phase, u64),
    repeat: usize,
    /// Whether the script left geometry to evaluate (else `evaluate` is 0).
    evaluated: bool,
    /// The profiler's function table, when asked for; owned.
    profile: ?[]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Report) void {
        if (self.profile) |p| self.allocator.free(p);
    }

    pub fn writeText(self: *const Report, w: *std.Io.Writer, file_path: []const u8) !void {
        try w.print("=== KupCAD Benchmark: {s} ({d} runs, medians) ===\n", .{ file_path, self.repeat });
        var total: u64 = 0;
        inline for (.{ .{ Phase.parse, "Parse" }, .{ Phase.compile, "Compile" }, .{ Phase.run, "VM run" }, .{ Phase.evaluate, "Evaluate" } }) |row| {
            const ns = self.median_ns.get(row[0]);
            total += ns;
            try w.print("{s:<9} {d:>9.3} ms\n", .{ row[1], ms(ns) });
        }
        try w.print("Total     {d:>9.3} ms\n", .{ms(total)});
        if (!self.evaluated) try w.writeAll("(the script left no geometry to evaluate)\n");
        if (self.profile) |p| {
            try w.writeAll("\n");
            try w.writeAll(p);
        }
    }

    pub fn writeJson(self: *const Report, w: *std.Io.Writer) !void {
        try std.json.Stringify.value(.{
            .repeat = self.repeat,
            .evaluated = self.evaluated,
            .median_ns = .{
                .parse = self.median_ns.get(.parse),
                .compile = self.median_ns.get(.compile),
                .run = self.median_ns.get(.run),
                .evaluate = self.median_ns.get(.evaluate),
            },
        }, .{ .whitespace = .indent_2 }, w);
        try w.writeAll("\n");
    }

    fn ms(ns: u64) f64 {
        return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
    }
};

/// Times `source` as `options` say. A script that doesn't parse, compile or run fails with
/// error.ParseError, error.CompileError or error.RuntimeError.
pub fn run(allocator: std.mem.Allocator, io: std.Io, source: []const u8, options: Options) !Report {
    const repeat = @max(options.repeat, 1);
    var samples = std.EnumArray(Phase, []u64).initUndefined();
    inline for (comptime std.enums.values(Phase)) |phase| samples.set(phase, try allocator.alloc(u64, repeat));
    defer inline for (comptime std.enums.values(Phase)) |phase| allocator.free(samples.get(phase));

    var evaluated = false;
    for (0..repeat) |i| {
        const timed = try timeOnce(allocator, io, source, options.evaluate, null);
        inline for (comptime std.enums.values(Phase)) |phase| samples.get(phase)[i] = timed.ns.get(phase);
        evaluated = timed.evaluated;
    }

    var report: Report = .{ .median_ns = .initFill(0), .repeat = repeat, .evaluated = evaluated, .profile = null, .allocator = allocator };
    inline for (comptime std.enums.values(Phase)) |phase| report.median_ns.set(phase, median(samples.get(phase)));

    if (options.profile) {
        var profile: std.Io.Writer.Allocating = .init(allocator);
        errdefer profile.deinit();
        _ = try timeOnce(allocator, io, source, false, &profile.writer);
        report.profile = try profile.toOwnedSlice();
    }
    return report;
}

const Timed = struct { ns: std.EnumArray(Phase, u64), evaluated: bool };

/// One cold run through every phase. With `profile_out`, the profiler is attached and its
/// table written there (that run's times aren't representative, so it is never sampled).
fn timeOnce(allocator: std.mem.Allocator, io: std.Io, source: []const u8, evaluate: bool, profile_out: ?*std.Io.Writer) !Timed {
    var ns = std.EnumArray(Phase, u64).initFill(0);
    var clock = Stopwatch.start(io);

    var doc = try Document.parse(allocator, source);
    defer doc.deinit();
    if (doc.diagnostics.len > 0) return error.ParseError;
    ns.set(.parse, clock.lap());

    var vm = try VM.init(allocator, io);
    defer vm.deinit();
    vm.mute_errors = true;
    vm.line_index = &doc.line_index;
    defer vm.line_index = null;
    try registry.registerStandardLibrary(&vm);
    // The script's own output (puts, print, inspect, benchmark) went into the report,
    // once per run; the timings don't depend on it being shown.
    vm.host.print_handler = null;
    var program = chunk.Chunk.init();
    defer program.free(allocator);
    var compiler = Compiler.forDocument(allocator, &doc, &program, &vm);
    defer compiler.deinit();
    compiler.compile(doc.tree.root) catch return error.CompileError;
    ns.set(.compile, clock.lap());

    var profiler = profiler_mod.Profiler.init(allocator, io);
    defer profiler.deinit();
    if (profile_out != null) vm.profiler = &profiler;
    if (vm.interpret(&program) != .ok) return error.RuntimeError;
    ns.set(.run, clock.lap());
    if (profile_out) |w| try profiler.dumpProfile(w);

    var evaluated = false;
    if (evaluate and vm.finalValue().isGeometry()) {
        _ = try vm.ensureConcrete(vm.finalValue());
        evaluated = true;
        ns.set(.evaluate, clock.lap());
    }
    return .{ .ns = ns, .evaluated = evaluated };
}

fn median(values: []u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}
