const std = @import("std");
const testing = std.testing;
const diagnostics = @import("diagnostics.zig");
const Diagnostics = diagnostics.Diagnostics;
const Options = diagnostics.Options;
const Limits = diagnostics.Limits;
const input = diagnostics.input;
const Tolerance = @import("tolerance.zig").Tolerance;
const Parallel = @import("parallel.zig").Parallel;

test "Diagnostics: findings in order, failures and warnings counted, the first failure named" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectEqual(@as(?diagnostics.Finding, null), diag.first());
    try diag.warn(.{ .code = .limit_exceeded, .label = "steps", .measured = 500, .threshold = 500 });
    const err = diag.fail(error.NotValid, .{ .code = .not_positive, .entity = .of(.face, 3), .measured = -1 });
    try testing.expectEqual(error.NotValid, err);
    try testing.expectEqual(@as(usize, 1), diag.failures());
    try testing.expectEqual(@as(usize, 1), diag.warnings());
    try testing.expectEqual(diagnostics.Code.not_positive, diag.first().?.code);
    try testing.expectEqual(@as(u32, 3), diag.first().?.entity.index);

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try diag.format(&w);
    try testing.expectEqualStrings(
        \\warning: steps went past a limit: 500 against 500
        \\face must be positive (face 3): -1 against 0
        \\
    , w.buffered());
    diag.clear();
    try testing.expectEqual(@as(usize, 0), diag.findings.items.len);
}

test "Diagnostics: a finding that can't be recorded is out of memory, and nothing leaks" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var diag = Diagnostics.init(failing.allocator());
    defer diag.deinit();
    try testing.expectError(error.OutOfMemory, diag.add(.{ .code = .empty_input }));
    try testing.expectEqual(error.OutOfMemory, diag.fail(error.NotValid, .{ .code = .empty_input }));
}

test "Options: the cancel flag is honoured only when set; the parallel defaults to serial" {
    var flag = std.atomic.Value(bool).init(false);
    const options: Options = .{ .cancel = &flag };
    try options.checkCancel();
    flag.store(true, .release);
    try testing.expectError(error.Canceled, options.checkCancel());
    const none: Options = .{};
    try none.checkCancel();
    try testing.expectEqual(@as(usize, 1), none.parallelOrSerial().threads());
    try testing.expectEqual(@as(?Tolerance, null), none.tolerance);
    try testing.expect(none.trace == null);
}

test "Limits: the defaults of the plan, and zero is not a limit" {
    const limits: Limits = .{};
    try testing.expectEqual(@as(u32, 50), limits.newton_trials);
    try testing.expectEqual(@as(u32, 500), limits.marching_steps);
    try testing.expectEqual(@as(u32, 64), limits.subdivision_depth);
    try testing.expectEqual(@as(u32, 4096), limits.fit_points);
    try testing.expectEqual(@as(u32, 1 << 20), limits.faces_per_body);
    try testing.expectEqual(@as(u32, 1 << 31), limits.entities_per_arena);
    try testing.expect(limits.isValid());
    try testing.expect(!(Limits{ .newton_trials = 0 }).isValid());
}

test "input: the checks at the boundary name the argument and the value" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try input.finite(&diag, "radius", 5);
    try testing.expectError(error.InvalidInput, input.finite(&diag, "radius", std.math.nan(f64)));
    try testing.expectError(error.InvalidInput, input.finite(&diag, "radius", std.math.inf(f64)));
    try testing.expectError(error.InvalidInput, input.positive(&diag, "radius", 0));
    try testing.expectError(error.InvalidInput, input.positive(&diag, "radius", -2));
    try input.positive(&diag, "radius", 1e-300);
    try input.range(&diag, "t", 0, 1);
    try testing.expectError(error.InvalidInput, input.range(&diag, "t", 1, 1));
    try testing.expectError(error.InvalidInput, input.range(&diag, "t", 2, 1));
    try testing.expectError(error.InvalidInput, input.range(&diag, "t", 0, std.math.nan(f64)));
    try input.nonEmpty(&diag, "points", 3);
    try testing.expectError(error.InvalidInput, input.nonEmpty(&diag, "points", 0));
    try input.tolerance(&diag, Tolerance.fromZone(1e-5));
    try testing.expectError(error.InvalidInput, input.tolerance(&diag, Tolerance.fromZone(0)));
    try input.scale(&diag, 1000, Tolerance.fromZone(1e-5));
    try testing.expectError(error.InvalidInput, input.scale(&diag, 1e9, Tolerance.fromZone(1e-5)));
    try testing.expectEqual(@as(usize, 10), diag.failures());
    try testing.expectEqualStrings("radius", diag.first().?.label);
    try testing.expectEqual(diagnostics.Code.not_finite, diag.first().?.code);
    const last = diag.findings.items[diag.findings.items.len - 1];
    try testing.expectEqual(diagnostics.Code.too_large_for_tolerance, last.code);
    try testing.expectEqual(@as(f64, 1e9), last.measured);
    try testing.expectApproxEqRel(@as(f64, 1e7), last.threshold, 1e-9);
}

test "limitExceeded and notImplemented: the errors with their findings" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectEqual(error.LimitExceeded, diagnostics.limitExceeded(&diag, "marching steps", 500, 500));
    try testing.expectEqual(error.NotImplemented, diagnostics.notImplemented(&diag, "fillets", 7));
    try testing.expectEqual(@as(f64, 7), diag.findings.items[1].threshold);
}

/// Whether every public function of `Namespace` takes a `*Diagnostics` (README rule 9): the
/// operations' namespaces are checked so in root.zig's tests as they are written.
pub fn everyFunctionTakesDiagnostics(comptime Namespace: type) bool {
    inline for (comptime std.meta.declarations(Namespace)) |name| {
        const decl = @field(Namespace, name);
        if (@typeInfo(@TypeOf(decl)) != .@"fn") continue;
        var takes = false;
        inline for (@typeInfo(@TypeOf(decl)).@"fn".param_types) |param| {
            if (param == *Diagnostics) takes = true;
        }
        if (!takes) return false;
    }
    return true;
}

test "everyFunctionTakesDiagnostics tells a namespace that does from one that doesn't" {
    const Good = struct {
        pub fn op(_: f64, _: *Diagnostics) void {}
        pub const CONSTANT = 1;
    };
    const Bad = struct {
        pub fn op(_: f64) void {}
    };
    try testing.expect(comptime everyFunctionTakesDiagnostics(Good));
    try testing.expect(comptime !everyFunctionTakesDiagnostics(Bad));
    try testing.expect(comptime everyFunctionTakesDiagnostics(input));
    _ = Parallel.serial;
}
