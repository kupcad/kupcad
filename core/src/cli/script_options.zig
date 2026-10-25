//! What `kupcad build`, `run` and `watch` read from their arguments: the script, the
//! parameters' values (`-p`, `-P`) and, for a command that writes the model, its exports.
//! Read here once: each command had its own copy of the loop and its messages.

const std = @import("std");
const api = @import("../api.zig");
const param_flags = @import("param_flags.zig");
const ExportFlags = @import("export_flags.zig").ExportFlags;
const Reporter = @import("reporter.zig").Reporter;

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

    pub fn deinit(self: *ScriptOptions, allocator: std.mem.Allocator) void {
        self.exports.deinit(allocator);
        self.params.deinit(allocator);
    }

    /// The options in `args` (`next() ?[]const u8`) of a command taking `exports`, whose
    /// help is `usage`; null, the refusal reported.
    pub fn parse(allocator: std.mem.Allocator, args: anytype, reporter: Reporter, comptime exports: Exports, comptime usage: []const u8) !?ScriptOptions {
        var options: ScriptOptions = .{ .input_path = "" };
        errdefer options.deinit(allocator);
        var given = false;
        while (args.next()) |arg| {
            switch (try param_flags.take(allocator, arg, args, &options.params, reporter)) {
                .taken => continue,
                .refused => return options.refuse(allocator),
                .other => {},
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
        return options;
    }

    fn refuse(self: *ScriptOptions, allocator: std.mem.Allocator) ?ScriptOptions {
        self.deinit(allocator);
        return null;
    }
};
