//! `Manifest`: a project's kupcad.json, its name, version and dependencies (alias to URL),
//! loaded and validated (`load`), changed (`setDependency`), and written back (`save`): the
//! dependencies sorted, what it doesn't read (a description, a license) kept as it was.

const std = @import("std");
const validate = @import("validate.zig");
const Vfs = @import("../vfs/vfs.zig").Vfs;

const string_map = @import("string_map.zig");
pub const StringMap = string_map.StringMap;

/// The keys a manifest reads and writes itself, in the order a new one has them.
const OWN_KEYS = [_][]const u8{ "name", "version", "dependencies" };

pub const Manifest = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    dependencies: StringMap,
    /// The file it was loaded from, whose other keys `save` writes back where they were
    file: ?std.json.Parsed(std.json.Value) = null,

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
        if (self.file) |*file| file.deinit();
    }

    /// Loads and parses kupcad.json from disk
    pub fn load(allocator: std.mem.Allocator, fs: Vfs) !Manifest {
        const buffer = fs.readFile(allocator, "kupcad.json") catch |err| switch (err) {
            error.FileNotFound => return error.ManifestNotFound,
            else => return err,
        };
        defer allocator.free(buffer);

        // Kept past the buffer, for its other keys: its strings its own
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, buffer, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();

        // Validate the shape instead of `.?`/`.object` panicking on hostile input.
        if (parsed.value != .object) return error.InvalidManifest;
        const root = parsed.value.object;
        const name_val = root.get("name") orelse return error.InvalidManifest;
        const version_val = root.get("version") orelse return error.InvalidManifest;
        if (name_val != .string or version_val != .string) return error.InvalidManifest;

        const name = try allocator.dupe(u8, name_val.string);
        errdefer allocator.free(name);
        const version = try allocator.dupe(u8, version_val.string);
        errdefer allocator.free(version);
        var dependencies = StringMap.init(allocator);
        errdefer string_map.deinitOwned(allocator, &dependencies);
        try readDependencies(allocator, root, &dependencies);
        return .{ .allocator = allocator, .name = name, .version = version, .dependencies = dependencies, .file = parsed };
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
        try string_map.putOwned(self.allocator, &self.dependencies, alias, url);
    }

    /// Writes it to kupcad.json: the file's keys in its order, each it doesn't read as it
    /// was, then any of its own the file lacked (a new one's name, version and dependencies);
    /// the dependencies sorted by alias, so the file changes as little as it can.
    pub fn save(self: *Manifest, fs: Vfs) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        // Every string JSON-escaped, so a `"` in a name or an alias can't add a key
        var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
        try json.beginObject();
        const kept: ?std.json.ObjectMap = if (self.file) |file| file.value.object else null;
        if (kept) |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                try json.objectField(entry.key_ptr.*);
                if (!try self.writeOwn(&json, entry.key_ptr.*)) try json.write(entry.value_ptr.*);
            }
        }
        for (OWN_KEYS) |key| {
            if (kept) |object| if (object.contains(key)) continue;
            try json.objectField(key);
            _ = try self.writeOwn(&json, key);
        }
        try json.endObject();
        try out.writer.writeByte('\n');
        try fs.writeFile("kupcad.json", out.written());
    }

    /// Writes its value of `key`, if `key` is one of its own (OWN_KEYS): whether it was.
    fn writeOwn(self: *const Manifest, json: *std.json.Stringify, key: []const u8) !bool {
        if (std.mem.eql(u8, key, "name")) {
            try json.write(self.name);
        } else if (std.mem.eql(u8, key, "version")) {
            try json.write(self.version);
        } else if (std.mem.eql(u8, key, "dependencies")) {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(self.allocator);
            var key_it = self.dependencies.keyIterator();
            while (key_it.next()) |k| try keys.append(self.allocator, k.*);
            string_map.sortKeys(keys.items);
            try json.beginObject();
            for (keys.items) |alias| {
                try json.objectField(alias);
                try json.write(self.dependencies.get(alias).?);
            }
            try json.endObject();
        } else return false;
        return true;
    }
};
