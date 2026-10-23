//! The export options `kupcad build` takes (`-o`, `--format`, `--draco`, `--draco-bits`,
//! `--stroke-width`, `--mtl`, `--bom`, `--split`) and the files they ask for once the
//! script has run: `ExportFlags.take` reads one, `settle` checks they fit together,
//! `requiredEngine` is the engine a format needs the script built on, and `write` writes
//! the model (or a file per part, PartFileNames naming them) and the parts list.

const std = @import("std");
const api = @import("../api.zig");
const parts_mod = @import("../exporters/parts.zig");
const naming = @import("../exporters/names.zig");
const geom = @import("../core/geometry_handle.zig");
const VM = @import("../vm/vm.zig").VM;
const Reporter = @import("reporter.zig").Reporter;
const Taken = @import("param_flags.zig").Taken;

/// Formats an export can write; the tag names are what `--format` accepts.
const Format = api.ExportFormat;

/// Used only when no `-o` is given and no `--format` either.
const DEFAULT_FORMAT: Format = .glb;
/// The format `--split` writes its parts in, without `--format`: what a slicer reads.
const DEFAULT_SPLIT_FORMAT: Format = .stl;
/// The material library the parts of a `--split` share.
const SPLIT_MTL_NAME = "materials.mtl";
const MAX_DRACO_BITS = @import("../exporters/3d/gltf.zig").MAX_DRACO_POSITION_BITS;

/// The options' lines of a command's USAGE.
pub const USAGE =
    \\  -o, --output <file>       Output path; its extension picks the format
    \\                            (
++ Format.EXTENSIONS ++ ")\n" ++
    \\  -f, --format <name>
++ Format.NAMES ++ " (glb when there is no -o)\n" ++
    \\  -d, --draco               Compress glb and gltf meshes with Draco
    \\      --draco-bits <n>      Quantize Draco's positions to n bits, 1 to 30 (14: an
    \\                            error of a part's size / 16384); finer files are larger
    \\      --stroke-width <mm>   An svg's outline width (0.1), e.g. a laser's hairline
    \\      --mtl                 Also write the materials of an obj as a library beside it
    \\                            (<output>.mtl; materials.mtl with --split)
    \\      --bom <file.json>     Also write the model's parts list: each part, how many
    \\                            copies, its volume, size and mass
    \\      --split <dir>         Write each part to its own file in <dir>, as made
    \\                            (not placed), named after it (stl unless -f says)
    \\
;

/// What an export was asked for.
pub const ExportFlags = struct {
    /// `-o`; without it the model goes next to the input, named after it.
    output_path: ?[]const u8 = null,
    /// What the model is written as, once `settle` has picked it.
    format: Format = DEFAULT_FORMAT,
    /// `--format`, when given.
    explicit_format: ?Format = null,
    use_draco: bool = false,
    /// `--draco-bits`, when given.
    draco_bits: ?u8 = null,
    /// `--stroke-width`, when given.
    stroke_width: ?f64 = null,
    /// `--mtl`: an OBJ names its materials, written to a library beside it.
    use_mtl: bool = false,
    /// `--bom`: where the parts list goes, besides the model.
    bom_path: ?[]const u8 = null,
    /// `--split`: the directory a file per part goes in, instead of one model file.
    split_dir: ?[]const u8 = null,

    /// Takes `arg`, and the value after it from `args` (`next() ?[]const u8`), when it is
    /// one of the export options.
    pub fn take(self: *ExportFlags, arg: []const u8, args: anytype, reporter: Reporter) Taken {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            self.output_path = flagValue(args, arg, "output path", reporter) orelse return .refused;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--draco")) {
            self.use_draco = true;
        } else if (std.mem.eql(u8, arg, "--draco-bits")) {
            const text = flagValue(args, arg, "bit count", reporter) orelse return .refused;
            self.draco_bits = std.fmt.parseInt(u8, text, 10) catch null;
            if (self.draco_bits == null or self.draco_bits.? == 0 or self.draco_bits.? > MAX_DRACO_BITS) {
                reporter.err("Error: --draco-bits must be a whole number from 1 to {d}, got '{s}'\n", .{ MAX_DRACO_BITS, text });
                return .refused;
            }
        } else if (std.mem.eql(u8, arg, "--stroke-width")) {
            const text = flagValue(args, arg, "width", reporter) orelse return .refused;
            const width = std.fmt.parseFloat(f64, text) catch std.math.nan(f64);
            if (!(width > 0) or !std.math.isFinite(width)) {
                reporter.err("Error: --stroke-width must be a positive number of millimetres, got '{s}'\n", .{text});
                return .refused;
            }
            self.stroke_width = width;
        } else if (std.mem.eql(u8, arg, "--mtl")) {
            self.use_mtl = true;
        } else if (std.mem.eql(u8, arg, "--split")) {
            self.split_dir = flagValue(args, arg, "directory", reporter) orelse return .refused;
        } else if (std.mem.eql(u8, arg, "--bom")) {
            self.bom_path = flagValue(args, arg, "parts list path", reporter) orelse return .refused;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
            const name = flagValue(args, arg, "format", reporter) orelse return .refused;
            self.explicit_format = Format.parse(name) orelse {
                reporter.err("Error: Unsupported format '{s}'. Allowed: {s}\n", .{ name, Format.NAMES });
                return .refused;
            };
        } else return .other;
        return .taken;
    }

    /// Sets the format the model is written in, from `--format` and the `-o` extension;
    /// false, the refusal reported, when they don't make one or the other options don't
    /// fit it.
    pub fn settle(self: *ExportFlags, reporter: Reporter) bool {
        if (self.split_dir != null and self.output_path != null) {
            reporter.err("Error: --split writes a file per part into its directory; leave out -o\n", .{});
            return false;
        }
        self.format = if (self.split_dir != null)
            self.explicit_format orelse DEFAULT_SPLIT_FORMAT
        else
            resolveFormat(self.explicit_format, self.output_path, reporter) orelse return false;
        // Draco is a glTF mesh-compression extension; the other exporters would silently drop
        // the request, so refuse it rather than pretend it was applied.
        if (self.use_draco and !self.format.supportsDraco()) {
            reporter.err("Error: --draco only applies to glb and gltf output, not {s}\n", .{@tagName(self.format)});
            return false;
        }
        if (self.draco_bits != null and !self.use_draco) {
            reporter.err("Error: --draco-bits sets Draco's precision; add --draco to compress\n", .{});
            return false;
        }
        if (self.stroke_width != null and !self.format.supportsStrokeWidth()) {
            reporter.err("Error: --stroke-width only applies to svg output, not {s}\n", .{@tagName(self.format)});
            return false;
        }
        if (self.use_mtl and !self.format.supportsMaterialLibrary()) {
            reporter.err("Error: --mtl only applies to obj output, not {s}\n", .{@tagName(self.format)});
            return false;
        }
        return true;
    }

    /// The engine the script must be built on for the format (STEP's exact B-Rep), if any.
    pub fn requiredEngine(self: *const ExportFlags) ?geom.EngineType {
        return self.format.requiredEngine();
    }

    /// Writes what was asked for, the model of `vm` (run from `input_path`) or a file per
    /// part, then the parts list; false, the failure reported, when one can't be written.
    pub fn write(self: *const ExportFlags, allocator: std.mem.Allocator, vm: *VM, input_path: []const u8, reporter: Reporter) !bool {
        const written = if (self.split_dir) |dir|
            try self.writeSplit(allocator, vm, dir, reporter)
        else
            try self.writeModel(allocator, vm, input_path, reporter);
        if (!written) return false;
        if (self.bom_path) |path| return writeBom(allocator, vm, path, reporter);
        return true;
    }

    /// How the export is written, the OBJ naming `mtl_name` as its library.
    fn exportOptions(self: *const ExportFlags, mtl_name: ?[]const u8) api.ExportOptions {
        var out: api.ExportOptions = .{ .draco = self.use_draco, .mtl_name = mtl_name };
        if (self.draco_bits) |bits| out.draco_bits = bits;
        if (self.stroke_width) |width| out.stroke_width = width;
        return out;
    }

    /// Writes the model to `-o`, or next to the input named after it; false, the failure
    /// reported, when it can't be exported. A failure the script can read about was raised
    /// (and reported) by the VM.
    fn writeModel(self: *const ExportFlags, allocator: std.mem.Allocator, vm: *VM, input_path: []const u8, reporter: Reporter) !bool {
        const extension = self.format.extension();
        const generated = if (self.output_path == null) blk: {
            const stem = std.fs.path.stem(input_path);
            const dir = std.fs.path.dirname(input_path) orelse break :blk try allocator.print("{s}{s}", .{ stem, extension });
            break :blk try allocator.print("{s}{c}{s}{s}", .{ dir, std.fs.path.sep, stem, extension });
        } else null;
        defer if (generated) |path| allocator.free(path);
        const path = self.output_path orelse generated.?;
        const mtl_path = if (self.use_mtl) try api.materialLibraryPath(allocator, path) else null;
        defer if (mtl_path) |p| allocator.free(p);

        const exporting = self.exportOptions(if (mtl_path) |p| std.fs.path.basename(p) else null);
        const bytes = api.exportModelFromVm(allocator, vm, self.format, exporting) catch |err| {
            reportExportFailure(reporter, err, path);
            return false;
        };
        defer allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(reporter.io, .{ .sub_path = path, .data = bytes });
        reporter.out("Successfully built {s} ({d} bytes)\n", .{ path, bytes.len });
        if (mtl_path) |p| try writeMaterialLibrary(allocator, vm, p, reporter);
        return true;
    }

    /// Writes each part of the model to its own file in `dir` (`--split`), named by
    /// PartFileNames, and with `--mtl` the one library they share; false, the failure
    /// reported, when the model can't be written.
    fn writeSplit(self: *const ExportFlags, allocator: std.mem.Allocator, vm: *VM, dir: []const u8, reporter: Reporter) !bool {
        const exporting = self.exportOptions(if (self.use_mtl) SPLIT_MTL_NAME else null);
        const files = api.exportPartsFromVm(allocator, vm, self.format, exporting) catch |err| {
            reportExportFailure(reporter, err, dir);
            return false;
        };
        defer {
            api.freePartFiles(allocator, files);
            allocator.free(files);
        }
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(reporter.io, dir);
        if (self.use_mtl) {
            const path = try std.fs.path.join(allocator, &.{ dir, SPLIT_MTL_NAME });
            defer allocator.free(path);
            try writeMaterialLibrary(allocator, vm, path, reporter);
        }
        var names: PartFileNames = .{};
        defer names.deinit(allocator);
        // Unnamed files are numbered per kind: part_1, part_2 and path_1 (parts_mod.fallbackName)
        var unnamed = std.EnumArray(parts_mod.ShapeKind, usize).initFill(0);
        for (files) |file| {
            const number = unnamed.getPtr(file.kind);
            if (file.name == null) number.* += 1;
            const name = try names.next(allocator, file.name, file.kind, number.*, self.format.extension()[1..]);
            defer allocator.free(name);
            const path = try std.fs.path.join(allocator, &.{ dir, name });
            defer allocator.free(path);
            try cwd.writeFile(reporter.io, .{ .sub_path = path, .data = file.bytes });
            reporter.out("Wrote {s} ({d} {s})\n", .{ path, file.count, if (file.count == 1) "copy" else "copies" });
        }
        return true;
    }
};

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

/// The value after flag `arg`, or null, reported as a missing `what`.
fn flagValue(args: anytype, arg: []const u8, comptime what: []const u8, reporter: Reporter) ?[]const u8 {
    return args.next() orelse {
        reporter.err("Error: Missing " ++ what ++ " after {s}\n", .{arg});
        return null;
    };
}

/// Why the model wasn't written to `path`: empty (the export's error.NoGeometry), or the
/// error (a script error the VM has already reported is error.RuntimeError).
fn reportExportFailure(reporter: Reporter, err: anyerror, path: []const u8) void {
    if (err == error.NoGeometry) {
        reporter.err("Error: the model is empty, there is nothing to write to '{s}'\n", .{path});
    } else reporter.err("Export failed: {}\n", .{err});
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
    pub fn next(self: *PartFileNames, allocator: std.mem.Allocator, part_name: ?[]const u8, kind: parts_mod.ShapeKind, number: usize, extension: []const u8) ![]u8 {
        const safe = try safeName(allocator, part_name orelse "");
        defer allocator.free(safe);
        const base = if (safe.len > 0) try allocator.dupe(u8, safe) else try parts_mod.fallbackName(allocator, kind, number);
        defer allocator.free(base);
        var copy: usize = 1;
        while (true) : (copy += 1) {
            const stem = try naming.numberedName(allocator, base, copy);
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
