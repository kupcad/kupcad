//! `kupcad build`: runs a script with its parameter values (`-p`, `-P`) and the project's memory limit,
//! then exports its model in a format of `api.ExportFormat` (STL, GLB, glTF, 3MF, STEP on
//! the B-Rep kernel), picked from `--format` or the `-o` extension. Entry points `execute`
//! and `run`.

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
pub const Outcome = @import("outcome.zig").Outcome;
pub const Reporter = @import("reporter.zig").Reporter;

pub const USAGE =
    \\Usage: kupcad build <file.kup> [options]
    \\
    \\Runs a script and exports its final geometry.
    \\
    \\Options:
    \\  -o, --output <file>       Output path; its extension picks the format
    \\                            (
++ Format.EXTENSIONS ++ ")\n" ++
    \\  -f, --format <name>       
++ Format.NAMES ++ " (glb when there is no -o)\n" ++
    param_flags.USAGE ++
    \\  -d, --draco               Compress glb and gltf meshes with Draco
    \\      --mtl                 Also write the materials of an obj as a library beside it
    \\                            (<output>.mtl; materials.mtl with --split)
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
/// The format `--split` writes its parts in, without `--format`: what a slicer reads.
const DEFAULT_SPLIT_FORMAT: Format = .stl;

/// Picks the export format. A recognized `-o` extension decides it, and an explicit
/// `--format` must agree with it; an unrecognized extension needs `--format`. Without
/// `-o` the output name is derived from the format, so the default cannot mislabel it.
/// Reports and returns null when the combination is ambiguous or contradictory.
fn resolveFormat(explicit: ?Format, output_path: ?[]const u8, reporter: Reporter) ?Format {
    const path = output_path orelse return explicit orelse DEFAULT_FORMAT;
    const ext = std.fs.path.extension(path);
    if (Format.forExtension(ext)) |inferred| {
        if (explicit) |chosen| {
            if (chosen != inferred) {
                reporter.err("Error: --format {s} conflicts with output extension {s}\n", .{ @tagName(chosen), ext });
                return null;
            }
        }
        return inferred;
    }
    if (explicit) |chosen| return chosen;
    reporter.err("Error: Cannot infer the format from output path '{s}'. Use an extension ({s}) or pass --format.\n", .{ path, Format.EXTENSIONS });
    return null;
}

/// The material library the parts of a `--split` share.
const SPLIT_MTL_NAME = "materials.mtl";

/// Writes each part of the model to its own file in `dir` (`--split`), named by
/// PartFileNames, and with `--mtl` the one library they share; false, the failure
/// reported, when the model can't be written.
fn writeSplit(allocator: std.mem.Allocator, vm: *VM, dir: []const u8, options: *const Options, reporter: Reporter) !bool {
    const exporting: api.ExportOptions = .{ .draco = options.use_draco, .mtl_name = if (options.use_mtl) SPLIT_MTL_NAME else null };
    const files = api.exportPartsFromVm(allocator, vm, options.format, exporting) catch |err| {
        reporter.err("Export failed: {}\n", .{err});
        return false;
    };
    defer {
        api.freePartFiles(allocator, files);
        allocator.free(files);
    }
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(reporter.io, dir);
    if (options.use_mtl) {
        const path = try std.fs.path.join(allocator, &.{ dir, SPLIT_MTL_NAME });
        defer allocator.free(path);
        try writeMaterialLibrary(allocator, vm, path, reporter);
    }
    var names: PartFileNames = .{};
    defer names.deinit(allocator);
    for (files, 1..) |file, number| {
        const name = try names.next(allocator, file.name, number, options.format.extension()[1..]);
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

/// What `kupcad build` was asked to do.
const Options = struct {
    input_path: []const u8,
    /// `-o`; without it the model goes next to the input, named after it.
    output_path: ?[]const u8 = null,
    format: Format = DEFAULT_FORMAT,
    use_draco: bool = false,
    /// `--mtl`: an OBJ names its materials, written to a library beside it.
    use_mtl: bool = false,
    /// `--bom`: where the parts list goes, besides the model.
    bom_path: ?[]const u8 = null,
    /// `--split`: the directory a file per part goes in, instead of one model file.
    split_dir: ?[]const u8 = null,
    /// The values `-p` and `-P` give, in order: the later of two for one parameter wins.
    params: api.ParamValues = .{},

    fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        self.params.deinit(allocator);
    }
};

/// Runs `kupcad build` with the remaining CLI arguments (`args_iter` needs `next() ?[]const u8`).
/// User-facing failures are reported and return `.failure`; unexpected errors propagate.
pub fn run(allocator: std.mem.Allocator, args_iter: anytype, reporter: Reporter) !Outcome {
    var options = try parseOptions(allocator, args_iter, reporter) orelse return .failure;
    defer options.deinit(allocator);

    // A one-shot command: one session is all it needs
    var manager = SessionManager.init(allocator, reporter.io, 1);
    defer manager.deinit();
    const session = try openSession(allocator, &manager, &options, reporter) orelse return .failure;
    if (!try evaluate(allocator, session, options.input_path, reporter)) return .failure;

    const vm = &session.vm;
    const written = if (options.split_dir) |dir|
        try writeSplit(allocator, vm, dir, &options, reporter)
    else
        try writeModel(allocator, vm, &options, reporter);
    if (!written) return .failure;
    if (options.bom_path) |path| {
        if (!try writeBom(allocator, vm, path, reporter)) return .failure;
    }
    return .success;
}

/// The options in `args`, or null, the refusal reported.
fn parseOptions(allocator: std.mem.Allocator, args: anytype, reporter: Reporter) !?Options {
    var options: Options = .{ .input_path = "" };
    errdefer options.deinit(allocator);
    var given = false;
    var explicit_format: ?Format = null;
    while (args.next()) |arg| {
        switch (try param_flags.take(allocator, arg, args, &options.params, reporter)) {
            .taken => continue,
            .refused => return refuse(allocator, &options),
            .other => {},
        }
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            options.output_path = flagValue(args, arg, "output path", reporter) orelse return refuse(allocator, &options);
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--draco")) {
            options.use_draco = true;
        } else if (std.mem.eql(u8, arg, "--mtl")) {
            options.use_mtl = true;
        } else if (std.mem.eql(u8, arg, "--split")) {
            options.split_dir = flagValue(args, arg, "directory", reporter) orelse return refuse(allocator, &options);
        } else if (std.mem.eql(u8, arg, "--bom")) {
            options.bom_path = flagValue(args, arg, "parts list path", reporter) orelse return refuse(allocator, &options);
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            const name = flagValue(args, arg, "format", reporter) orelse return refuse(allocator, &options);
            explicit_format = Format.parse(name) orelse {
                reporter.err("Error: Unsupported format '{s}'. Allowed: {s}\n", .{ name, Format.NAMES });
                return refuse(allocator, &options);
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            reporter.err("Error: Unknown option '{s}'\n\n" ++ USAGE, .{arg});
            return refuse(allocator, &options);
        } else if (given) {
            reporter.err("Error: Expected one input file, got '{s}' and '{s}'\n", .{ options.input_path, arg });
            return refuse(allocator, &options);
        } else {
            options.input_path = arg;
            given = true;
        }
    }
    if (!given) {
        reporter.err("Error: Missing input file path.\n\n" ++ USAGE, .{});
        return refuse(allocator, &options);
    }
    if (!settleFormat(&options, explicit_format, reporter)) return refuse(allocator, &options);
    return options;
}

/// The value after flag `arg`, or null, reported as a missing `what`.
fn flagValue(args: anytype, arg: []const u8, comptime what: []const u8, reporter: Reporter) ?[]const u8 {
    return args.next() orelse {
        reporter.err("Error: Missing " ++ what ++ " after {s}\n", .{arg});
        return null;
    };
}

fn refuse(allocator: std.mem.Allocator, options: *Options) ?Options {
    options.deinit(allocator);
    return null;
}

/// Sets the format `options` write in, from `--format` and the `-o` extension; false, the
/// refusal reported, when they don't make one or the other options don't fit it.
fn settleFormat(options: *Options, explicit: ?Format, reporter: Reporter) bool {
    if (options.split_dir != null and options.output_path != null) {
        reporter.err("Error: --split writes a file per part into its directory; leave out -o\n", .{});
        return false;
    }
    options.format = if (options.split_dir != null)
        explicit orelse DEFAULT_SPLIT_FORMAT
    else
        resolveFormat(explicit, options.output_path, reporter) orelse return false;
    // Draco is a glTF mesh-compression extension; the other exporters would silently drop
    // the request, so refuse it rather than pretend it was applied.
    if (options.use_draco and !options.format.supportsDraco()) {
        reporter.err("Error: --draco only applies to glb and gltf output, not {s}\n", .{@tagName(options.format)});
        return false;
    }
    if (options.use_mtl and !options.format.supportsMaterialLibrary()) {
        reporter.err("Error: --mtl only applies to obj output, not {s}\n", .{@tagName(options.format)});
        return false;
    }
    return true;
}

/// The session the script runs in, set up as `options` and the project ask: the parameter
/// values, the terminal debugger, the project's memory limit (`vm_memory_limit` in
/// .kupcad.json) and, for STEP, the exact B-Rep engine. Null, the failure reported, when it
/// can't be.
fn openSession(allocator: std.mem.Allocator, manager: *SessionManager, options: *Options, reporter: Reporter) !?*ScriptSession {
    const io = reporter.io;
    const session = manager.getOrInitializeSession(options.input_path) catch |err| {
        reporter.err("Failed to initialize session: {}\n", .{err});
        return null;
    };
    session.setParams(&options.params);
    session.vm.debugger_handler = debug.terminalDebugger(io);
    var where: ProjectConfig.Position = .{ .line = 0, .column = 0 };
    const config = ProjectConfig.forScript(io, allocator, options.input_path, &where) catch |err| {
        reporter.err("Error: {s} near {s}:{d}:{d}: {s}\n", .{ CONFIG_FILE_NAME, options.input_path, where.line, where.column, ProjectConfig.describeError(err) });
        return null;
    };
    session.vm.setMemoryLimit(config.vm_memory_limit);
    if (options.format.requiredEngine()) |engine| {
        var settings = session.vm.config();
        settings.engine = engine;
        try session.vm.setConfig(settings);
    }
    return session;
}

/// Runs the script at `input_path` and the modules it imports, dependencies first; false,
/// the errors reported, when one doesn't parse, compile or run.
fn evaluate(allocator: std.mem.Allocator, session: *ScriptSession, input_path: []const u8, reporter: Reporter) !bool {
    const source = try fs.readFileLimit(reporter.io, allocator, input_path, MAX_FILE_SIZE);
    defer allocator.free(source);
    _ = try session.workspace.addModule(input_path, source);
    try session.workspace.linkDependencies();
    try session.buildReverseGraph();
    session.evaluateWorkspace() catch |err| {
        if (err == error.ParseError or err == error.CompileError) if (session.failure) |*failure| {
            try reportErrors(allocator, session, failure, reporter);
            return false;
        };
        reporter.err("Build failed: {}\n", .{err});
        return false;
    };
    return true;
}

/// Writes the model to `-o`, or next to the input named after it; false, the failure
/// reported, when it can't be exported. A failure the script can read about was raised
/// (and reported) by the VM.
fn writeModel(allocator: std.mem.Allocator, vm: *VM, options: *const Options, reporter: Reporter) !bool {
    const extension = options.format.extension();
    const generated = if (options.output_path == null) blk: {
        const stem = std.fs.path.stem(options.input_path);
        const dir = std.fs.path.dirname(options.input_path) orelse break :blk try allocator.print("{s}{s}", .{ stem, extension });
        break :blk try allocator.print("{s}{c}{s}{s}", .{ dir, std.fs.path.sep, stem, extension });
    } else null;
    defer if (generated) |path| allocator.free(path);
    const path = options.output_path orelse generated.?;
    const mtl_path = if (options.use_mtl) try api.materialLibraryPath(allocator, path) else null;
    defer if (mtl_path) |p| allocator.free(p);

    const exporting: api.ExportOptions = .{ .draco = options.use_draco, .mtl_name = if (mtl_path) |p| std.fs.path.basename(p) else null };
    const bytes = api.exportModelFromVm(allocator, vm, options.format, exporting) catch |err| {
        reporter.err("Export failed: {}\n", .{err});
        return false;
    };
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(reporter.io, .{ .sub_path = path, .data = bytes });
    reporter.out("Successfully built {s} ({d} bytes)\n", .{ path, bytes.len });
    if (mtl_path) |p| try writeMaterialLibrary(allocator, vm, p, reporter);
    return true;
}

/// Writes the model's material library (`--mtl`) to `path`.
fn writeMaterialLibrary(allocator: std.mem.Allocator, vm: *const VM, path: []const u8, reporter: Reporter) !void {
    const bytes = try api.exportMaterialLibrary(allocator, vm);
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(reporter.io, .{ .sub_path = path, .data = bytes });
    reporter.out("Wrote {s} ({d} bytes)\n", .{ path, bytes.len });
}

/// Writes the model's parts list to `path` (`--bom`); false, the failure reported, when it
/// can't be made. A part the script can read about (a B-Rep one has no volume yet) was
/// raised by the VM.
fn writeBom(allocator: std.mem.Allocator, vm: *VM, path: []const u8, reporter: Reporter) !bool {
    const parts = api.billOfMaterials(allocator, vm) catch |err| {
        reporter.err("Parts list failed: {}\n", .{err});
        return false;
    };
    defer allocator.free(parts);
    try std.Io.Dir.cwd().writeFile(reporter.io, .{ .sub_path = path, .data = parts });
    reporter.out("Wrote the parts list to {s}\n", .{path});
    return true;
}
