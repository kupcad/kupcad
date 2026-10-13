const std = @import("std");
const api = @import("../api.zig");
const fs = @import("fs.zig");
const log_helpers = @import("../log.zig");
const SessionManager = @import("../daemon/session_manager.zig").SessionManager;
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;

/// Process exit status for any failed build, so scripts and CI can detect errors.
const EXIT_FAILURE: u8 = 1;

pub const Outcome = enum { success, failure };

/// Where `run` reports. By default it prints to the process streams; tests set `capture`.
pub const Reporter = struct {
    io: std.Io,
    capture: ?*std.Io.Writer = null,

    fn err(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.capture) |w| w.print(fmt, args) catch {} else log_helpers.printStderr(self.io, fmt, args);
    }

    fn out(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.capture) |w| w.print(fmt, args) catch {} else log_helpers.printStdout(self.io, fmt, args);
    }
};

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    if (try run(allocator, args_iter, .{ .io = init.io }) == .failure) std.process.exit(EXIT_FAILURE);
}

/// Runs `kupcad build` with the remaining CLI arguments (`args_iter` needs `next() ?[]const u8`).
/// User-facing failures are reported and return `.failure`; unexpected errors propagate.
pub fn run(allocator: std.mem.Allocator, args_iter: anytype, reporter: Reporter) !Outcome {
    const io = reporter.io;
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var format: []const u8 = "glb";
    var use_draco: bool = false;

    // Store CLI parameters (e.g., --param width=50) temporarily to inject them later
    var cli_params = std.StringHashMap(f64).init(allocator);
    defer cli_params.deinit();

    // --- 1. Parse Command Line Arguments ---
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--param")) {
            const pair = args_iter.next() orelse {
                reporter.err("Error: Missing key=value after {s}\n", .{arg});
                return .failure;
            };
            var it = std.mem.splitScalar(u8, pair, '=');
            const key = it.next() orelse continue;
            const val_str = it.next() orelse {
                reporter.err("Error: Invalid param format. Use --param key=value.\n", .{});
                return .failure;
            };

            const val = std.fmt.parseFloat(f64, val_str) catch {
                reporter.err("Error: Param value must be numeric. Got '{s}'\n", .{val_str});
                return .failure;
            };
            try cli_params.put(key, val);
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = args_iter.next();
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--draco")) {
            use_draco = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            format = args_iter.next() orelse {
                reporter.err("Error: Missing format after {s}\n", .{arg});
                return .failure;
            };

            if (!std.mem.eql(u8, format, "stl") and !std.mem.eql(u8, format, "glb") and !std.mem.eql(u8, format, "gltf") and !std.mem.eql(u8, format, "step")) {
                reporter.err("Error: Unsupported format '{s}'. Allowed: stl, glb, gltf, step\n", .{format});
                return .failure;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            input_path = arg;
        }
    }

    const target_input = input_path orelse {
        reporter.err("Error: Missing input file path.\n", .{});
        return .failure;
    };

    // --- 2. Determine Final Output Path ---
    // If the user didn't specify an output path, generate one matching the input file's name and location
    const generated_output = if (output_path == null) blk: {
        const stem = std.fs.path.stem(target_input);
        if (std.fs.path.dirname(target_input)) |dir| {
            break :blk try allocator.print("{s}{c}{s}.{s}", .{ dir, std.fs.path.sep, stem, format });
        } else {
            break :blk try allocator.print("{s}.{s}", .{ stem, format });
        }
    } else null;
    defer if (generated_output) |p| allocator.free(p);

    const final_output = output_path orelse generated_output.?;

    // --- 3. Setup Persistent Session Manager ---
    // We use a capacity of 1 since this is a one-shot CLI command.
    var manager = SessionManager.init(allocator, io, 1);
    defer manager.deinit();

    var session = manager.getOrInitializeSession(target_input) catch |err| {
        reporter.err("Failed to initialize session: {}\n", .{err});
        return .failure;
    };

    // Use the shared DRY helper to load the CLI arguments into the active VM state
    api.injectParamsIntoVm(&session.vm, cli_params) catch |err| {
        reporter.err("Failed to inject params: {}\n", .{err});
        return .failure;
    };

    // Force exact analytical representations if STEP export is requested
    if (std.mem.eql(u8, format, "step")) {
        session.vm.config_stack.items[0].engine = .brep_native;
    }

    // --- 4. Evaluate the Workspace ---
    const source = try fs.readFileLimit(io, allocator, target_input, MAX_FILE_SIZE);
    defer allocator.free(source);

    // Feed the source into the Workspace so it can parse imports and build the dependency graph
    _ = try session.workspace.addModule(target_input, source);
    try session.workspace.linkDependencies();
    try session.buildReverseGraph();

    // Perform Kahn's Topological Sort to execute dependencies from bottom to top
    session.evaluateWorkspace() catch |err| {
        reporter.err("Build failed: {}\n", .{err});
        return .failure;
    };

    // --- 5. Export Resulting Geometry ---
    // Use the shared DRY helper to pull from the VM stack and create the binary file
    const output_bytes = api.exportModelFromVm(allocator, &session.vm, format, use_draco) catch |err| {
        reporter.err("Export failed: {}\n", .{err});
        return .failure;
    };
    defer allocator.free(output_bytes);

    // Write the final binary bytes to the filesystem
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{
        .sub_path = final_output,
        .data = output_bytes,
    });

    reporter.out("Successfully built {s} ({d} bytes)\n", .{ final_output, output_bytes.len });
    return .success;
}
