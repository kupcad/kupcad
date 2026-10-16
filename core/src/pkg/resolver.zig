const std = @import("std");
const Manifest = @import("manifest.zig").Manifest;
const lockfile_mod = @import("lockfile.zig");
const Lockfile = lockfile_mod.Lockfile;
const LockedPackage = lockfile_mod.LockedPackage;
const StringMap = lockfile_mod.StringMap;
const provider = @import("providers/provider.zig");
const cafs_mod = @import("cafs.zig");
const Cafs = cafs_mod.Cafs;
const Store = @import("store.zig").Store;
const Fetcher = @import("providers/fetcher.zig").Fetcher;
const Vfs = @import("../vfs/vfs.zig").Vfs;
const GithubProvider = @import("providers/github.zig").GithubProvider;
const GitlabProvider = @import("providers/gitlab.zig").GitlabProvider;
const GiteaProvider = @import("providers/gitea.zig").GiteaProvider;
const HttpProvider = @import("providers/http.zig").HttpProvider;
const LocalProvider = @import("providers/local.zig").LocalProvider;
const validate = @import("validate.zig");
const limits = @import("limits.zig");

/// Hex chars of the content integrity used as the pseudo-commit of http/local archives.
const CONTENT_COMMIT_LEN = 40;

const log = std.log.scoped(.resolver);

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

    /// Package ids claimed during this run (guarded by `mutex`). Dedupes diamond
    /// dependencies and lets stale lockfile entries be dropped afterwards.
    visited: std.StringHashMapUnmanaged(void) = .empty,
    /// First error hit by any worker (guarded by `mutex`); returned from `resolve`
    /// so a failed install never reports success.
    first_error: ?anyerror = null,

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

    pub fn deinit(self: *Resolver) void {
        var it = self.visited.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.visited.deinit(self.allocator);
    }

    /// Installs the manifest's dependency tree. Returns only once every worker has
    /// finished, on success and on every error, so none outlives the resolver.
    pub fn resolve(self: *Resolver) !void {
        // Checked before anything is spawned: an invalid alias used to return from here
        // while the workers for the aliases before it were still running.
        var alias_it = self.manifest.dependencies.keyIterator();
        while (alias_it.next()) |alias| try validate.validateAlias(alias.*);

        // From the first spawn on, an error (out of memory) still waits for the group.
        errdefer self.group.cancel(self.io);
        var manifest_it = self.manifest.dependencies.iterator();

        // Spawn the initial top-level manifest dependencies into the concurrent worker pool
        while (manifest_it.next()) |entry| {
            const alias = try self.allocator.dupe(u8, entry.key_ptr.*);
            const pkg_url = self.allocator.dupe(u8, entry.value_ptr.*) catch |err| {
                self.allocator.free(alias);
                return err;
            };

            self.group.async(self.io, resolveWorker, .{ self, alias, pkg_url, @as(?[]const u8, null) });
        }

        // Suspend the main task and let the worker pool download the entire tree.
        // It will automatically wake us up when the transitive queue is completely empty.
        try self.group.await(self.io);

        if (self.first_error) |err| return err;

        self.pruneStaleLockEntries();
    }

    fn recordError(self: *Resolver, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.first_error == null) self.first_error = err;
    }

    /// Drops lockfile entries that no longer belong to the dependency graph so they
    /// aren't linked into the workspace or kept pinned forever.
    fn pruneStaleLockEntries(self: *Resolver) void {
        var stale: std.ArrayListUnmanaged([]const u8) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.lockfile.packages.keyIterator();
        while (it.next()) |k| {
            if (!self.visited.contains(k.*)) stale.append(self.allocator, k.*) catch return;
        }
        for (stale.items) |key| {
            if (self.lockfile.packages.fetchRemove(key)) |kv| {
                var value = kv.value;
                value.deinit(self.allocator);
                self.allocator.free(kv.key);
            }
        }
    }

    /// Isolated worker trampoline required by std.Io.Group
    fn resolveWorker(self: *Resolver, alias: []const u8, pkg_url: []const u8, parent_id: ?[]const u8) std.Io.Cancelable!void {
        defer {
            self.allocator.free(alias);
            self.allocator.free(pkg_url);
            if (parent_id) |pid| self.allocator.free(pid);
        }

        self.resolveTask(alias, pkg_url, parent_id) catch |err| {
            log.warn("Error resolving {s}: {any}\n", .{ pkg_url, err });
            self.recordError(err);
        };
    }

    /// The actual concurrent package installation logic
    fn resolveTask(self: *Resolver, alias: []const u8, pkg_url: []const u8, parent_id: ?[]const u8) !void {
        const parsed = try provider.ParsedPackage.parse(pkg_url);
        // A downloaded package may only pull from public git hosts (no file:, raw
        // URLs, loopback or IP literals) to prevent local-file reads and SSRF.
        if (parent_id != null and !parsed.isAllowedTransitive()) return error.ForbiddenTransitiveDependency;

        const pkg_id = try parsed.pkgId(self.allocator);
        defer self.allocator.free(pkg_id);

        var pinned_commit: ?[]const u8 = null;
        var pinned_integrity: ?[]const u8 = null;
        defer if (pinned_commit) |c| self.allocator.free(c);
        defer if (pinned_integrity) |i| self.allocator.free(i);
        var first_visit = false;

        // Claim the package and read its lockfile pin thread-safely
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (!self.visited.contains(pkg_id)) {
                try self.visited.put(self.allocator, try self.allocator.dupe(u8, pkg_id), {});
                first_visit = true;
                if (self.lockfile.packages.get(pkg_id)) |locked| {
                    // The pin only applies to the ref it was resolved from; editing the
                    // ref in kupcad.json is an explicit request to re-resolve.
                    if (locked.resolved.len > 0 and std.mem.eql(u8, locked.ref, parsed.ref)) {
                        pinned_commit = try self.allocator.dupe(u8, locked.resolved);
                        pinned_integrity = try self.allocator.dupe(u8, locked.integrity);
                    }
                }
            }
        }

        if (first_visit) try self.installPackage(parsed, pkg_id, pinned_commit, pinned_integrity);

        // Assign the resolved package as a dependency to the parent module
        if (parent_id) |pid| {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            if (self.lockfile.packages.getPtr(pid)) |parent_locked| {
                const gop = try parent_locked.dependencies.getOrPut(alias);
                if (gop.found_existing) {
                    self.allocator.free(gop.value_ptr.*);
                } else {
                    gop.key_ptr.* = self.allocator.dupe(u8, alias) catch |err| {
                        parent_locked.dependencies.removeByPtr(gop.key_ptr);
                        return err;
                    };
                }
                gop.value_ptr.* = try self.allocator.dupe(u8, pkg_url);
            }
        }
    }

    /// Fetches (or loads from cache) one package, verifies it against the lockfile
    /// pin, registers it and records the new lock entry.
    fn installPackage(
        self: *Resolver,
        parsed: provider.ParsedPackage,
        pkg_id: []const u8,
        pinned_commit: ?[]const u8,
        pinned_integrity: ?[]const u8,
    ) !void {
        var fetcher = Fetcher.init(self.allocator, self.io);
        defer fetcher.deinit();

        // 1. Commit: pinned by the lockfile, resolved via the provider API, or (for
        //    http/local archives without commits) derived from the content below.
        var commit_sha: ?[]const u8 = null;
        defer if (commit_sha) |c| self.allocator.free(c);
        if (pinned_commit) |c| {
            commit_sha = try self.allocator.dupe(u8, c);
        } else if (parsed.constraint != null) {
            var release = try fetcher.resolveRange(parsed);
            defer release.deinit(self.allocator);
            log.info("{s}@{s} resolved to tag {s}", .{ pkg_id, parsed.ref, release.tag });
            commit_sha = try self.allocator.dupe(u8, release.commit);
        } else if (parsed.provider.isGitHost()) {
            commit_sha = try fetcher.fetchCommitSha(parsed);
        }

        // A pin taken before lockfile 3.0.0 hashed a git host archive with its top folder,
        // which only the archive itself still has: it is checked against a fresh download.
        const format = try self.lockfile.format();
        const pinned_wrapped = pinned_commit != null and format.wrapped_git_archives and parsed.provider.archiveLayout() == .wrapped;

        // 2. Content: offline cache first, network/disk otherwise
        var cached: ?std.StringHashMap([]const u8) = null;
        if (commit_sha) |c| if (!pinned_wrapped) {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            cached = try self.store.getPackageFiles(self.allocator, pkg_id, c);
        };
        var archive: cafs_mod.Archive = if (cached) |files| .{ .files = files, .root = &.{} } else try self.downloadPackage(&fetcher, parsed, commit_sha);
        defer archive.deinit(self.allocator);
        const files = &archive.files;

        // 3. Integrity: must match the lockfile for both cached and fresh content
        const integrity_hash = try Store.computeIntegrity(self.allocator, files);
        var integrity_owned = true;
        defer if (integrity_owned) self.allocator.free(integrity_hash);

        if (pinned_commit != null) {
            const expected = pinned_integrity orelse "";
            if (expected.len == 0) {
                log.warn("kupcad.lock entry for {s} has no integrity; refusing to install unverified content", .{pkg_id});
                return error.LockfileMissingIntegrity;
            }
            const scheme: Store.IntegrityScheme = .{
                .algo = if (format.legacy_hash) .legacy else .current,
                .root = if (pinned_wrapped) archive.root else "",
            };
            Store.verifyIntegrity(self.allocator, files, expected, scheme) catch |err| {
                log.warn("Integrity mismatch for {s}@{s}: kupcad.lock expects {s}, got {s}", .{ pkg_id, pinned_commit.?, expected, integrity_hash });
                return err;
            };
        }

        if (commit_sha == null) {
            // http/local archives: content-addressed pseudo-commit
            const hex = integrity_hash["sha256-".len..];
            commit_sha = try self.allocator.dupe(u8, hex[0..CONTENT_COMMIT_LEN]);
        }

        // 4. Register and record the lock entry
        var manifest_hash: ?[]const u8 = null;
        defer if (manifest_hash) |h| self.allocator.free(h);
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);

            try self.store.registerPackage(pkg_id, commit_sha.?, @tagName(parsed.provider), integrity_hash, files);

            const ref_dupe = try self.allocator.dupe(u8, parsed.ref);
            errdefer self.allocator.free(ref_dupe);
            const key_dupe = try self.allocator.dupe(u8, pkg_id);
            errdefer self.allocator.free(key_dupe);

            if (self.lockfile.packages.fetchRemove(pkg_id)) |kv| {
                var old = kv.value;
                old.deinit(self.allocator);
                self.allocator.free(kv.key);
            }
            try self.lockfile.packages.put(key_dupe, .{
                .resolved = commit_sha.?,
                .ref = ref_dupe,
                .integrity = integrity_hash,
                .dependencies = StringMap.init(self.allocator),
            });
            commit_sha = null;
            integrity_owned = false;

            if (files.get("kupcad.json")) |h| manifest_hash = try self.allocator.dupe(u8, h);
        }

        // 5. Transitive dependencies (spawned outside the mutex: `async` may run inline)
        if (manifest_hash) |h| try self.spawnTransitiveDependencies(pkg_id, h);
    }

    fn downloadPackage(self: *Resolver, fetcher: *Fetcher, parsed: provider.ParsedPackage, commit_sha: ?[]const u8) !cafs_mod.Archive {
        switch (parsed.provider) {
            .github, .gitlab, .gitea => {
                const archive_url = switch (parsed.provider) {
                    .github => try GithubProvider.formatArchiveUrl(self.allocator, parsed, commit_sha.?),
                    .gitlab => try GitlabProvider.formatArchiveUrl(self.allocator, parsed, commit_sha.?),
                    else => try GiteaProvider.formatArchiveUrl(self.allocator, parsed, commit_sha.?),
                };
                defer self.allocator.free(archive_url);
                return fetcher.downloadArchive(archive_url, self.cafs, parsed.provider.archiveLayout());
            },
            .http => {
                const archive_url = try HttpProvider.formatArchiveUrl(self.allocator, parsed, "");
                defer self.allocator.free(archive_url);
                return fetcher.downloadArchive(archive_url, self.cafs, parsed.provider.archiveLayout());
            },
            .local => {
                const path = try LocalProvider.formatArchiveUrl(self.allocator, self.io, parsed, "");
                defer self.allocator.free(path);
                return fetcher.openLocalArchive(path, self.cafs);
            },
        }
    }

    /// Reads kupcad.json out of the Content Addressable filesystem to find child dependencies.
    /// Malformed manifests and invalid entries are errors, never silently skipped,
    /// so a broken dependency tree can't masquerade as a successful install.
    fn spawnTransitiveDependencies(self: *Resolver, pkg_id: []const u8, manifest_hash: []const u8) !void {
        // CAFS is trusted and lives outside the project sandbox: read it directly.
        const json_data = try self.cafs.readBlob(self.allocator, manifest_hash, limits.MAX_MANIFEST_BYTES);
        defer self.allocator.free(json_data);

        var parsed_json = std.json.parseFromSlice(std.json.Value, self.allocator, json_data, .{}) catch return error.InvalidManifest;
        defer parsed_json.deinit();

        if (parsed_json.value != .object) return error.InvalidManifest;

        if (parsed_json.value.object.get("dependencies")) |deps| {
            if (deps != .object) return error.InvalidManifest;

            var dep_it = deps.object.iterator();
            while (dep_it.next()) |dep_entry| {
                if (dep_entry.value_ptr.* != .string) return error.InvalidManifest;
                // Alias becomes a symlink name inside the store; never trust it raw.
                try validate.validateAlias(dep_entry.key_ptr.*);

                const dep_alias = try self.allocator.dupe(u8, dep_entry.key_ptr.*);
                errdefer self.allocator.free(dep_alias);
                const dep_url = try self.allocator.dupe(u8, dep_entry.value_ptr.*.string);
                errdefer self.allocator.free(dep_url);
                const p_id = try self.allocator.dupe(u8, pkg_id);

                // Fire the transitive dependency into the worker pool immediately
                self.group.async(self.io, resolveWorker, .{ self, dep_alias, dep_url, @as(?[]const u8, p_id) });
            }
        }
    }

    // Linking happens sequentially *after* resolve
    pub fn linkWorkspace(self: *Resolver, fs: Vfs) !void {
        try fs.makePath(".kupcad/pkg/.store");

        var pkg_it = self.lockfile.packages.iterator();
        while (pkg_it.next()) |entry| {
            const pkg_id = entry.key_ptr.*;
            const locked = entry.value_ptr.*;

            // Both come from kupcad.lock and are joined into filesystem paths.
            try validate.validatePathSegment(pkg_id);
            try validate.validatePathSegment(locked.resolved);

            const versioned_folder = try self.allocator.print(".kupcad/pkg/.store/{s}-{s}/pkg", .{ pkg_id, locked.resolved });
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
            var created_dirs: std.StringHashMapUnmanaged(void) = .empty;
            defer {
                var key_it = created_dirs.keyIterator();
                while (key_it.next()) |k| self.allocator.free(k.*);
                created_dirs.deinit(self.allocator);
            }

            var sanitize_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            while (try rows.next()) |row| {
                // Defense in depth: indexed paths must already be normalized relative paths.
                const clean = try cafs_mod.sanitizeEntryPath(&sanitize_buf, row.file_path);
                if (!std.mem.eql(u8, clean, row.file_path)) return error.UnsafeArchivePath;

                const dest_path = try self.allocator.print("{s}/{s}", .{ versioned_folder, row.file_path });
                defer self.allocator.free(dest_path);

                if (std.fs.path.dirname(dest_path)) |parent_dir| {
                    if (!created_dirs.contains(parent_dir)) {
                        try fs.makePath(parent_dir);
                        try created_dirs.put(self.allocator, try self.allocator.dupe(u8, parent_dir), {});
                    }
                }

                try self.cafs.linkBlob(row.file_hash, dest_path);
            }

            if (locked.dependencies.count() > 0) {
                const nested_pkg_dir_path = try self.allocator.print(".kupcad/pkg/.store/{s}-{s}/.kupcad/pkg", .{ pkg_id, locked.resolved });
                defer self.allocator.free(nested_pkg_dir_path);
                try fs.makePath(nested_pkg_dir_path);

                var dep_it = locked.dependencies.iterator();
                while (dep_it.next()) |dep_entry| {
                    const dep_alias = dep_entry.key_ptr.*;
                    const dep_url = dep_entry.value_ptr.*;
                    // The alias is a symlink name: reject separators, `..`, etc.
                    try validate.validateAlias(dep_alias);
                    const parsed = try provider.ParsedPackage.parse(dep_url);
                    const dep_pkg_id = try parsed.pkgId(self.allocator);
                    defer self.allocator.free(dep_pkg_id);

                    if (self.lockfile.packages.get(dep_pkg_id)) |dep_locked| {
                        const link_name = try self.allocator.print("{s}/{s}", .{ nested_pkg_dir_path, dep_alias });
                        defer self.allocator.free(link_name);

                        const target_path = try self.allocator.print("../../../{s}-{s}/pkg", .{ dep_pkg_id, dep_locked.resolved });
                        defer self.allocator.free(target_path);

                        try validate.validatePathSegment(dep_locked.resolved);
                        fs.symLink(target_path, link_name) catch |err| {
                            log.warn("Failed to link {s} -> {s}: {}", .{ link_name, target_path, err });
                            return err;
                        };
                    }
                }
            }
        }

        var manifest_dep_it = self.manifest.dependencies.iterator();
        while (manifest_dep_it.next()) |entry| {
            const alias = entry.key_ptr.*;
            const url = entry.value_ptr.*;
            try validate.validateAlias(alias);
            const parsed = try provider.ParsedPackage.parse(url);
            const pkg_id = try parsed.pkgId(self.allocator);
            defer self.allocator.free(pkg_id);

            if (self.lockfile.packages.get(pkg_id)) |locked| {
                const link_name = try self.allocator.print(".kupcad/pkg/{s}", .{alias});
                defer self.allocator.free(link_name);

                const target_path = try self.allocator.print(".store/{s}-{s}/pkg", .{ pkg_id, locked.resolved });
                defer self.allocator.free(target_path);

                fs.symLink(target_path, link_name) catch |err| {
                    log.warn("Failed to link {s} -> {s}: {}", .{ link_name, target_path, err });
                    return err;
                };
            } else {
                log.warn("Dependency '{s}' is not in kupcad.lock; skipping link", .{alias});
            }
        }
    }
};
