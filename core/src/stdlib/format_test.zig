//! String#% (format.zig): each directive with its flags, width and precision as Ruby's
//! `format` writes it, and what a format that doesn't fit its arguments is told.

const support = @import("../test_support.zig");
const expectScripts = support.expectScripts;
const rescued = support.rescued;

test "format: integers truncated toward zero, in any base, signed and padded" {
    try expectScripts(&.{
        .{ .src = "r = \"%05.1f mm\" % 3.14159", .expected = .{ .str = "003.1 mm" } },
        .{ .src = "r = [\"%d\" % 3.99, \"%d\" % -3.99, \"%+d\" % 5, \"% d\" % 5, \"%i\" % 0].join(\"|\")", .expected = .{ .str = "3|-3|+5| 5|0" } },
        .{ .src = "r = \"%5d|%-5d|%05d|%.3d\" % [42, 42, -42, 7]", .expected = .{ .str = "   42|42   |-0042|007" } },
        .{ .src = "r = \"%x %X %o %b %#x %#o %#b %#x\" % [255, 255, 8, 5, 255, 8, 5, 0]", .expected = .{ .str = "ff FF 10 101 0xff 010 0b101 0" } },
        .{ .src = "r = \"%x\" % -255", .expected = .{ .str = "-ff" } },
    });
}

test "format: f, e and g write numbers as C does, rounding the digits a number prints with" {
    try expectScripts(&.{
        // Half away from zero, on the decimal digits (2.675 prints as 2.675)
        .{ .src = "r = [\"%.2f\" % 2.675, \"%f\" % 1, \"%.0f\" % 0.5, \"%#.0f\" % 2, \"%+.1f\" % -0.04].join(\"|\")", .expected = .{ .str = "2.68|1.000000|1|2.|-0.0" } },
        .{ .src = "r = [\"%e\" % 12345.678, \"%.2e\" % 0.000123, \"%E\" % 1e300, \"%.0e\" % 5].join(\"|\")", .expected = .{ .str = "1.234568e+04|1.23e-04|1.000000E+300|5e+00" } },
        .{ .src = "r = [\"%g\" % 0.0001, \"%g\" % 0.00001, \"%g\" % 123456789, \"%g\" % 100, \"%.3g\" % 3.14159].join(\"|\")", .expected = .{ .str = "0.0001|1e-05|1.23457e+08|100|3.14" } },
        // %g's exponent after rounding: 9.9999995 is 10 to six digits
        .{ .src = "r = [\"%#g\" % 1, \"%g\" % 0, \"%g\" % 9.9999995, \"%G\" % 1e-10, \"%010.3f\" % -3.14159].join(\"|\")", .expected = .{ .str = "1.00000|0|10|1E-10|-00003.142" } },
        .{ .src = "r = [\"%f\" % Number::NAN, \"%5.1f\" % Number::INFINITY, \"%05f\" % -Number::INFINITY, \"%+f\" % Number::INFINITY, \"%E\" % Number::NAN].join(\"|\")", .expected = .{ .str = "NaN|  Inf| -Inf|+Inf|NAN" } },
    });
}

test "format: s as puts shows a value and p as inspect does, a precision cutting characters" {
    try expectScripts(&.{
        .{ .src = "r = \"%s and %p\" % [\"a\", \"a\"]", .expected = .{ .str = "a and \"a\"" } },
        .{ .src = "r = [\"%-4s|\" % \"ab\", \"%.2s\" % \"héllo\", \"%3s\" % \"é\", \"%s\" % [[1, 2]], \"%p\" % :m3].join(\"\")", .expected = .{ .str = "ab  |hé  é[1, 2]:m3" } },
        .{ .src = "r = \"100%% of %s\" % \"it\"", .expected = .{ .str = "100% of it" } },
        // A script's to_s, run while the arguments stay rooted
        .{ .src = "class P\n  def to_s = \"pt\"\nend\nr = \"%s|%p|%s\" % [P.new, P.new, \"#{1 + 1}\"]", .expected = .{ .str = "pt|pt|2" }, .gc_stress = true },
    });
}

test "format: a format that doesn't fit its arguments is an error saying how" {
    try expectScripts(&.{
        .{ .src = comptime rescued("\"%d\" % \"x\""), .expected = .{ .str = "TypeError: %: %d formats a Number, got String" } },
        .{ .src = comptime rescued("\"%d %d\" % [1]"), .expected = .{ .str = "ArgumentError: %: the format has more directives than the 1 argument given" } },
        .{ .src = comptime rescued("\"%d\" % [1, 2]"), .expected = .{ .str = "ArgumentError: %: 2 arguments given, but the format uses 1" } },
        .{ .src = comptime rescued("\"abc\" % 5"), .expected = .{ .str = "ArgumentError: %: 1 argument given, but the format uses 0" } },
        .{ .src = comptime rescued("\"%q\" % 1"), .expected = .{ .str = "ArgumentError: %: '%q' is no directive (they are %d %i %f %e %g %x %o %b %s %p, and %% for a %)" } },
        .{ .src = comptime rescued("\"%5\" % 1"), .expected = .{ .str = "ArgumentError: %: the format ends inside a directive" } },
        .{ .src = comptime rescued("\"%d\" % Number::NAN"), .expected = .{ .str = "ValueError: %: %d needs a finite number, got NaN" } },
        .{ .src = comptime rescued("\"%d\" % 1e20"), .expected = .{ .str = "RangeError: %: 1e20 is past a 64-bit integer" } },
        .{ .src = comptime rescued("\"%.101f\" % 1"), .expected = .{ .str = "RangeError: %: a precision is at most 100 digits" } },
        .{ .src = comptime rescued("\"%1000001d\" % 1"), .expected = .{ .str = "RangeError: %: a width is at most 1000000 characters" } },
        // Other operands stay an operator's TypeError
        .{ .src = comptime rescued("5 % \"a\""), .expected = .{ .str = "TypeError: '%' can't combine Number and String" } },
        .{ .src = comptime rescued("[1] % 2"), .expected = .{ .str = "TypeError: '%' can't combine Array and Number" } },
    });
}
