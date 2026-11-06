//! The inverse trigonometric functions Locus uses: the standard library's, through a
//! barrier on their arguments. `std.math.atan` guards its tiny-argument path with
//! `std.mem.doNotOptimizeAway(@as(f32, ...))`, an inline asm with an "rm" constraint;
//! where LLVM proves that argument a constant (a call inlined into a branch that fixed
//! it), the wasm32 backend cannot select a constant-pool f32 for it and aborts
//! ("Cannot select: ConstantPool<float 0.0>", ReleaseSafe, met in sketch/overlay.zig).
//! The barrier is a volatile read: the argument stays a runtime value, nothing else
//! changes. source_test.zig keeps every other file on these.

const std = @import("std");

pub fn atan2(y: f64, x: f64) f64 {
    return std.math.atan2(runtime(y), runtime(x));
}

pub fn atan(x: f64) f64 {
    return std.math.atan(runtime(x));
}

/// `v`, as a value the optimizer cannot know.
inline fn runtime(v: f64) f64 {
    var cell = v;
    const p: *volatile f64 = &cell;
    return p.*;
}
