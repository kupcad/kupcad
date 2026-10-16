//! `kupcad build`: runs a script with its `--param` values and the project's memory limit,
//! then exports its final geometry as STL, GLB, glTF or STEP (B-Rep kernel for STEP), the
//! format picked from `--format` or the `-o` extension. Entry points `execute` and `run`.

const std = @import("std");
const api = @import("../api.zig");
const kernel = @import("../kernel/kernel.zig");
const fs = @import("fs.zig");
const SessionManager = @import("../daemon/session_manager.zig").SessionManager;
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;
const ProjectConfig = @import("config.zig").ProjectConfig;
const CONFIG_FILE_NAME = @import("config.zig").FILE_NAME;
const diagnostic_report = @import("diagnostic_report.zig");
const session_mod = @import("../daemon/session.zig");
const debug = @import("../stdlib/debug.zig");
const Args = @import("args.zig").Args;
const ScriptSession = session_mod.ScriptSession;

pub const USAGE =
    \\Usage: kupcad build <file.kup> [options]
    \\
    \\Runs a script and exports its final geometry.
    \\
    \\Options:
    \\  -o, --output <file>       Output path; its extension picks the format
    \\                            (.stl, .glb, .gltf, .step, .stp)
    \\  -f, --format <name>       stl, glb, gltf or step (glb when there is no -o)
    \\  -p, --param <name=value>  Value for param(:name); repeatable
    \\  -d, --draco               Compress glb and gltf meshes with Draco
    \\  -h, --help                Show this help
    \\
;

/// Formats `build` can write. Tag names are what `--format` accepts and what
/// `api.exportModelFromVm` expects.
const Format = enum { stl, glb, gltf, step };

/// Used only when no `-o` is given and no `--format` either.
const DEFAULT_FORMAT: Format = .glb;

/// Output file extensions (matched case-insensitively) and the format each implies, so
/// `-o part.stl` writes STL instead of a mislabeled default-format file.
const OUTPUT_EXTENSIONS = [_]struct { ext: []const u8, format: Format }{
    .{ .ext = ".stl", .format = .stl },
    .{ .ext = ".glb", .format = .glb },
    .{ .ext = ".gltf", .format = .gltf },
    .{ .ext = ".step", .format = .step },
    .{ .ext = ".stp", .format = .step },
};

/// "stl, glb, gltf, step", for error messages.
const FORMAT_LIST = blk: {
    var list: []const u8 = "";
    for (std.meta.fieldNames(Format), 0..) |name, i| list = list ++ (if (i == 0) "" else ", ") ++ name;
    break :blk list;
};

/// ".stl, .glb, .gltf, .step, .stp", for error messages.
const EXTENSION_LIST = blk: {
    var list: []const u8 = "";
    for (OUTPUT_EXTENSIONS, 0..) |entry, i| list = list ++ (if (i == 0) "" else ", ") ++ entry.ext;
    break :blk list;
};

fn formatForExtension(ext: []const u8) ?Format {
    for (OUTPUT_EXTENSIONS) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry.ext)) return entry.format;
    }
    return null;
}

/// Picks the export format. A recognized `-o` extension decides it, and an explicit
/// `--format` must agree with it; an unrecognized extension needs `--format`. Without
/// `-o` the output name is derived from the format, so the default cannot mislabel it.
/// Reports and returns null when the combination is ambiguous or contradictory.
fn resolveFormat(explicit: ?Format, output_path: ?[]const u8, reporter: Reporter) ?Format {
    const path = output_path orelse return explicit orelse DEFAULT_FORMAT;
    const ext = std.fs.path.extension(path);
    if (formatForExtension(ext)) |inferred| {
        if (explicit) |chosen| {
            if (chosen != inferred) {
                reporter.err("Error: --format {s} conflicts with output extension {s}\n", .{ @tagName(chosen), ext });
                return null;
            }
        }
        return inferred;
    }
    if (explicit) |chosen| return chosen;
    reporter.err("Error: Cannot infer the format from output path '{s}'. Use an extension ({s}) or pass --format.\n", .{ path, EXTENSION_LIST });
    return null;
}

/// `name=value` from `--param`: the name is everything before the first `=`, so
/// `w=1=2` is a bad number rather than `w=1`, and the value is finite, as script numbers are.
fn parseParam(pair: []const u8) error{ MissingEquals, EmptyName, NotANumber }!struct { name: []const u8, value: f64 } {
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.MissingEquals;
    if (eq == 0) return error.EmptyName;
    const val = std.fmt.parseFloat(f64, pair[eq + 1 ..]) catch return error.NotANumber;
    if (!std.math.isFinite(val)) return error.NotANumber;
    return .{ .name = pair[0..eq], .value = val };
}

pub const Outcome = @import("outcome.zig").Outcome;

pub const Reporter = @import("reporter.zig").Reporter;

/// Prints a module's errors the way `kupcad check` does (file:line:col, the source line
/// and a caret), then a one-line summary.
pub fn reportErrors(allocator: std.mem.Allocator, session: *const ScriptSession, failure: *const session_mod.Failure, reporter: Reporter) !void {
    const mod = &session.workspace.modules.items[@backingInt(failure.module)];
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    defer rendered.deinit();
    const count = try diagnostic_report.writeErrors(&rendered.writer, allocator, mod.path, mod.source, failure.diagnostics, reporter.err_style);
    reporter.err("{s}Build failed: {d} error{s} in {s}\n", .{ rendered.written(), count, if (count == 1) "" else "s", mod.path });
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    return run(allocator, args_iter, .forProcess(init));
}

/// Runs `kupcad build` with the remaining CLI arguments (`args_iter` needs `next() ?[]const u8`).
/// User-facing failures are reported and return `.failure`; unexpected errors propagate.
pub fn run(allocator: std.mem.Allocator, args_iter: anytype, reporter: Reporter) !Outcome {
    const io = reporter.io;
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var explicit_format: ?Format = null;
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
            const param = parseParam(pair) catch |err| {
                switch (err) {
                    error.MissingEquals => reporter.err("Error: Invalid param format. Use --param key=value.\n", .{}),
                    error.EmptyName => reporter.err("Error: Param '{s}' has no name. Use --param key=value.\n", .{pair}),
                    error.NotANumber => reporter.err("Error: Param value must be a finite number. Got '{s}'\n", .{pair[std.mem.indexOfScalar(u8, pair, '=').? + 1 ..]}),
                }
                return .failure;
            };
            try cli_params.put(param.name, param.value);
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = args_iter.next() orelse {
                reporter.err("Error: Missing output path after {s}\n", .{arg});
                return .failure;
            };
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--draco")) {
            use_draco = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            const name = args_iter.next() orelse {
                reporter.err("Error: Missing format after {s}\n", .{arg});
                return .failure;
            };
            explicit_format = std.meta.stringToEnum(Format, name) orelse {
                reporter.err("Error: Unsupported format '{s}'. Allowed: {s}\n", .{ name, FORMAT_LIST });
                return .failure;
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            reporter.err("Error: Unknown option '{s}'\n\n" ++ USAGE, .{arg});
            return .failure;
        } else if (input_path) |first| {
            reporter.err("Error: Expected one input file, got '{s}' and '{s}'\n", .{ first, arg });
            return .failure;
        } else {
            input_path = arg;
        }
    }

    const target_input = input_path orelse {
        reporter.err("Error: Missing input file path.\n\n" ++ USAGE, .{});
        return .failure;
    };

    const format = resolveFormat(explicit_format, output_path, reporter) orelse return .failure;
    const format_name = @tagName(format);

    // Draco is a glTF mesh-compression extension; the STL and STEP exporters would
    // silently drop the request, so refuse it rather than pretend it was applied.
    if (use_draco and format != .glb and format != .gltf) {
        reporter.err("Error: --draco only applies to glb and gltf output, not {s}\n", .{format_name});
        return .failure;
    }

    // --- 2. Determine Final Output Path ---
    // If the user didn't specify an output path, generate one matching the input file's name and location
    const generated_output = if (output_path == null) blk: {
        const stem = std.fs.path.stem(target_input);
        if (std.fs.path.dirname(target_input)) |dir| {
            break :blk try allocator.print("{s}{c}{s}.{s}", .{ dir, std.fs.path.sep, stem, format_name });
        } else {
            break :blk try allocator.print("{s}.{s}", .{ stem, format_name });
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

    try session.setParams(cli_params.unmanaged);
    session.vm.debugger_handler = debug.terminalDebugger(io);
    // The project's memory sandbox (`vm_memory_limit` in .kupcad.json), if it sets one.
    var where: ProjectConfig.Position = .{ .line = 0, .column = 0 };
    const config = ProjectConfig.forScript(io, allocator, target_input, &where) catch |err| {
        reporter.err("Error: {s} near {s}:{d}:{d}: {s}\n", .{ CONFIG_FILE_NAME, target_input, where.line, where.column, ProjectConfig.describeError(err) });
        return .failure;
    };
    session.vm.setMemoryLimit(config.vm_memory_limit);

    // Force exact analytical representations if STEP export is requested
    if (format == .step) {
        var settings = session.vm.config();
        settings.engine = .brep_native;
        try session.vm.setConfig(settings);
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
        if (err == error.ParseError or err == error.CompileError) if (session.failure) |*failure| {
            try reportErrors(allocator, session, failure, reporter);
            return .failure;
        };
        reporter.err("Build failed: {}\n", .{err});
        return .failure;
    };

    // --- 5. Export Resulting Geometry ---
    // Use the shared DRY helper to pull from the VM stack and create the binary file
    // A failure the script can read about was raised (and reported) by the VM.
    const output_bytes = api.exportModelFromVm(allocator, &session.vm, format_name, use_draco) catch |err| {
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
