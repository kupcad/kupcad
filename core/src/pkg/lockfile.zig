const std = @import("std");
const Vfs = @import("../vfs/vfs.zig").Vfs;

pub const StringMap = std.StringHashMap([]const u8);
pub const PackagesMap = std.StringHashMap(LockedPackage);

const SortUtil = struct {
    pub fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
};

pub const LockedPackage = struct {
    resolved: []const u8,
    ref: []const u8,
    dependencies: StringMap,

    pub fn deinit(self: *LockedPackage, allocator: std.mem.Allocator) void {
        allocator.free(self.resolved);
        allocator.free(self.ref);
        var it = self.dependencies.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.dependencies.deinit();
    }
};

pub const Lockfile = struct {
    allocator: std.mem.Allocator,
    version: []const u8,
    packages: PackagesMap,

    pub fn init(allocator: std.mem.Allocator) Lockfile {
        return .{
            .allocator = allocator,
            .version = allocator.dupe(u8, "1.0.0") catch unreachable,
            .packages = PackagesMap.init(allocator),
        };
    }

    pub fn deinit(self: *Lockfile) void {
        self.allocator.free(self.version);
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

        // Catch parse errors and safely map them to UnexpectedToken as expected by tests
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
            return error.UnexpectedToken;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.UnexpectedToken;

        var lockfile = Lockfile.init(allocator);
        errdefer lockfile.deinit();

        if (root.object.get("version")) |v| {
            if (v == .string) {
                allocator.free(lockfile.version);
                lockfile.version = try allocator.dupe(u8, v.string);
            }
        }

        if (root.object.get("packages")) |pkgs| {
            if (pkgs == .object) {
                var it = pkgs.object.iterator();
                while (it.next()) |entry| {
                    const pkg_id = entry.key_ptr.*;
                    const pkg_val = entry.value_ptr.*;

                    if (pkg_val != .object) continue;

                    var resolved: []const u8 = "";
                    var ref: []const u8 = "";
                    var deps = StringMap.init(allocator);
                    errdefer deps.deinit();

                    if (pkg_val.object.get("resolved")) |r| {
                        if (r == .string) resolved = try allocator.dupe(u8, r.string);
                    }
                    if (pkg_val.object.get("ref")) |r| {
                        if (r == .string) ref = try allocator.dupe(u8, r.string);
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
                        .dependencies = deps,
                    };

                    const key_dupe = try allocator.dupe(u8, pkg_id);
                    try lockfile.packages.put(key_dupe, locked_pkg);
                }
            }
        }

        return lockfile;
    }

    pub fn save(self: *Lockfile, fs: Vfs) !void {
        var out_str: std.ArrayListUnmanaged(u8) = .empty;
        defer out_str.deinit(self.allocator);

        var pkg_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer pkg_keys.deinit(self.allocator);

        var pkg_it = self.packages.keyIterator();
        while (pkg_it.next()) |k| try pkg_keys.append(self.allocator, k.*);
        std.mem.sort([]const u8, pkg_keys.items, {}, SortUtil.lessThan);

        try out_str.appendSlice(self.allocator, "{\n  \"version\": \"");
        try out_str.appendSlice(self.allocator, self.version);
        try out_str.appendSlice(self.allocator, "\",\n  \"packages\": {");

        if (pkg_keys.items.len > 0) {
            try out_str.appendSlice(self.allocator, "\n");
            for (pkg_keys.items, 0..) |pkg_id, i| {
                const locked_pkg = self.packages.get(pkg_id).?;
                const comma1 = if (i < pkg_keys.items.len - 1) "," else "";

                const pkg_header = try std.fmt.allocPrint(self.allocator, "    \"{s}\": {{\n      \"resolved\": \"{s}\",\n      \"ref\": \"{s}\"", .{ pkg_id, locked_pkg.resolved, locked_pkg.ref });
                defer self.allocator.free(pkg_header);
                try out_str.appendSlice(self.allocator, pkg_header);

                if (locked_pkg.dependencies.count() > 0) {
                    try out_str.appendSlice(self.allocator, ",\n      \"dependencies\": {\n");

                    var dep_keys: std.ArrayListUnmanaged([]const u8) = .empty;
                    defer dep_keys.deinit(self.allocator);
                    var dep_it = locked_pkg.dependencies.keyIterator();
                    while (dep_it.next()) |k| try dep_keys.append(self.allocator, k.*);
                    std.mem.sort([]const u8, dep_keys.items, {}, SortUtil.lessThan);

                    for (dep_keys.items, 0..) |dep_key, j| {
                        const dep_val = locked_pkg.dependencies.get(dep_key).?;
                        const comma2 = if (j < dep_keys.items.len - 1) "," else "";
                        const dep_line = try std.fmt.allocPrint(self.allocator, "        \"{s}\": \"{s}\"{s}\n", .{ dep_key, dep_val, comma2 });
                        defer self.allocator.free(dep_line);
                        try out_str.appendSlice(self.allocator, dep_line);
                    }
                    try out_str.appendSlice(self.allocator, "      }\n    }");
                } else {
                    try out_str.appendSlice(self.allocator, "\n    }");
                }

                try out_str.appendSlice(self.allocator, comma1);
                try out_str.appendSlice(self.allocator, "\n");
            }
            try out_str.appendSlice(self.allocator, "  }\n}");
        } else {
            try out_str.appendSlice(self.allocator, "}\n}");
        }

        try fs.writeFile("kupcad.lock", out_str.items);
    }
};
