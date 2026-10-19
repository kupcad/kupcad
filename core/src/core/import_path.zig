//! Where an `import` reads its module from. Paths are relative to the project's root: the
//! root of the VFS scripts read through (the current directory for the CLI, the workspace
//! folder in the editor), which also keeps imports inside it.

const std = @import("std");
const builtin = @import("builtin");

/// Where `kupcad pkg` links a project's packages, by alias.
pub const PACKAGE_DIR = ".kupcad/pkg";
/// The file a package import (`import "hardware"`) reads when it names none.
pub const PACKAGE_ENTRY = "main.kup";

/// Packages exist where there is a filesystem `kupcad pkg` installs into; the browser
/// reads an import's path as it is.
const PACKAGES_LINKED = builtin.target.os.tag != .freestanding and builtin.target.os.tag != .wasi;

/// The path `spec` names when the module at `importer` imports it ("" for the main script
/// when its own path is unknown: then the root is its folder). A relative spec (`./x.kup`,
/// `../lib/x.kup`) is joined to the importer's folder: it used to be read from the root,
/// so `kupcad build parts/main.kup` couldn't import its neighbour. An absolute one stays
/// as it is (the VFS refuses it); any other is a package, `hardware` or
/// `hardware/screws.kup`, in PACKAGE_DIR. Caller owns the result.
pub fn resolve(allocator: std.mem.Allocator, importer: []const u8, raw_spec: []const u8) ![]u8 {
    const spec = std.mem.trimEnd(u8, raw_spec, "/"); // `import "hardware/"` is the package
    if (isRelative(spec)) return joinRelative(allocator, importer, spec);
    if (std.fs.path.isAbsolutePosix(spec) or !PACKAGES_LINKED) return allocator.dupe(u8, spec);
    if (std.mem.endsWith(u8, spec, ".kup")) return allocator.print(PACKAGE_DIR ++ "/{s}", .{spec});
    return allocator.print(PACKAGE_DIR ++ "/{s}/" ++ PACKAGE_ENTRY, .{spec});
}

/// The file an import of a file (`import logo from "./logo.stl"`) reads, as `resolve` finds
/// a module's: a relative spec joined to the importer's folder, an absolute one as it is,
/// any other a package's file (`hardware/data.json` is PACKAGE_DIR/hardware/data.json). It
/// was read from the root, so a package's data couldn't be imported by its alias. A call
/// (`import_json("data/m.json")`) reads from the root as written. Caller owns the result.
pub fn resolveFile(allocator: std.mem.Allocator, importer: []const u8, spec: []const u8) ![]u8 {
    if (isRelative(spec)) return joinRelative(allocator, importer, spec);
    if (std.fs.path.isAbsolutePosix(spec) or !PACKAGES_LINKED) return allocator.dupe(u8, spec);
    return allocator.print(PACKAGE_DIR ++ "/{s}", .{spec});
}

fn joinRelative(allocator: std.mem.Allocator, importer: []const u8, spec: []const u8) ![]u8 {
    const folder = std.fs.path.dirnamePosix(importer) orelse return std.fs.path.resolveAllocPosix(allocator, &.{spec});
    return std.fs.path.resolveAllocPosix(allocator, &.{ folder, spec });
}

fn isRelative(spec: []const u8) bool {
    return std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../");
}
