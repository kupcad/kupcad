//! Built-ins for checking and timing a script: `assert` (`nativeAssert`) raises an
//! AssertionError, or the given class, through the VM's rescue machinery, and so do
//! `assert_equal` and `assert_near`, naming what they compared; `warn` prints a warning
//! through the host; `benchmark` times its block; `debugger` pauses in the host's debugger
//! (cli/debugger.zig in a terminal). The natives a `test("name") do ... end` block compiles
//! to under `kupcad test` (`nativeTestBegin`, `nativeTestPass`, `nativeTestFail`) keep each
//! test's outcome in the run's report.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("../vm/vm.zig").VM;
const arguments = @import("arguments.zig");
const Text = @import("../vm/text.zig").Text;

/// What `warn` prints before its parts.
const WARNING_PREFIX = "[Warning] ";

/// assert(condition, message = "Assertion failed.", error_class = AssertionError) { message }
/// -> raises when the condition is false or nil; the block, if given, builds the message
/// lazily (only for a failure).
pub fn nativeAssert(vm: *VM, condition: value.Value, message: ?value.Value, error_class: ?*value.ObjClass, block: ?*value.ObjClosure) anyerror!value.Value {
    if (!condition.isFalsey()) return value.Value.initNil();

    const msg_val = if (block) |closure|
        try requireMessage(vm, try vm.callClosureSync(closure, &.{}), "its block to return a String message")
    else if (message) |m|
        try requireMessage(vm, m, "a String for its message")
    else
        try vm.allocateString("Assertion failed.");
    return raiseAssertion(vm, error_class, msg_val);
}

/// Raises `message` as an instance of `error_class` (AssertionError without one) into the
/// VM's rescue system: a rescue that caught it takes over from here.
fn raiseAssertion(vm: *VM, error_class: ?*value.ObjClass, message: value.Value) anyerror!value.Value {
    const err_class = error_class orelse vm.error_classes.get(.AssertionError) orelse {
        return vm.fail(.RuntimeError, "AssertionError class not found", .{});
    };
    return switch (try vm.throwError(err_class, message)) {
        .ok => error.Unwind,
        else => error.FatalError,
    };
}

/// assert_equal(actual, expected, message = nil) -> raises an AssertionError naming both
/// values when they differ, as `==` tells (`expected 3, got 4`; the message, if given,
/// before them).
pub fn nativeAssertEqual(vm: *VM, actual: value.Value, expected: value.Value, message: ?value.Value) anyerror!value.Value {
    if (vm.valuesEqual(actual, expected)) return value.Value.initNil();
    var out = try startComparison(vm, message, "assert_equal");
    defer out.deinit();
    try out.writeAll("expected ");
    try out.inspect(expected);
    try out.writeAll(", got ");
    try out.inspect(actual);
    return raiseAssertion(vm, null, try out.toString());
}

/// assert_near(actual, expected, message = nil, tolerance: the active tolerance) -> raises
/// an AssertionError when two numbers differ by more than `tolerance` (`expected 10 within
/// 0.00001, got 10.5`): a measure of a mesh (a volume, a bounding box) is never exact.
pub fn nativeAssertNear(vm: *VM, args: []const value.Value) anyerror!value.Value {
    const parsed = try arguments.parseKwargs(struct { tolerance: ?f64 = null }, vm, args, "assert_near");
    if (parsed.positional.len < 2 or parsed.positional.len > 3) {
        return vm.fail(.ArgumentError, "assert_near expects 2 to 3 arguments, got {d}", .{parsed.positional.len});
    }
    const message: ?value.Value = if (parsed.positional.len == 3) parsed.positional[2] else null;
    const tolerance = parsed.opts.tolerance orelse vm.config().tolerance;
    if (!(tolerance >= 0)) return vm.fail(.ValueError, "assert_near tolerance must be zero or more, got {d}", .{tolerance});
    // Two Arrays of numbers compare item by item: a point, a bounding box's size
    if (parsed.positional[0].isArray() and parsed.positional[1].isArray()) {
        const actuals = parsed.positional[0].asArray().items.items;
        const expecteds = parsed.positional[1].asArray().items.items;
        var near = actuals.len == expecteds.len;
        if (near) for (actuals, expecteds) |a, e| {
            if (!a.isNumber() or !e.isNumber()) return vm.fail(.TypeError, "assert_near compares Arrays of numbers, got {s} and {s} in them", .{ vm.typeName(a), vm.typeName(e) });
            if (!isNear(a.asNumber(), e.asNumber(), tolerance)) near = false;
        };
        if (near) return value.Value.initNil();
        var out = try startComparison(vm, message, "assert_near");
        defer out.deinit();
        try out.writeAll("expected ");
        try out.inspect(parsed.positional[1]);
        try out.writeAll(" within ");
        try out.display(value.Value.initNumber(tolerance));
        try out.writeAll(", got ");
        try out.inspect(parsed.positional[0]);
        return raiseAssertion(vm, null, try out.toString());
    }
    const actual = try arguments.requireNumber(vm, parsed.positional[0], "assert_near", "actual");
    const expected = try arguments.requireNumber(vm, parsed.positional[1], "assert_near", "expected");
    if (isNear(actual, expected, tolerance)) return value.Value.initNil();
    var out = try startComparison(vm, message, "assert_near");
    defer out.deinit();
    try out.writeAll("expected ");
    try out.display(parsed.positional[1]);
    try out.writeAll(" within ");
    try out.display(value.Value.initNumber(tolerance));
    try out.writeAll(", got ");
    try out.display(parsed.positional[0]);
    return raiseAssertion(vm, null, try out.toString());
}

fn isNear(actual: f64, expected: f64, tolerance: f64) bool {
    return actual == expected or @abs(actual - expected) <= tolerance;
}

/// `assert_raises(ErrorClass = StandardError, message = nil) do ... end`, which the
/// compiler desugars (compiler/compiler.zig's compileAssertRaises) into a `begin ... rescue`
/// that hands what was raised, or nil, to this native: an AssertionError when nothing was
/// raised, when it isn't of the class, or when its message isn't `message`; else the
/// error, the expression's value.
pub fn nativeAssertRaised(vm: *VM, raised: value.Value, class: value.Value, message: value.Value) anyerror!value.Value {
    var expected_class: ?*value.ObjClass = null;
    if (!class.isNil()) {
        if (!class.isClass()) return vm.fail(.TypeError, "assert_raises expects an error class, got {s}", .{vm.typeName(class)});
        const exception = vm.classes.get(.exception);
        if (exception != null and !VM.isSubclassOf(class.asClass(), exception.?)) return vm.fail(.TypeError, "assert_raises expects an error class, got {s}", .{class.asClass().name.chars});
        expected_class = class.asClass();
    }
    if (!message.isNil() and !message.isString()) return vm.fail(.TypeError, "assert_raises expects a String for the message, got {s}", .{vm.typeName(message)});
    const class_name = if (expected_class) |c| c.name.chars else "an error";
    var out: Text = .init(vm);
    defer out.deinit();
    if (raised.isNil()) {
        try out.writeAll("expected ");
        try out.writeAll(class_name);
        try out.writeAll(" to be raised, nothing was");
        return raiseAssertion(vm, null, try out.toString());
    }
    if (!raised.isInstance()) return raiseAssertion(vm, null, try vm.allocateString("expected an error to be raised, got something else"));
    const inst = raised.asInstance();
    if (expected_class) |c| if (!VM.isSubclassOf(inst.class, c)) {
        try out.writeAll("expected ");
        try out.writeAll(class_name);
        try out.writeAll(" to be raised, got ");
        try out.writeAll(inst.class.name.chars);
        if (try vm.errorField(inst, "message")) |m| {
            try out.writeAll(": ");
            try out.display(m);
        }
        return raiseAssertion(vm, null, try out.toString());
    };
    if (message.isString()) {
        const got = try vm.errorField(inst, "message") orelse value.Value.initNil();
        if (!got.isString() or !std.mem.eql(u8, got.asString().chars, message.asString().chars)) {
            try out.writeAll("expected the message ");
            try out.inspect(message);
            try out.writeAll(", got ");
            try out.inspect(got);
            return raiseAssertion(vm, null, try out.toString());
        }
    }
    return raised;
}

/// A failed comparison's message, begun with the script's own `message` (a String, else a
/// TypeError) and ": " when one was given.
fn startComparison(vm: *VM, message: ?value.Value, comptime method: []const u8) !Text {
    var out: Text = .init(vm);
    errdefer out.deinit();
    if (message) |m| {
        if (!m.isString()) return vm.fail(.TypeError, method ++ " expects a String for its message, got {s}", .{vm.typeName(m)});
        try out.writeAll(m.asString().chars);
        try out.writeAll(": ");
    }
    return out;
}

// --- Test blocks (`test("name") do ... end`, compiled by compiler/compiler.zig) ---

/// Starts the test `name`: whether it runs, which it doesn't when `VM.test_filter` names
/// text its name lacks (`kupcad test --filter`), reported as skipped; one that runs is in
/// the report from here.
pub fn nativeTestBegin(vm: *VM, name: *value.ObjString) anyerror!value.Value {
    if (vm.test_filter) |filter| {
        if (std.mem.find(u8, name.chars, filter) == null) {
            try vm.report.skipTest(vm.allocator, name.chars);
            return value.Value.initBool(false);
        }
    }
    try vm.report.beginTest(vm.allocator, name.chars);
    return value.Value.initBool(true);
}

/// Ends the running test: its body ran through.
pub fn nativeTestPass(vm: *VM) anyerror!value.Value {
    try vm.report.endTest(vm.allocator, null, null);
    return value.Value.initNil();
}

/// Ends the running test with the error `err` that left its body: as an uncaught error is
/// reported (`AssertionError: expected 3, got 4`, then the backtrace's lines).
pub fn nativeTestFail(vm: *VM, err: value.Value) anyerror!value.Value {
    var out: Text = .init(vm);
    defer out.deinit();
    if (err.isInstance()) {
        const inst = err.asInstance();
        try out.writeAll(inst.class.name.chars);
        try out.writeAll(": ");
        if (try vm.errorField(inst, "message")) |message| try out.display(message);
        if (try vm.errorField(inst, "backtrace")) |backtrace| {
            if (backtrace.isArray()) for (backtrace.asArray().items.items) |line| {
                try out.writeAll("\n");
                try out.display(line);
            };
        }
    } else {
        try out.inspect(err);
    }
    try vm.report.endTest(vm.allocator, out.written(), vm.last_throw_place);
    return value.Value.initNil();
}

fn requireMessage(vm: *VM, msg: value.Value, comptime expected: []const u8) !value.Value {
    if (msg.isString()) return msg;
    return vm.fail(.TypeError, "assert expects " ++ expected ++ ", got {s}", .{vm.typeName(msg)});
}

/// `warn(*parts)`: prints `[Warning] ` and the parts, as `puts` would, and keeps them as a
/// warning of the run where it is called, which an editor shows on that line and the
/// preview beside the model. It was printed only.
pub fn nativeWarn(vm: *VM, args: []const value.Value) anyerror!value.Value {
    var out: Text = .init(vm);
    defer out.deinit();
    try out.writeAll(WARNING_PREFIX);
    for (args) |arg| try out.stringify(arg, false);
    try out.writeAll("\n");
    if (vm.host.print_handler) |print_handler| print_handler(vm, out.written());
    // The report keeps the parts alone, in a copy of its own
    const message = out.written();
    vm.keepWarning(try vm.allocator.dupe(u8, message[WARNING_PREFIX.len .. message.len - 1]));
    return value.Value.initNil();
}

/// benchmark(label = "Execution") { ... } -> runs the block, prints how long it took and
/// returns its result
pub fn nativeBenchmark(vm: *VM, label_str: ?*value.ObjString, block: *value.ObjClosure) anyerror!value.Value {
    const label = if (label_str) |l| l.chars else "Execution";

    // Start Timer using the VM's IO capability
    const start_time = std.Io.Clock.now(.awake, vm.io);

    const result = try vm.callClosureSync(block, &.{});

    // Stop Timer
    const end_time = std.Io.Clock.now(.awake, vm.io);

    // Calculate safe duration
    const duration_ns = start_time.durationTo(end_time).toNanoseconds();
    const elapsed_ns: u64 = @intCast(@max(0, duration_ns));
    const duration_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    if (vm.host.print_handler) |print_handler| {
        if (vm.fmtScratch("[Benchmark] {s}: {d:.3} ms\n", .{ label, duration_ms })) |msg| {
            print_handler(vm, msg);
        } else |_| {}
    }

    return result;
}

/// `debugger`: opens the host's debugger (`VM.debugger_handler`) on the paused frame and
/// steps with it from there; nothing without one.
pub fn nativeDebugger(vm: *VM) !value.Value {
    const open = vm.debugger_handler orelse return value.Value.initNil();
    vm.debugger_step_handler = open;
    vm.openDebugger(open);
    return value.Value.initNil();
}
