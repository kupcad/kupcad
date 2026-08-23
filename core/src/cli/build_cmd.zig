const std = @import("std");
const api = @import("../api.zig");
const fs = @import("fs.zig");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var format: []const u8 = "stl"; // Default format

    // Hold our parsed CLI parameters
    var cli_params = std.StringHashMap(f64).init(allocator);
    defer cli_params.deinit();

    // Parse Arguments
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--param")) {
            const pair = args_iter.next() orelse {
                std.debug.print("Error: Missing key=value after {s}\n", .{arg});
                return;
            };
            var it = std.mem.splitScalar(u8, pair, '=');
            const key = it.next() orelse continue;
            const val_str = it.next() orelse {
                std.debug.print("Error: Invalid param format. Use --param key=value.\n", .{});
                return;
            };

            const val = std.fmt.parseFloat(f64, val_str) catch {
                std.debug.print("Error: Param value must be numeric (e.g. 5.5, 1, 0). Got '{s}'\n", .{val_str});
                return;
            };
            try cli_params.put(key, val);
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = args_iter.next();
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            format = args_iter.next() orelse {
                std.debug.print("Error: Missing format after {s}\n", .{arg});
                return;
            };
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            input_path = arg;
        }
    }

    const target_input = input_path orelse {
        std.debug.print("Error: Missing input file path.\n", .{});
        return;
    };

    // Auto-generate output filename if not explicitly provided
    const generated_output = if (output_path == null) blk: {
        const stem = std.fs.path.stem(target_input);
        if (std.fs.path.dirname(target_input)) |dir| {
            break :blk try std.fmt.allocPrint(allocator, "{s}{c}{s}.{s}", .{ dir, std.fs.path.sep, stem, format });
        } else {
            break :blk try std.fmt.allocPrint(allocator, "{s}.{s}", .{ stem, format });
        }
    } else null;
    defer if (generated_output) |p| allocator.free(p);

    const final_output = output_path orelse generated_output.?;

    // Read Source
    const source = try fs.readFileLimit(init.io, allocator, target_input, MAX_FILE_SIZE);
    defer allocator.free(source);

    // Compile, Inject, and Evaluate
    const output_bytes = api.buildModel(allocator, init.io, source, format, cli_params) catch |err| {
        std.debug.print("Build failed: {}\n", .{err});
        return;
    };
    defer allocator.free(output_bytes);

    // Export File
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(init.io, .{
        .sub_path = final_output,
        .data = output_bytes,
    });

    std.debug.print("Successfully built {s} ({d} bytes)\n", .{ final_output, output_bytes.len });
}
