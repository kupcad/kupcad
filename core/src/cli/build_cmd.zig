//! `kupcad build`: runs a script with its parameter values (`-p`, `-P`) and the project's memory limit,
//! then exports its final geometry as STL, GLB, glTF or STEP (B-Rep kernel for STEP), the
//! format picked from `--format` or the `-o` extension. Entry points `execute` and `run`.

const std = @import("std");
const api = @import("../api.zig");
const kernel = @import("../kernel/kernel.zig");
const fs = @import("fs.zig");
const param_flags = @import("param_flags.zig");
const SessionManager = @import("../daemon/session_manager.zig").SessionManager;
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;
const ProjectConfig = @import("config.zig").ProjectConfig;
const CONFIG_FILE_NAME = @import("config.zig").FILE_NAME;
const diagnostic_report = @import("diagnostic_report.zig");
const session_mod = @import("../daemon/session.zig");
const debug = @import("../stdlib/debug.zig");
const Args = @import("args.zig").Args;
const ScriptSession = session_mod.ScriptSession;
const VM = @import("../vm/vm.zig").VM;

pub const USAGE =
    \\Usage: kupcad build <file.kup> [options]
    \\
    \\Runs a script and exports its final geometry.
    \\
    \\Options:
    \\  -o, --output <file>       Output path; its extension picks the format
    \\                            (.stl, .glb, .gltf, .step, .stp, .3mf)
    \\  -f, --format <name>       stl, glb, gltf, step or 3mf (glb when there is no -o)
    \\
++ param_flags.USAGE ++
    \\  -d, --draco               Compress glb and gltf meshes with Draco
    \\      --bom <file.json>     Also write the model's parts list: each part, how many
    \\                            copies, its volume, size and mass
    \\      --split <dir>         Write each part to its own file in <dir>, as made
    \\                            (not placed), named after it (stl unless -f says)
    \\  -h, --help                Show this help
    \\
;

/// Formats `build` can write; the tag names are what `--format` accepts.
const Format = api.ExportFormat;

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
    .{ .ext = ".3mf", .format = .@"3mf" },
};
/// The format `--split` writes its parts in, without `--format`: what a slicer reads.
const DEFAULT_SPLIT_FORMAT: Format = .stl;

/// "stl, glb, gltf, step", for error messages.
const FORMAT_LIST = blk: {
    var list: []const u8 = "";
    for (@typeInfo(Format).@"enum".field_names, 0..) |name, i| list = list ++ (if (i == 0) "" else ", ") ++ name;
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

/// Writes each part of the model to its own file in `dir` (`--split`), named by
/// PartFileNames; false, the failure reported, when the model can't be written.
fn writeSplit(allocator: std.mem.Allocator, vm: *VM, dir: []const u8, format: Format, use_draco: bool, reporter: Reporter) !bool {
    const files = api.exportPartsFromVm(allocator, vm, format, use_draco) catch |err| {
        reporter.err("Export failed: {}\n", .{err});
        return false;
    };
    defer {
        api.freePartFiles(allocator, files);
        allocator.free(files);
    }
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(reporter.io, dir);
    var names: PartFileNames = .{};
    defer names.deinit(allocator);
    for (files, 1..) |file, number| {
        const name = try names.next(allocator, file.name, number, @tagName(format));
        defer allocator.free(name);
        const path = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(path);
        try cwd.writeFile(reporter.io, .{ .sub_path = path, .data = file.bytes });
        reporter.out("Wrote {s} ({d} {s})\n", .{ path, file.count, if (file.count == 1) "copy" else "copies" });
    }
    return true;
}

/// The file names `--split` gives the parts: a part's name with what a file name can't hold
/// replaced by `_`, "part N" (its number in the list) for one without a name, and a number
/// after one already given ("bolt 2"), case aside, as macOS and Windows compare names.
pub const PartFileNames = struct {
    /// The names given, lowercased, owned.
    taken: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *PartFileNames, allocator: std.mem.Allocator) void {
        var it = self.taken.keyIterator();
        while (it.next()) |name| allocator.free(name.*);
        self.taken.deinit(allocator);
    }

    /// The next part's file name, with `extension`; caller owns it.
    pub fn next(self: *PartFileNames, allocator: std.mem.Allocator, part_name: ?[]const u8, number: usize, extension: []const u8) ![]u8 {
        const safe = try safeName(allocator, part_name orelse "");
        defer allocator.free(safe);
        const base = if (safe.len > 0) try allocator.dupe(u8, safe) else try allocator.print("part {d}", .{number});
        defer allocator.free(base);
        var copy: usize = 1;
        while (true) : (copy += 1) {
            const stem = if (copy == 1) try allocator.dupe(u8, base) else try allocator.print("{s} {d}", .{ base, copy });
            defer allocator.free(stem);
            const key = try std.ascii.allocLowerString(allocator, stem);
            const entry = self.taken.getOrPut(allocator, key) catch |err| {
                allocator.free(key);
                return err;
            };
            if (entry.found_existing) {
                allocator.free(key);
                continue;
            }
            return allocator.print("{s}.{s}", .{ stem, extension });
        }
    }

    /// `name` without what a file name can't hold (separators, the characters Windows
    /// reserves, control characters) and without spaces or dots at either end.
    fn safeName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
        const kept = try allocator.dupe(u8, name);
        defer allocator.free(kept);
        for (kept) |*c| switch (c.*) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|', 0...0x1f, 0x7f => c.* = '_',
            else => {},
        };
        return allocator.dupe(u8, std.mem.trim(u8, kept, " ."));
    }
};

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
    var bom_path: ?[]const u8 = null;
    var split_dir: ?[]const u8 = null;

    // The values `-p` and `-P` give, in order: the later of two for one parameter wins
    var params: api.ParamValues = .{};
    defer params.deinit(allocator);

    // --- 1. Parse Command Line Arguments ---
    while (args_iter.next()) |arg| {
        switch (try param_flags.take(allocator, arg, args_iter, &params, reporter)) {
            .taken => continue,
            .refused => return .failure,
            .other => {},
        }
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = args_iter.next() orelse {
                reporter.err("Error: Missing output path after {s}\n", .{arg});
                return .failure;
            };
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--draco")) {
            use_draco = true;
        } else if (std.mem.eql(u8, arg, "--split")) {
            split_dir = args_iter.next() orelse {
                reporter.err("Error: Missing directory after {s}\n", .{arg});
                return .failure;
            };
        } else if (std.mem.eql(u8, arg, "--bom")) {
            bom_path = args_iter.next() orelse {
                reporter.err("Error: Missing parts list path after {s}\n", .{arg});
                return .failure;
            };
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            const name = args_iter.next() orelse {
                reporter.err("Error: Missing format after {s}\n", .{arg});
                return .failure;
            };
            explicit_format = Format.parse(name) orelse {
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

    if (split_dir != null and output_path != null) {
        reporter.err("Error: --split writes a file per part into its directory; leave out -o\n", .{});
        return .failure;
    }
    const format = if (split_dir != null)
        explicit_format orelse DEFAULT_SPLIT_FORMAT
    else
        resolveFormat(explicit_format, output_path, reporter) orelse return .failure;
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

    session.setParams(&params);
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
    const cwd = std.Io.Dir.cwd();
    if (split_dir) |dir| {
        if (!try writeSplit(allocator, &session.vm, dir, format, use_draco, reporter)) return .failure;
    } else {
        const output_bytes = api.exportModelFromVm(allocator, &session.vm, format, use_draco) catch |err| {
            reporter.err("Export failed: {}\n", .{err});
            return .failure;
        };
        defer allocator.free(output_bytes);
        try cwd.writeFile(io, .{ .sub_path = final_output, .data = output_bytes });
        reporter.out("Successfully built {s} ({d} bytes)\n", .{ final_output, output_bytes.len });
    }

    if (bom_path) |path| {
        // A part the script can read about (a B-Rep one has no volume yet) was raised by the VM
        const parts = api.billOfMaterials(allocator, &session.vm) catch |err| {
            reporter.err("Parts list failed: {}\n", .{err});
            return .failure;
        };
        defer allocator.free(parts);
        try cwd.writeFile(io, .{ .sub_path = path, .data = parts });
        reporter.out("Wrote the parts list to {s}\n", .{path});
    }
    return .success;
}
