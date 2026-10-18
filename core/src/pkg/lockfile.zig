//! `Lockfile`: reads and writes a project's `kupcad.lock`, the resolved source, ref,
//! integrity and dependencies of every installed package (`LockedPackage`).

const std = @import("std");
const Vfs = @import("../vfs/vfs.zig").Vfs;
const semver = @import("../core/semver.zig");

const log = std.log.scoped(.pkg);

const string_map = @import("string_map.zig");
pub const StringMap = string_map.StringMap;

/// The format this build writes. It reads any version of the same major; another major
/// is refused at load (its integrities would only fail later, as an IntegrityMismatch).
pub const LOCKFILE_VERSION = "1.0.0";
const LOCKFILE_MAJOR = (semver.Version.parse(LOCKFILE_VERSION) catch unreachable).major;

/// JSON-escaped, quoted string formatter.
fn jsonStr(s: []const u8) std.json.Formatter([]const u8) {
    return std.json.fmt(s, .{});
}
pub const PackagesMap = std.StringHashMap(LockedPackage);

pub const LockedPackage = struct {
    resolved: []const u8,
    ref: []const u8,
    integrity: []const u8,
    dependencies: StringMap,

    pub fn deinit(self: *LockedPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.resolved);
        allocator.free(self.ref);
        allocator.free(self.integrity);
        string_map.deinitOwned(allocator, &self.dependencies);
    }
};

pub const Lockfile = struct {
    allocator: std.mem.Allocator,
    packages: PackagesMap,

    pub fn init(allocator: std.mem.Allocator) Lockfile {
        return .{
            .allocator = allocator,
            .packages = PackagesMap.init(allocator),
        };
    }

    pub fn deinit(self: *Lockfile) void {
        var it = self.packages.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.packages.deinit();
    }

    pub fn load(allocator: std.mem.Allocator, fs: Vfs) !Lockfile {
        const content = fs.readFile(allocator, "kupcad.lock") catch |err| switch (err) {
            error.FileNotFound => return Lockfile.init(allocator),
            else => return err,
        };
        defer allocator.free(content);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
            return error.UnexpectedToken;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.UnexpectedToken;

        const version = if (root.object.get("version")) |v| (if (v == .string) v.string else "") else "";
        if (!isSupported(version)) {
            log.warn("kupcad.lock version \"{s}\" is not supported (this kupcad reads {d}.x lockfiles); upgrade kupcad or delete kupcad.lock to re-resolve", .{ version, LOCKFILE_MAJOR });
            return error.UnsupportedLockfileVersion;
        }

        var lockfile = Lockfile.init(allocator);
        errdefer lockfile.deinit();

        if (root.object.get("packages")) |pkgs| {
            if (pkgs == .object) {
                var it = pkgs.object.iterator();
                while (it.next()) |entry| {
                    const pkg_id = entry.key_ptr.*;
                    const pkg_val = entry.value_ptr.*;

                    if (pkg_val != .object) continue;

                    var resolved: []const u8 = "";
                    var ref: []const u8 = "";
                    var integrity: []const u8 = "";
                    var deps = StringMap.init(allocator);
                    errdefer deps.deinit();

                    if (pkg_val.object.get("resolved")) |r| {
                        if (r == .string) resolved = try allocator.dupe(u8, r.string);
                    }
                    if (pkg_val.object.get("ref")) |r| {
                        if (r == .string) ref = try allocator.dupe(u8, r.string);
                    }
                    if (pkg_val.object.get("integrity")) |i| {
                        if (i == .string) integrity = try allocator.dupe(u8, i.string);
                    }

                    if (pkg_val.object.get("dependencies")) |d| {
                        if (d == .object) {
                            var dep_it = d.object.iterator();
                            while (dep_it.next()) |dep_entry| {
                                if (dep_entry.value_ptr.* == .string) {
                                    const d_key = try allocator.dupe(u8, dep_entry.key_ptr.*);
                                    const d_val = try allocator.dupe(u8, dep_entry.value_ptr.*.string);
                                    try deps.put(d_key, d_val);
                                }
                            }
                        }
                    }

                    const locked_pkg = LockedPackage{
                        .resolved = resolved,
                        .ref = ref,
                        .integrity = integrity,
                        .dependencies = deps,
                    };

                    const key_dupe = try allocator.dupe(u8, pkg_id);
                    try lockfile.packages.put(key_dupe, locked_pkg);
                }
            }
        }

        return lockfile;
    }

    fn isSupported(version: []const u8) bool {
        const v = semver.Version.parse(version) catch return false;
        return v.major == LOCKFILE_MAJOR;
    }

    pub fn save(self: *const Lockfile, fs: Vfs) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;

        var pkg_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer pkg_keys.deinit(self.allocator);

        var pkg_it = self.packages.keyIterator();
        while (pkg_it.next()) |k| try pkg_keys.append(self.allocator, k.*);
        string_map.sortKeys(pkg_keys.items);

        // Every string goes through the JSON string encoder: ids, refs and aliases
        // can originate from downloaded manifests, and raw `{s}` interpolation let a
        // `"` in an alias inject arbitrary lockfile entries.
        // Saving always upgrades to the current format (integrities were recomputed by the resolver).
        try w.print("{{\n  \"version\": {f},\n  \"packages\": {{", .{jsonStr(LOCKFILE_VERSION)});

        if (pkg_keys.items.len > 0) {
            try w.writeAll("\n");
            for (pkg_keys.items, 0..) |pkg_id, i| {
                const locked_pkg = self.packages.get(pkg_id).?;
                const comma1 = if (i < pkg_keys.items.len - 1) "," else "";

                try w.print("    {f}: {{\n      \"resolved\": {f},\n      \"ref\": {f},\n      \"integrity\": {f}", .{
                    jsonStr(pkg_id),
                    jsonStr(locked_pkg.resolved),
                    jsonStr(locked_pkg.ref),
                    jsonStr(locked_pkg.integrity),
                });

                if (locked_pkg.dependencies.count() > 0) {
                    try w.writeAll(",\n      \"dependencies\": {\n");

                    var dep_keys: std.ArrayListUnmanaged([]const u8) = .empty;
                    defer dep_keys.deinit(self.allocator);
                    var dep_it = locked_pkg.dependencies.keyIterator();
                    while (dep_it.next()) |k| try dep_keys.append(self.allocator, k.*);
                    string_map.sortKeys(dep_keys.items);

                    for (dep_keys.items, 0..) |dep_key, j| {
                        const dep_val = locked_pkg.dependencies.get(dep_key).?;
                        const comma2 = if (j < dep_keys.items.len - 1) "," else "";
                        try w.print("        {f}: {f}{s}\n", .{ jsonStr(dep_key), jsonStr(dep_val), comma2 });
                    }
                    try w.writeAll("      }\n    }");
                } else {
                    try w.writeAll("\n    }");
                }

                try w.writeAll(comma1);
                try w.writeAll("\n");
            }
            try w.writeAll("  }\n}");
        } else {
            try w.writeAll("}\n}");
        }

        try fs.writeFile("kupcad.lock", aw.written());
    }
};
