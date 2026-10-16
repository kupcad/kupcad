//! The values a numeric range walks: shared by Range and Number iteration in the stdlib
//! and by `for` loops in the VM, so all agree on how many values there are and what each is.

const std = @import("std");
const value = @import("../core/value.zig");
const VM = @import("vm.zig").VM;

/// Largest count whose indices are all exactly representable as f64 (2^53). Beyond it,
/// `start + i * step` stops producing distinct values, so iteration would be wrong, not just
/// long. This is a correctness bound, not a resource limit: block iteration is governed by
/// the VM's instruction budget and cancellation, exactly like a `while` loop.
const MAX_EXACT_COUNT: u64 = 1 << std.math.floatMantissaBits(f64) + 1;

/// An arithmetic sequence start, start + step, ... bounded by `end`.
pub const Span = struct {
    start: f64,
    end: f64,
    step: f64,
    is_exclusive: bool,

    /// Number of values the span yields. Mirrors Ruby's `ruby_float_step_size`: the
    /// epsilon allowance makes `(0..0.3).step(0.1)` yield 4 values even though
    /// `0.3 / 0.1` is 2.9999999999999996 in binary floating point.
    /// Callers must have validated the span (finite, non-zero step).
    pub fn count(self: Span) f64 {
        const n = (self.end - self.start) / self.step;
        const err = @min(0.5, (@abs(self.start) + @abs(self.end) + @abs(self.end - self.start)) / @abs(self.step) * std.math.floatEps(f64));
        if (self.is_exclusive) {
            if (n <= 0) return 0;
            var whole: f64 = if (n < 1) 0 else @floor(n - err);
            const next = (whole + 1) * self.step + self.start;
            if (if (self.start < self.end) next < self.end else next > self.end) whole += 1;
            return whole + 1;
        }
        if (n < 0) return 0;
        return @floor(n + err) + 1;
    }

    /// The i-th value, computed from `start` rather than by accumulation so float
    /// error does not grow with the index; clamped so the last value never overshoots.
    pub fn at(self: Span, i: u64) f64 {
        const d = @as(f64, @floatFromInt(i)) * self.step + self.start;
        if (if (self.step >= 0) self.end < d else d < self.end) return self.end;
        return d;
    }
};

/// Validates `span` for `method` (finite bounds and step, non-zero step) and returns its
/// value count as an f64, or raises a rescuable ValueError.
pub fn validatedCount(vm: *VM, span: Span, method: []const u8) !f64 {
    if (!std.math.isFinite(span.start) or !std.math.isFinite(span.end) or !std.math.isFinite(span.step)) {
        return vm.fail(.ValueError, "{s} requires finite bounds and step, got {f}..{f} step {f}", .{ method, value.fmtNumber(span.start), value.fmtNumber(span.end), value.fmtNumber(span.step) });
    }
    if (span.step == 0) {
        return vm.fail(.ValueError, "{s} step can't be 0", .{method});
    }
    return span.count();
}

/// Count for a block-driven iteration: no resource cap, only MAX_EXACT_COUNT.
pub fn iterationCount(vm: *VM, span: Span, method: []const u8) !u64 {
    const n = try validatedCount(vm, span, method);
    if (n > @as(f64, @floatFromInt(MAX_EXACT_COUNT))) {
        return vm.fail(.ValueError, "{s} would iterate {d} times, more than the {d} distinct values a float can count", .{ method, n, MAX_EXACT_COUNT });
    }
    // Finite, non-negative and at most 2^53, so the cast is defined.
    return @intFromFloat(n);
}
