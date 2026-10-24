//! `kupcad version`: the version of kupcad, as `--version` prints it, or with `--json` what a
//! front end checks before it runs this binary (version.zig): the version, the protocol
//! version and the platform it was built for.

const std = @import("std");
const build_info = @import("build_info");
const Info = @import("../version.zig").Info;
pub const Outcome = @import("outcome.zig").Outcome;
const Args = @import("args.zig").Args;
const Reporter = @import("reporter.zig").Reporter;

pub const USAGE =
    \\Usage: kupcad version [--json]
    \\
    \\Prints the version of kupcad. With --json, prints it as a JSON object with the
    \\protocol version front ends check and the platform it was built for:
    \\{"version": "0.1.0", "protocolVersion": 1, "os": "macos", "arch": "aarch64"}
    \\
;

pub const TEXT = "kupcad " ++ build_info.version ++ "\n";

pub fn execute(init: std.process.Init, _: std.mem.Allocator, args: *Args) !Outcome {
    return run(args, .forProcess(init));
}

pub fn run(args: *Args, reporter: Reporter) Outcome {
    var json = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            continue;
        }
        reporter.err("Error: Unknown option '{s}'\n\n{s}", .{ arg, USAGE });
        return .failure;
    }
    if (json) reporter.out("{f}\n", .{std.json.fmt(Info{}, .{})}) else reporter.out("{s}", .{TEXT});
    return .success;
}
