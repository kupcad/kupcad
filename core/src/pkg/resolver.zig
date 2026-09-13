const std = @import("std");
const Manifest = @import("manifest.zig").Manifest;
const lockfile_mod = @import("lockfile.zig");
const Lockfile = lockfile_mod.Lockfile;
const LockedPackage = lockfile_mod.LockedPackage;
const StringMap = lockfile_mod.StringMap;
const provider = @import("providers/provider.zig");
const Cafs = @import("cafs.zig").Cafs;
const Store = @import("store.zig").Store;
const Fetcher = @import("providers/fetcher.zig").Fetcher;
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const Vfs = @import("../vfs/vfs.zig").Vfs;
const GithubProvider = @import("providers/github.zig").GithubProvider;
const GitlabProvider = @import("providers/gitlab.zig").GitlabProvider;
const GiteaProvider = @import("providers/gitea.zig").GiteaProvider;
const HttpProvider = @import("providers/http.zig").HttpProvider;
const LocalProvider = @import("providers/local.zig").LocalProvider;

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cafs: *Cafs,
    store: *Store,
    manifest: *Manifest,
    lockfile: *Lockfile,

    // Concurrency Primitives
    mutex: std.Io.Mutex = .init,
    group: std.Io.Group = .init,

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
        var manifest_it = self.manifest.dependencies.iterator();

        // Spawn the initial top-level manifest dependencies into the concurrent worker pool
        while (manifest_it.next()) |entry| {
            const alias = try self.allocator.dupe(u8, entry.key_ptr.*);
            const pkg_url = try self.allocator.dupe(u8, entry.value_ptr.*);

            try self.group.concurrent(self.io, resolveWorker, .{ self, alias, pkg_url, @as(?[]const u8, null) });
        }

        // Suspend the main task and let the worker pool download the entire tree.
        // It will automatically wake us up when the transitive queue is completely empty.
        try self.group.await(self.io);
    }

    /// Isolated worker trampoline required by std.Io.Group
    fn resolveWorker(self: *Resolver, alias: []const u8, pkg_url: []const u8, parent_id: ?[]const u8) std.Io.Cancelable!void {
        defer {
            self.allocator.free(alias);
            self.allocator.free(pkg_url);
            if (parent_id) |pid| self.allocator.free(pid);
        }

        self.resolveTask(alias, pkg_url, parent_id) catch |err| {
            std.debug.print("Error resolving {s}: {any}\n", .{ pkg_url, err });
        };
    }

    /// The actual concurrent package installation logic
    fn resolveTask(self: *Resolver, alias: []const u8, pkg_url: []const u8, parent_id: ?[]const u8) !void {
        var fetcher = Fetcher.init(self.allocator, self.io);
        defer fetcher.deinit();

        const parsed = try provider.ParsedPackage.parse(pkg_url);
        const pkg_id = try std.fmt.allocPrint(self.allocator, "{s}-{s}-{s}", .{ parsed.domain, parsed.user, parsed.repo });
        defer self.allocator.free(pkg_id);

        var commit_sha: []const u8 = undefined;
        var needs_download = false;

        // Check the lockfile thread-safely
        try self.mutex.lock(self.io);
        if (self.lockfile.packages.get(pkg_id)) |locked| {
            commit_sha = try self.allocator.dupe(u8, locked.resolved);
        } else {
            needs_download = true;
        }
        self.mutex.unlock(self.io);

        // Download the package completely detached from the mutex so other threads can keep working
        if (needs_download) {
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

            const integrity_hash = try Store.computeIntegrity(self.allocator, &extracted_files);

            // Re-acquire lock to write the results
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            // Double-checked locking pattern: ensure another worker thread didn't beat us to it
            if (!self.lockfile.packages.contains(pkg_id)) {
                try self.store.registerPackage(pkg_id, commit_sha, @tagName(parsed.provider), integrity_hash, &extracted_files);

                const new_locked = LockedPackage{
                    .resolved = commit_sha,
                    .ref = try self.allocator.dupe(u8, parsed.ref),
                    .integrity = integrity_hash,
                    .dependencies = StringMap.init(self.allocator),
                };
                try self.lockfile.packages.put(try self.allocator.dupe(u8, pkg_id), new_locked);

                // Dynamically extract transitive dependencies from the newly downloaded kupcad.json
                if (extracted_files.get("kupcad.json")) |manifest_hash| {
                    try self.spawnTransitiveDependencies(pkg_id, manifest_hash);
                }
            } else {
                self.allocator.free(commit_sha);
                self.allocator.free(integrity_hash);
            }
        }

        // Assign the resolved package as a dependency to the parent module
        if (parent_id) |pid| {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            if (self.lockfile.packages.getPtr(pid)) |parent_locked| {
                try parent_locked.dependencies.put(
                    try self.allocator.dupe(u8, alias),
                    try self.allocator.dupe(u8, pkg_url),
                );
            }
        }
    }

    /// Reads kupcad.json out of the Content Addressable filesystem to find child dependencies
    fn spawnTransitiveDependencies(self: *Resolver, pkg_id: []const u8, manifest_hash: []const u8) !void {
        const manifest_path = try self.cafs.blobPath(manifest_hash);
        defer self.allocator.free(manifest_path);

        // Fix: Store NativeVfs in a variable so we can take a mutable pointer to it
        var native_vfs = NativeVfs.init(self.io, std.Io.Dir.cwd());
        const fs = native_vfs.vfs();

        const json_data = fs.readFile(self.allocator, manifest_path) catch return;
        defer self.allocator.free(json_data);

        var parsed_json = std.json.parseFromSlice(std.json.Value, self.allocator, json_data, .{}) catch return;
        defer parsed_json.deinit();

        if (parsed_json.value != .object) return;

        if (parsed_json.value.object.get("dependencies")) |deps| {
            if (deps != .object) return;

            var dep_it = deps.object.iterator();
            while (dep_it.next()) |dep_entry| {
                if (dep_entry.value_ptr.* != .string) continue;

                const dep_alias = try self.allocator.dupe(u8, dep_entry.key_ptr.*);
                const dep_url = try self.allocator.dupe(u8, dep_entry.value_ptr.*.string);
                const p_id = try self.allocator.dupe(u8, pkg_id);

                // Fire the transitive dependency into the worker pool immediately
                try self.group.concurrent(self.io, resolveWorker, .{ self, dep_alias, dep_url, p_id });
            }
        }
    }

    // Keep linkWorkspace exactly as it was, since linking happens sequentially *after* resolve
    pub fn linkWorkspace(self: *Resolver, fs: Vfs) !void {
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

            // Track created directories to minimize redundant VFS syscalls
            var created_dirs = std.StringHashMap(void).init(self.allocator);
            defer {
                var key_it = created_dirs.keyIterator();
                while (key_it.next()) |k| self.allocator.free(k.*);
                created_dirs.deinit();
            }

            while (try rows.next()) |row| {
                const dest_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ versioned_folder, row.file_path });
                defer self.allocator.free(dest_path);

                if (std.fs.path.dirname(dest_path)) |parent_dir| {
                    if (!created_dirs.contains(parent_dir)) {
                        try fs.makePath(parent_dir);
                        try created_dirs.put(try self.allocator.dupe(u8, parent_dir), {});
                    }
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
