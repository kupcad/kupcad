//! The parameter options `kupcad build` and `kupcad watch` share: `-p name=text` and `-P
//! file.json`, gathered into one ParamValues in the order given, so the later of two values
//! for one parameter wins.

const std = @import("std");
const api = @import("../api.zig");
const fs = @import("fs.zig");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;
const Reporter = @import("reporter.zig").Reporter;

/// The options' lines of a command's USAGE.
pub const USAGE =
    \\  -p, --param <name=value>  Value for param(:name), read as the type its default
    \\                            has; repeatable
    \\  -P, --params <file.json>  Values for parameters, a JSON object of names and
    \\                            numbers, strings or booleans; repeatable. Of two
    \\                            values for one parameter the later (-p or -P) wins
    \\
;

/// What `take` did with an argument.
pub const Taken = enum {
    /// It was -p or -P, and its value is in the parameters.
    taken,
    /// Some other argument, for the command.
    other,
    /// It was refused, and the refusal reported.
    refused,
};

/// Takes `arg`, and the value after it from `args` (anything with `next() ?[]const u8`),
/// when it is -p/--param or -P/--params.
pub fn take(allocator: std.mem.Allocator, arg: []const u8, args: anytype, params: *api.ParamValues, reporter: Reporter) !Taken {
    if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--param")) {
        const pair = args.next() orelse {
            reporter.err("Error: Missing key=value after {s}\n", .{arg});
            return .refused;
        };
        const param = parseParam(pair) catch |err| {
            switch (err) {
                error.MissingEquals => reporter.err("Error: Invalid param format. Use --param key=value.\n", .{}),
                error.EmptyName => reporter.err("Error: Param '{s}' has no name. Use --param key=value.\n", .{pair}),
            }
            return .refused;
        };
        try params.put(allocator, param.name, .{ .text = param.text });
        return .taken;
    }
    if (std.mem.eql(u8, arg, "-P") or std.mem.eql(u8, arg, "--params")) {
        const path = args.next() orelse {
            reporter.err("Error: Missing parameter file after {s}\n", .{arg});
            return .refused;
        };
        return if (try readParamsFile(allocator, path, params, reporter)) .taken else .refused;
    }
    return .other;
}

/// `name=value` from `--param`: the name is everything before the first `=`, so `w=1=2` is
/// the text "1=2" for `w`. The text is read as the parameter's type when the script runs
/// (`param()`), which knows it.
fn parseParam(pair: []const u8) error{ MissingEquals, EmptyName }!struct { name: []const u8, text: []const u8 } {
    const eq = std.mem.findScalar(u8, pair, '=') orelse return error.MissingEquals;
    if (eq == 0) return error.EmptyName;
    return .{ .name = pair[0..eq], .text = pair[eq + 1 ..] };
}

/// Reads the parameter file at `path` (`-P`) into `params`; false, the refusal reported, when
/// it can't be read or isn't one JSON object of names and values.
fn readParamsFile(allocator: std.mem.Allocator, path: []const u8, params: *api.ParamValues, reporter: Reporter) !bool {
    const text = fs.readFileLimit(reporter.io, allocator, path, MAX_FILE_SIZE) catch |err| {
        reporter.err("Error: Could not read parameter file '{s}': {s}\n", .{ path, @errorName(err) });
        return false;
    };
    defer allocator.free(text);
    var why: ?[]u8 = null;
    defer if (why) |w| allocator.free(w);
    params.putJson(allocator, text, &why) catch |err| switch (err) {
        error.InvalidParams => {
            reporter.err("Error: {s}: {s}\n", .{ path, why orelse "not a parameter file" });
            return false;
        },
        else => |e| return e,
    };
    return true;
}
