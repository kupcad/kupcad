const std = @import("std");

pub const StringMap = std.StringHashMap([]const u8);

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
    pub fn init(allocator: std.mem.Allocator, name: []const u8) Manifest {
        return .{
            .allocator = allocator,
            .name = allocator.dupe(u8, name) catch unreachable,
            .version = allocator.dupe(u8, "0.1.0") catch unreachable,
            .dependencies = StringMap.init(allocator),
        };
    }

    pub fn deinit(self: *Manifest) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        var it = self.dependencies.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.dependencies.deinit();
    }

    /// Loads and parses kupcad.json from disk
    pub fn load(allocator: std.mem.Allocator, fs: @import("../vfs/vfs.zig").Vfs) !Manifest {
        const buffer = fs.readFile(allocator, "kupcad.json") catch |err| switch (err) {
            error.FileNotFound => return error.ManifestNotFound,
            else => return err,
        };
        defer allocator.free(buffer);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, buffer, .{});
        defer parsed.deinit();

        const root = parsed.value.object;

        var manifest = Manifest{
            .allocator = allocator,
            .name = try allocator.dupe(u8, root.get("name").?.string),
            .version = try allocator.dupe(u8, root.get("version").?.string),
            .dependencies = StringMap.init(allocator),
        };

        if (root.get("dependencies")) |deps_val| {
            var it = deps_val.object.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try allocator.dupe(u8, entry.value_ptr.*.string);
                try manifest.dependencies.put(key, val);
            }
        }

        return manifest;
    }

    /// Saves the current state back to kupcad.json deterministically
    pub fn save(self: *Manifest, fs: @import("../vfs/vfs.zig").Vfs) !void {
        var out_str: std.ArrayListUnmanaged(u8) = .empty;
        defer out_str.deinit(self.allocator);

        // Extract and sort keys for deterministic serialization
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer keys.deinit(self.allocator);

        var key_it = self.dependencies.keyIterator();
        while (key_it.next()) |k| try keys.append(self.allocator, k.*);
        std.mem.sort([]const u8, keys.items, {}, SortUtil.lessThan);

        try out_str.appendSlice(self.allocator, "{\n  \"name\": \"");
        try out_str.appendSlice(self.allocator, self.name);
        try out_str.appendSlice(self.allocator, "\",\n  \"version\": \"");
        try out_str.appendSlice(self.allocator, self.version);
        try out_str.appendSlice(self.allocator, "\",\n  \"dependencies\": {");

        if (keys.items.len > 0) {
            try out_str.appendSlice(self.allocator, "\n");
            for (keys.items, 0..) |k, i| {
                const v = self.dependencies.get(k).?;
                const comma = if (i < keys.items.len - 1) "," else "";
                const line = try std.fmt.allocPrint(self.allocator, "    \"{s}\": \"{s}\"{s}\n", .{ k, v, comma });
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
