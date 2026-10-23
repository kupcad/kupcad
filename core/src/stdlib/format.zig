//! `String#%`: `"%05.1f mm" % 3.14159` is `"003.1 mm"`, with Ruby's `format` directives: `%`,
//! then flags (`-` left-justifies, `0` pads a number with zeros, `+` and a space give a
//! sign, `#` a base's prefix), a width, a precision (`.2`) and a conversion: `d` or `i` an
//! integer (truncated toward zero), `f`, `e` and `g` a number, `x`, `o` and `b` an integer
//! in hex, octal or binary, `s` the value as `puts` shows it and `p` as `inspect` does; `%%`
//! is a `%`. The arguments are an Array's items, or the one value. `%f` rounds the decimal
//! digits a number prints with, half away from zero (`"%.2f" % 2.675` is `"2.68"`).

const std = @import("std");
const value = @import("../core/value.zig");
const limits = @import("../core/limits.zig");
const VM = @import("../vm/vm.zig").VM;
const HandleScope = @import("../vm/scope.zig").HandleScope;

/// The most digits a precision asks for: past it, a number has no more to show.
const MAX_PRECISION = 100;
/// Room for a number rendered with MAX_PRECISION decimals (up to 309 integer digits).
const NUMBER_BUFFER_BYTES = 512;
const DEFAULT_FLOAT_PRECISION = 6;
const DIRECTIVES = "%d %i %f %e %g %x %o %b %s %p, and %% for a %";

const Spec = struct {
    left: bool = false,
    zero: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    width: usize = 0,
    precision: ?usize = null,
    conversion: u8 = 0,
};

/// `fmt % arg`: the String `fmt` describes, its directives filled in, in order, from `arg`'s
/// items when it is an Array, else from `arg` alone. Too few arguments or too many is an
/// ArgumentError.
pub fn format(vm: *VM, fmt_val: value.Value, arg: value.Value) !value.Value {
    // Rooted: `%s` and `%p` may run a script's to_s or inspect
    var scope = HandleScope.init(vm);
    defer scope.deinit();
    vm.push(fmt_val);
    vm.push(arg);
    const fmt = fmt_val.asString().chars;

    var out: std.Io.Writer.Allocating = .init(vm.allocator);
    defer out.deinit();
    var used: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            const next = std.mem.findScalarPos(u8, fmt, i, '%') orelse fmt.len;
            try out.writer.writeAll(fmt[i..next]);
            i = next;
            continue;
        }
        i += 1;
        if (i < fmt.len and fmt[i] == '%') {
            try out.writer.writeByte('%');
            i += 1;
            continue;
        }
        const spec = try parseSpec(vm, fmt, &i);
        if (used >= argCount(arg)) return vm.fail(.ArgumentError, "%: the format has more directives than the {d} argument{s} given", .{ argCount(arg), plural(argCount(arg)) });
        try writeDirective(vm, &out.writer, spec, argAt(arg, used));
        used += 1;
    }
    if (used < argCount(arg)) return vm.fail(.ArgumentError, "%: {d} argument{s} given, but the format uses {d}", .{ argCount(arg), plural(argCount(arg)), used });
    return vm.allocateString(out.written());
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

// An Array argument is read afresh at each directive: a script's to_s may change it
fn argCount(arg: value.Value) usize {
    return if (arg.isArray()) arg.asArray().items.items.len else 1;
}

fn argAt(arg: value.Value, n: usize) value.Value {
    if (!arg.isArray()) return arg;
    const items = arg.asArray().items.items;
    return if (n < items.len) items[n] else value.Value.initNil();
}

/// The directive whose flags start at `fmt[i.*]`; `i` is left past its conversion.
fn parseSpec(vm: *VM, fmt: []const u8, i: *usize) !Spec {
    var spec: Spec = .{};
    while (i.* < fmt.len) : (i.* += 1) {
        switch (fmt[i.*]) {
            '-' => spec.left = true,
            '0' => spec.zero = true,
            '+' => spec.plus = true,
            ' ' => spec.space = true,
            '#' => spec.alt = true,
            else => break,
        }
    }
    spec.width = try digits(vm, fmt, i, limits.MAX_STRING_PAD, "width", "characters");
    if (i.* < fmt.len and fmt[i.*] == '.') {
        i.* += 1;
        spec.precision = try digits(vm, fmt, i, MAX_PRECISION, "precision", "digits");
    }
    if (i.* >= fmt.len) return vm.fail(.ArgumentError, "%: the format ends inside a directive", .{});
    spec.conversion = fmt[i.*];
    i.* += 1;
    if (std.mem.findScalar(u8, "diufeEgGxXobBsp", spec.conversion) == null) {
        return vm.fail(.ArgumentError, "%: '%{s}' is no directive (they are " ++ DIRECTIVES ++ ")", .{fmt[i.* - 1 .. i.*]});
    }
    return spec;
}

/// The number written at `fmt[i.*]` (0 for none), at most `max` `unit`.
fn digits(vm: *VM, fmt: []const u8, i: *usize, comptime max: usize, comptime what: []const u8, comptime unit: []const u8) !usize {
    var n: usize = 0;
    while (i.* < fmt.len and std.ascii.isDigit(fmt[i.*])) : (i.* += 1) {
        n = n * 10 + (fmt[i.*] - '0');
        if (n > max) return vm.fail(.RangeError, "%: a " ++ what ++ " is at most {d} " ++ unit, .{max});
    }
    return n;
}

fn writeDirective(vm: *VM, w: *std.Io.Writer, spec: Spec, arg: value.Value) !void {
    var text: std.Io.Writer.Allocating = .init(vm.allocator);
    defer text.deinit();
    switch (spec.conversion) {
        's', 'p' => {
            if (spec.conversion == 's') try vm.writeDisplay(arg, &text.writer) else try vm.writeInspect(arg, &text.writer);
            var shown = text.written();
            if (spec.precision) |p| shown = shown[0..charsEnd(shown, p)];
            return pad(w, spec, "", shown, false);
        },
        else => {},
    }
    if (!arg.isNumber()) return vm.fail(.TypeError, "%: %{c} formats a Number, got {s}", .{ spec.conversion, vm.typeName(arg) });
    const n = arg.asNumber();
    var buf: [NUMBER_BUFFER_BYTES]u8 = undefined;
    switch (spec.conversion) {
        'd', 'i', 'u', 'x', 'X', 'o', 'b', 'B' => {
            if (!std.math.isFinite(n)) return vm.fail(.ValueError, "%: %{c} needs a finite number, got {f}", .{ spec.conversion, value.fmtNumber(n) });
            const t = @trunc(n);
            if (@abs(t) >= 0x1p63) return vm.fail(.RangeError, "%: {f} is past a 64-bit integer", .{value.fmtNumber(n)});
            const int: i64 = @intFromFloat(t);
            const base: u8, const case: std.fmt.Case, const prefix: []const u8 = switch (spec.conversion) {
                'x' => .{ 16, .lower, "0x" },
                'X' => .{ 16, .upper, "0X" },
                'o' => .{ 8, .lower, "0" },
                'b' => .{ 2, .lower, "0b" },
                'B' => .{ 2, .lower, "0B" },
                else => .{ 10, .lower, "" },
            };
            const magnitude = std.fmt.printInt(&buf, @abs(int), base, case, .{});
            var body: std.Io.Writer.Allocating = .init(vm.allocator);
            defer body.deinit();
            // A precision is the fewest digits, as in C
            if (spec.precision) |p| if (p > magnitude) try body.writer.splatByteAll('0', p - magnitude);
            try body.writer.writeAll(buf[0..magnitude]);
            var sign_buf: [3]u8 = undefined;
            const lead = try leading(&sign_buf, spec, int < 0, if (spec.alt and int != 0) prefix else "");
            return pad(w, spec, lead, body.written(), spec.precision == null);
        },
        else => {},
    }
    // f, e, g: NaN and the infinities as Ruby's format writes them
    var sign_buf: [3]u8 = undefined;
    const lead = try leading(&sign_buf, spec, std.math.signbit(n) and !std.math.isNan(n), "");
    const upper = std.ascii.isUpper(spec.conversion);
    if (std.math.isNan(n)) return pad(w, spec, lead, if (upper) "NAN" else "NaN", false);
    if (std.math.isInf(n)) return pad(w, spec, lead, if (upper) "INF" else "Inf", false);
    const precision = spec.precision orelse DEFAULT_FLOAT_PRECISION;
    const body = switch (std.ascii.toLower(spec.conversion)) {
        'f' => try fixed(&buf, @abs(n), precision, spec.alt),
        'e' => try scientific(&buf, @abs(n), precision, spec.alt, upper),
        else => try general(&buf, @abs(n), precision, spec.alt, upper),
    };
    return pad(w, spec, lead, body, true);
}

/// The sign `spec` and a negative number call for, then `prefix` (a base's), in `buf`.
fn leading(buf: *[3]u8, spec: Spec, negative: bool, prefix: []const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (negative) try w.writeByte('-') else if (spec.plus) try w.writeByte('+') else if (spec.space) try w.writeByte(' ');
    try w.writeAll(prefix);
    return w.buffered();
}

/// `lead` and `body` written within `spec.width` characters: spaces before, after (`-`), or
/// zeros between them when `zeros` allows (a finite number's).
fn pad(w: *std.Io.Writer, spec: Spec, lead: []const u8, body: []const u8, zeros: bool) !void {
    const len = lead.len + (std.unicode.utf8CountCodepoints(body) catch body.len);
    const fill = spec.width -| len;
    if (spec.left) {
        try w.writeAll(lead);
        try w.writeAll(body);
        try w.splatByteAll(' ', fill);
    } else if (spec.zero and zeros) {
        try w.writeAll(lead);
        try w.splatByteAll('0', fill);
        try w.writeAll(body);
    } else {
        try w.splatByteAll(' ', fill);
        try w.writeAll(lead);
        try w.writeAll(body);
    }
}

/// Where the first `n` characters of `text` end (all of it when it has fewer).
fn charsEnd(text: []const u8, n: usize) usize {
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    for (0..n) |_| _ = view.nextCodepointSlice() orelse break;
    return view.i;
}

/// `x` (not negative) with `precision` decimals, and the point kept for `#` with none.
fn fixed(buf: []u8, x: f64, precision: usize, alt: bool) ![]const u8 {
    const text = try std.fmt.float.render(buf, x, .{ .mode = .decimal, .precision = precision });
    if (!alt or precision > 0) return text;
    buf[text.len] = '.';
    return buf[0 .. text.len + 1];
}

/// `x` (not negative) as `d.ddde+XX`, the exponent at least two digits, as C's `%e`.
fn scientific(buf: []u8, x: f64, precision: usize, alt: bool, upper: bool) ![]const u8 {
    var rendered: [NUMBER_BUFFER_BYTES]u8 = undefined;
    const text = try std.fmt.float.render(&rendered, x, .{ .mode = .scientific, .precision = precision });
    const e = std.mem.findScalar(u8, text, 'e').?;
    const exponent = std.fmt.parseInt(i32, text[e + 1 ..], 10) catch unreachable;
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll(text[0..e]);
    if (alt and precision == 0) try w.writeByte('.');
    try w.print("{c}{c}{d:0>2}", .{ @as(u8, if (upper) 'E' else 'e'), @as(u8, if (exponent < 0) '-' else '+'), @abs(exponent) });
    return w.buffered();
}

/// `x` (not negative) as C's `%g`: in `%e` form when its exponent is below -4 or at least
/// the precision (the significant digits), else in `%f` form; trailing zeros dropped
/// unless `#`.
fn general(buf: []u8, x: f64, precision: usize, alt: bool, upper: bool) ![]const u8 {
    const significant = @max(precision, 1);
    var probe: [NUMBER_BUFFER_BYTES]u8 = undefined;
    // The exponent `%e` would show, after its rounding (9.9999995 is 1.000000e+01)
    const as_e = try std.fmt.float.render(&probe, x, .{ .mode = .scientific, .precision = significant - 1 });
    const exponent = std.fmt.parseInt(i32, as_e[std.mem.findScalar(u8, as_e, 'e').? + 1 ..], 10) catch unreachable;
    const text = if (exponent < -4 or exponent >= @as(i32, @intCast(significant)))
        try scientific(buf, x, significant - 1, alt, upper)
    else
        try fixed(buf, x, @intCast(@as(i32, @intCast(significant)) - 1 - exponent), alt);
    if (alt) return text;
    // Without `#`, the fraction's trailing zeros go, and a point left alone
    const point = std.mem.findScalar(u8, text, '.') orelse return text;
    const exp_at = std.mem.findAny(u8, text, "eE") orelse text.len;
    var end = exp_at;
    while (end > point + 1 and text[end - 1] == '0') end -= 1;
    if (end == point + 1) end = point;
    if (end == exp_at) return text;
    std.mem.copyForwards(u8, buf[end..], text[exp_at..]);
    return buf[0 .. end + (text.len - exp_at)];
}
