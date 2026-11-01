//! What `kupcad build`, `run` and `watch` read from their arguments: the script, the
//! parameters' values (`-p`, `-P`), the memory limit (`--memory-limit`, else
//! `KUPCAD_MEMORY_LIMIT` in `environ`), how a failure is told (`--errors`) and, for a command
//! that writes the model, its exports.
//! Read here once: each command had its own copy of the loop and its messages.

const std = @import("std");
const api = @import("../api.zig");
const param_flags = @import("param_flags.zig");
const memory_flag = @import("memory_flag.zig");
const ExportFlags = @import("export_flags.zig").ExportFlags;
const reporter_mod = @import("reporter.zig");
const Reporter = reporter_mod.Reporter;

pub const ERRORS_FLAG = "--errors";

pub const ERRORS_USAGE =
    \\  --errors <text|json>      How a failure is told: in words (text, the default), or
    \\                            with one line of JSON last, for a host: an "error"
    \\                            object with kind, message, file, line and column
    \\
;

/// What a command takes of the export options: none (`run`), settled whatever is given
/// (`build`, which writes the model always), or settled when one is given (`watch`, which
/// writes then only).
pub const Exports = enum { none, always, when_given };

pub const ScriptOptions = struct {
    input_path: []const u8,
    /// The values `-p` and `-P` give, in order: the later of two for one parameter wins.
    params: api.ParamValues = .{},
    /// What the model is written as, where the command writes it.
    exports: ExportFlags = .{},
    /// Whether an export option was given.
    writes: bool = false,
    /// `--memory-limit`, else `KUPCAD_MEMORY_LIMIT`, which win over the project's own
    /// (memory_flag.zig); null when neither is given.
    memory_limit: ?usize = null,
    /// `--errors`: how a failure is told (Reporter.fail).
    errors: reporter_mod.ErrorsFormat = .text,

    pub fn deinit(self: *ScriptOptions, allocator: std.mem.Allocator) void {
        self.exports.deinit(allocator);
        self.params.deinit(allocator);
    }

    /// The options in `args` (`next() ?[]const u8`) of a command taking `exports`, whose
    /// help is `usage`; null, the refusal reported.
    pub fn parse(allocator: std.mem.Allocator, args: anytype, environ: *const std.process.Environ.Map, reporter: Reporter, comptime exports: Exports, comptime usage: []const u8) !?ScriptOptions {
        var options: ScriptOptions = .{ .input_path = "" };
        errdefer options.deinit(allocator);
        var given = false;
        while (args.next()) |arg| {
            switch (try param_flags.take(allocator, arg, args, &options.params, reporter)) {
                .taken => continue,
                .refused => return options.refuse(allocator),
                .other => {},
            }
            switch (memory_flag.take(arg, args, &options.memory_limit, reporter)) {
                .taken => continue,
                .refused => return options.refuse(allocator),
                .other => {},
            }
            if (std.mem.eql(u8, arg, ERRORS_FLAG)) {
                const how = args.next() orelse "";
                options.errors = std.meta.stringToEnum(reporter_mod.ErrorsFormat, how) orelse {
                    reporter.err("Error: {s} takes text or json, got '{s}'\n", .{ ERRORS_FLAG, how });
                    return options.refuse(allocator);
                };
                continue;
            }
            if (exports != .none) switch (try options.exports.take(allocator, arg, args, reporter)) {
                .taken => {
                    options.writes = true;
                    continue;
                },
                .refused => return options.refuse(allocator),
                .other => {},
            };
            if (std.mem.startsWith(u8, arg, "-")) {
                reporter.err("Error: Unknown option '{s}'\n\n" ++ usage, .{arg});
                return options.refuse(allocator);
            }
            if (given) {
                reporter.err("Error: Expected one input file, got '{s}' and '{s}'\n", .{ options.input_path, arg });
                return options.refuse(allocator);
            }
            options.input_path = arg;
            given = true;
        }
        if (!given) {
            reporter.err("Error: Missing input file path.\n\n" ++ usage, .{});
            return options.refuse(allocator);
        }
        const settles = switch (exports) {
            .none => false,
            .always => true,
            .when_given => options.writes,
        };
        if (settles and !try options.exports.settle(allocator, reporter)) return options.refuse(allocator);
        options.memory_limit = memory_flag.given(options.memory_limit, environ, reporter) catch return options.refuse(allocator);
        return options;
    }

    fn refuse(self: *ScriptOptions, allocator: std.mem.Allocator) ?ScriptOptions {
        self.deinit(allocator);
        return null;
    }
};
