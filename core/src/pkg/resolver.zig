const std = @import("std");
const Manifest = @import("manifest.zig").Manifest;
const Lockfile = @import("lockfile.zig").Lockfile;
const provider = @import("providers/provider.zig");
const Cafs = @import("cafs.zig").Cafs;
const Store = @import("store.zig").Store;
const Fetcher = @import("providers/fetcher.zig").Fetcher;
const GithubProvider = @import("providers/github.zig").GithubProvider;
const GitlabProvider = @import("providers/gitlab.zig").GitlabProvider;
const GiteaProvider = @import("providers/gitea.zig").GiteaProvider;
const HttpProvider = @import("providers/http.zig").HttpProvider;
const LocalProvider = @import("providers/local.zig").LocalProvider;

const DepTask = struct {
    alias: []const u8,
    pkg_url: []const u8,
    parent_id: ?[]const u8,
};

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cafs: *Cafs,
    store: *Store,
    manifest: *Manifest,
    lockfile: *Lockfile,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cafs: *Cafs, store: *Store, manifest: *Manifest, lockfile: *Lockfile) Resolver {
        return .{
            .allocator = allocator,
            .io = io,
            .cafs = cafs,
            .store = store,
            .manifest = manifest,
            .lockfile = lockfile,
        };
    }

    pub fn resolve(self: *Resolver) !void {
        var queue: std.ArrayListUnmanaged(DepTask) = .empty;
        defer {
            for (queue.items) |item| {
                self.allocator.free(item.alias);
                self.allocator.free(item.pkg_url);
                if (item.parent_id) |pid| self.allocator.free(pid);
            }
            queue.deinit(self.allocator);
        }

        var manifest_it = self.manifest.dependencies.iterator();
        while (manifest_it.next()) |entry| {
            try queue.append(self.allocator, .{
                .alias = try self.allocator.dupe(u8, entry.key_ptr.*),
                .pkg_url = try self.allocator.dupe(u8, entry.value_ptr.*),
                .parent_id = null,
            });
        }

        var fetcher = Fetcher.init(self.allocator, self.io);
        defer fetcher.deinit();

        var i: usize = 0;
        while (i < queue.items.len) : (i += 1) {
            const task = queue.items[i];
            const parsed = try provider.ParsedPackage.parse(task.pkg_url);

            const pkg_id = try std.fmt.allocPrint(self.allocator, "{s}-{s}-{s}", .{ parsed.domain, parsed.user, parsed.repo });
            defer self.allocator.free(pkg_id);

            var commit_sha: []const u8 = undefined;

            if (self.lockfile.packages.get(pkg_id)) |locked| {
                commit_sha = try self.allocator.dupe(u8, locked.resolved);
            } else {
                commit_sha = try fetcher.fetchCommitSha(parsed);

                var archive_url: []const u8 = undefined;
                switch (parsed.provider) {
                    .github => archive_url = try GithubProvider.formatArchiveUrl(self.allocator, parsed, commit_sha),
                    .gitlab => archive_url = try GitlabProvider.formatArchiveUrl(self.allocator, parsed, commit_sha),
                    .gitea => archive_url = try GiteaProvider.formatArchiveUrl(self.allocator, parsed, commit_sha),
                    .http => archive_url = try HttpProvider.formatArchiveUrl(self.allocator, parsed, commit_sha),
                    .local => archive_url = try LocalProvider.formatArchiveUrl(self.allocator, self.io, parsed, commit_sha),
                }
                defer self.allocator.free(archive_url);

                var extracted_files = try fetcher.downloadArchive(archive_url, self.cafs);
                defer {
                    var ext_it = extracted_files.iterator();
                    while (ext_it.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                        self.allocator.free(entry.value_ptr.*);
                    }
                    extracted_files.deinit();
                }

                try self.store.registerPackage(pkg_id, commit_sha, @tagName(parsed.provider), &extracted_files);

                const new_locked = @import("lockfile.zig").LockedPackage{
                    .resolved = commit_sha,
                    .ref = try self.allocator.dupe(u8, parsed.ref),
                    .dependencies = @import("lockfile.zig").StringMap.init(self.allocator),
                };
                try self.lockfile.packages.put(try self.allocator.dupe(u8, pkg_id), new_locked);
            }

            if (task.parent_id) |parent_id| {
                if (self.lockfile.packages.getPtr(parent_id)) |parent_locked| {
                    try parent_locked.dependencies.put(
                        try self.allocator.dupe(u8, task.alias),
                        try self.allocator.dupe(u8, task.pkg_url),
                    );
                }
            }
        }
    }

    pub fn linkWorkspace(self: *Resolver, fs: @import("../vfs/vfs.zig").Vfs) !void {
        try fs.makePath(".kupcad/pkg/.store");

        var pkg_it = self.lockfile.packages.iterator();
        while (pkg_it.next()) |entry| {
            const pkg_id = entry.key_ptr.*;
            const locked = entry.value_ptr.*;

            const versioned_folder = try std.fmt.allocPrint(self.allocator, ".kupcad/pkg/.store/{s}-{s}/pkg", .{ pkg_id, locked.resolved });
            defer self.allocator.free(versioned_folder);

            try fs.makePath(versioned_folder);

            const query =
                \\SELECT file_path, file_hash FROM package_files
                \\WHERE package_id = ? AND commit_sha = ?
            ;
            var stmt = try self.store.db.prepare(query);
            defer stmt.deinit();

            var rows = try stmt.iterator(struct { file_path: []const u8, file_hash: []const u8 }, .{ pkg_id, locked.resolved });

            while (try rows.next()) |row| {
                const dest_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ versioned_folder, row.file_path });
                defer self.allocator.free(dest_path);

                if (std.fs.path.dirname(dest_path)) |parent_dir| {
                    try fs.makePath(parent_dir);
                }

                try self.cafs.linkBlob(row.file_hash, dest_path);
            }

            if (locked.dependencies.count() > 0) {
                const nested_pkg_dir_path = try std.fmt.allocPrint(self.allocator, ".kupcad/pkg/.store/{s}-{s}/.kupcad/pkg", .{ pkg_id, locked.resolved });
                defer self.allocator.free(nested_pkg_dir_path);
                try fs.makePath(nested_pkg_dir_path);

                var dep_it = locked.dependencies.iterator();
                while (dep_it.next()) |dep_entry| {
                    const dep_alias = dep_entry.key_ptr.*;
                    const dep_url = dep_entry.value_ptr.*;
                    const parsed = try provider.ParsedPackage.parse(dep_url);
                    const dep_pkg_id = try std.fmt.allocPrint(self.allocator, "{s}-{s}-{s}", .{ parsed.domain, parsed.user, parsed.repo });
                    defer self.allocator.free(dep_pkg_id);

                    if (self.lockfile.packages.get(dep_pkg_id)) |dep_locked| {
                        const link_name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ nested_pkg_dir_path, dep_alias });
                        defer self.allocator.free(link_name);

                        const target_path = try std.fmt.allocPrint(self.allocator, "../../../{s}-{s}/pkg", .{ dep_pkg_id, dep_locked.resolved });
                        defer self.allocator.free(target_path);

                        fs.symLink(target_path, link_name) catch {};
                    }
                }
            }
        }

        var manifest_dep_it = self.manifest.dependencies.iterator();
        while (manifest_dep_it.next()) |entry| {
            const alias = entry.key_ptr.*;
            const url = entry.value_ptr.*;
            const parsed = try provider.ParsedPackage.parse(url);
            const pkg_id = try std.fmt.allocPrint(self.allocator, "{s}-{s}-{s}", .{ parsed.domain, parsed.user, parsed.repo });
            defer self.allocator.free(pkg_id);

            if (self.lockfile.packages.get(pkg_id)) |locked| {
                const link_name = try std.fmt.allocPrint(self.allocator, ".kupcad/pkg/{s}", .{alias});
                defer self.allocator.free(link_name);

                const target_path = try std.fmt.allocPrint(self.allocator, ".store/{s}-{s}/pkg", .{ pkg_id, locked.resolved });
                defer self.allocator.free(target_path);

                fs.symLink(target_path, link_name) catch {};
            }
        }
    }
};
