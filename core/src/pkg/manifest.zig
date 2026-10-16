//! `Manifest`: a project's kupcad.json, its name, version and dependencies (alias to URL),
//! loaded and validated (`load`), changed (`setDependency`), and written back with sorted
//! keys (`save`).

const std = @import("std");
const validate = @import("validate.zig");
const Vfs = @import("../vfs/vfs.zig").Vfs;

const string_map = @import("string_map.zig");
const owned_keys = @import("../core/owned_keys.zig");
pub const StringMap = string_map.StringMap;

const SortUtil = struct {
    pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
};

pub const Manifest = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    dependencies: StringMap,

    /// Creates a new manifest with default values
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Manifest {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, "0.1.0"),
            .dependencies = StringMap.init(allocator),
        };
    }

    pub fn deinit(self: *Manifest) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        string_map.deinitOwned(self.allocator, &self.dependencies);
    }

    /// Loads and parses kupcad.json from disk
    pub fn load(allocator: std.mem.Allocator, fs: Vfs) !Manifest {
        const buffer = fs.readFile(allocator, "kupcad.json") catch |err| switch (err) {
            error.FileNotFound => return error.ManifestNotFound,
            else => return err,
        };
        defer allocator.free(buffer);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, buffer, .{});
        defer parsed.deinit();

        // Validate the shape instead of `.?`/`.object` panicking on hostile input.
        if (parsed.value != .object) return error.InvalidManifest;
        const root = parsed.value.object;
        const name_val = root.get("name") orelse return error.InvalidManifest;
        const version_val = root.get("version") orelse return error.InvalidManifest;
        if (name_val != .string or version_val != .string) return error.InvalidManifest;

        var manifest = Manifest{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name_val.string),
            .version = try allocator.dupe(u8, version_val.string),
            .dependencies = StringMap.init(allocator),
        };
        errdefer manifest.deinit();
        try readDependencies(allocator, root, &manifest.dependencies);
        return manifest;
    }

    /// The `dependencies` of the kupcad.json in `json_bytes` (alias -> URL, owned): what the
    /// resolver reads from a dependency's own manifest, which needn't name a version.
    pub fn parseDependencies(allocator: std.mem.Allocator, json_bytes: []const u8) !StringMap {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch return error.InvalidManifest;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidManifest;
        var deps = StringMap.init(allocator);
        errdefer string_map.deinitOwned(allocator, &deps);
        try readDependencies(allocator, parsed.value.object, &deps);
        return deps;
    }

    /// Adds `root`'s dependencies to `out`. A malformed entry is an error, never skipped, so
    /// a broken dependency tree can't pass for a complete one, and every alias is checked:
    /// it becomes a link name under PACKAGE_DIR.
    fn readDependencies(allocator: std.mem.Allocator, root: std.json.ObjectMap, out: *StringMap) !void {
        const deps_val = root.get("dependencies") orelse return;
        if (deps_val != .object) return error.InvalidManifest;
        var it = deps_val.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) return error.InvalidManifest;
            try validate.validateAlias(entry.key_ptr.*);
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            const val = try allocator.dupe(u8, entry.value_ptr.*.string);
            errdefer allocator.free(val);
            try out.put(key, val);
        }
    }

    /// Records `alias` as depending on `url`, replacing what the alias named before.
    pub fn setDependency(self: *Manifest, alias: []const u8, url: []const u8) !void {
        const url_copy = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(url_copy);
        const gop = try owned_keys.getOrPutOwned(&self.dependencies, self.allocator, alias);
        if (gop.found_existing) self.allocator.free(gop.value_ptr.*);
        gop.value_ptr.* = url_copy;
    }

    /// Saves the current state back to kupcad.json deterministically
    pub fn save(self: *Manifest, fs: Vfs) !void {
        var out_str: std.ArrayListUnmanaged(u8) = .empty;
        defer out_str.deinit(self.allocator);

        // Extract and sort keys for deterministic serialization
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer keys.deinit(self.allocator);

        var key_it = self.dependencies.keyIterator();
        while (key_it.next()) |k| try keys.append(self.allocator, k.*);
        std.mem.sort([]const u8, keys.items, {}, SortUtil.lessThan);

        // All strings are JSON-escaped so a `"` in a name/alias can't inject keys.
        const header = try self.allocator.print("{{\n  \"name\": {f},\n  \"version\": {f},\n  \"dependencies\": {{", .{ std.json.fmt(self.name, .{}), std.json.fmt(self.version, .{}) });
        defer self.allocator.free(header);
        try out_str.appendSlice(self.allocator, header);

        if (keys.items.len > 0) {
            try out_str.appendSlice(self.allocator, "\n");
            for (keys.items, 0..) |k, i| {
                const v = self.dependencies.get(k).?;
                const comma = if (i < keys.items.len - 1) "," else "";
                const line = try self.allocator.print("    {f}: {f}{s}\n", .{ std.json.fmt(k, .{}), std.json.fmt(v, .{}), comma });
                defer self.allocator.free(line);
                try out_str.appendSlice(self.allocator, line);
            }
            try out_str.appendSlice(self.allocator, "  }\n}");
        } else {
            try out_str.appendSlice(self.allocator, "}\n}");
        }

        try fs.writeFile("kupcad.json", out_str.items);
    }
};
