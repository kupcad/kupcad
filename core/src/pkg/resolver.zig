//! `Resolver`: installs a manifest's dependency tree, fetching packages concurrently,
//! verifying them against kupcad.lock, recording their lock entries and dropping stale ones,
//! then links them into the project (`linkWorkspace`).

const std = @import("std");
const owned_keys = @import("../core/owned_keys.zig");
const Manifest = @import("manifest.zig").Manifest;
const lockfile_mod = @import("lockfile.zig");
const Lockfile = lockfile_mod.Lockfile;
const StringMap = lockfile_mod.StringMap;
const provider = @import("providers/provider.zig");
const cafs_mod = @import("cafs.zig");
const Cafs = cafs_mod.Cafs;
const Store = @import("store.zig").Store;
const integrity = @import("integrity.zig");
const Fetcher = @import("providers/fetcher.zig").Fetcher;
const Vfs = @import("../vfs/vfs.zig").Vfs;
const git_host = @import("providers/git_host.zig");
const HttpProvider = @import("providers/http.zig").HttpProvider;
const LocalProvider = @import("providers/local.zig").LocalProvider;
const validate = @import("validate.zig");
const limits = @import("limits.zig");
const string_map = @import("string_map.zig");
const PACKAGE_DIR = @import("../core/import_path.zig").PACKAGE_DIR;

/// Hex chars of the content integrity used as the pseudo-commit of http/local archives.
const CONTENT_COMMIT_LEN = 40;
/// Where installed packages live, by content: PACKAGE_DIR/<alias> links into it.
const STORE_DIR = PACKAGE_DIR ++ "/.store";

const log = std.log.scoped(.pkg);

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cafs: *Cafs,
    store: *Store,
    manifest: *Manifest,
    lockfile: *Lockfile,
    /// One HTTP client for every package: the connections are pooled and the system's
    /// root certificates are loaded once (a client per package loaded them per package).
    fetcher: Fetcher,

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
            .fetcher = Fetcher.init(allocator, io),
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.fetcher.deinit();
        owned_keys.deinit(&self.visited, self.allocator, .borrowed);
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
        var stale: std.ArrayList([]const u8) = .empty;
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
                try string_map.putOwned(self.allocator, &parent_locked.dependencies, alias, pkg_url);
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
        // 1. Commit: pinned by the lockfile, resolved via the provider API, or (for
        //    http/local archives without commits) derived from the content below.
        var commit_sha: ?[]const u8 = null;
        defer if (commit_sha) |c| self.allocator.free(c);
        if (pinned_commit) |c| {
            commit_sha = try self.allocator.dupe(u8, c);
        } else if (parsed.constraint != null) {
            var release = try self.fetcher.resolveRange(parsed);
            defer release.deinit(self.allocator);
            log.info("{s}@{s} resolved to tag {s}", .{ pkg_id, parsed.ref, release.tag });
            commit_sha = try self.allocator.dupe(u8, release.commit);
        } else if (parsed.provider.isGitHost()) {
            commit_sha = try self.fetcher.fetchCommitSha(parsed);
        }

        // 2. Content: offline cache first, network/disk otherwise
        var cached: ?std.StringHashMap([]const u8) = null;
        if (commit_sha) |c| {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            cached = try self.store.getPackageFiles(self.allocator, pkg_id, c);
        }
        var archive: cafs_mod.Archive = if (cached) |files| .{ .files = files, .root = &.{} } else try self.downloadPackage(parsed, commit_sha);
        defer archive.deinit(self.allocator);
        const files = &archive.files;

        // 3. Integrity: must match the lockfile for both cached and fresh content
        const integrity_hash = try integrity.compute(self.allocator, files);
        var integrity_owned = true;
        defer if (integrity_owned) self.allocator.free(integrity_hash);

        if (pinned_commit != null) {
            const expected = pinned_integrity orelse "";
            if (expected.len == 0) {
                log.warn("kupcad.lock entry for {s} has no integrity; refusing to install unverified content", .{pkg_id});
                return error.LockfileMissingIntegrity;
            }
            integrity.verify(self.allocator, files, expected) catch |err| {
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

    fn downloadPackage(self: *Resolver, parsed: provider.ParsedPackage, commit_sha: ?[]const u8) !cafs_mod.Archive {
        switch (parsed.provider) {
            .github, .gitlab, .gitea => {
                const archive_url = try git_host.of(parsed.provider).?.archive_url(self.allocator, parsed, commit_sha.?);
                defer self.allocator.free(archive_url);
                return self.fetcher.downloadArchive(archive_url, self.cafs, parsed.provider.archiveLayout());
            },
            .http => {
                const archive_url = try HttpProvider.formatArchiveUrl(self.allocator, parsed, "");
                defer self.allocator.free(archive_url);
                return self.fetcher.downloadArchive(archive_url, self.cafs, parsed.provider.archiveLayout());
            },
            .local => {
                const path = try LocalProvider.formatArchiveUrl(self.allocator, self.io, parsed, "");
                defer self.allocator.free(path);
                return self.fetcher.openLocalArchive(path, self.cafs);
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

        // Parsed and checked as the project's own manifest is (Manifest.parseDependencies).
        var deps = try Manifest.parseDependencies(self.allocator, json_data);
        defer string_map.deinitOwned(self.allocator, &deps);
        {
            var dep_it = deps.iterator();
            while (dep_it.next()) |dep_entry| {
                const dep_alias = try self.allocator.dupe(u8, dep_entry.key_ptr.*);
                errdefer self.allocator.free(dep_alias);
                const dep_url = try self.allocator.dupe(u8, dep_entry.value_ptr.*);
                errdefer self.allocator.free(dep_url);
                const p_id = try self.allocator.dupe(u8, pkg_id);

                // Fire the transitive dependency into the worker pool immediately
                self.group.async(self.io, resolveWorker, .{ self, dep_alias, dep_url, @as(?[]const u8, p_id) });
            }
        }
    }

    // Linking happens sequentially *after* resolve
    pub fn linkWorkspace(self: *Resolver, fs: Vfs) !void {
        try fs.makePath(STORE_DIR);

        var pkg_it = self.lockfile.packages.iterator();
        while (pkg_it.next()) |entry| {
            const pkg_id = entry.key_ptr.*;
            const locked = entry.value_ptr.*;

            // Both come from kupcad.lock and are joined into filesystem paths.
            try validate.validatePathSegment(pkg_id);
            try validate.validatePathSegment(locked.resolved);

            const versioned_folder = try self.allocator.print(STORE_DIR ++ "/{s}-{s}/pkg", .{ pkg_id, locked.resolved });
            defer self.allocator.free(versioned_folder);

            try fs.makePath(versioned_folder);

            // A locked package missing from the store linked as an empty folder.
            var files = try self.store.getPackageFiles(self.allocator, pkg_id, locked.resolved) orelse return error.PackageNotInStore;
            defer string_map.deinitOwned(self.allocator, &files);

            // Track created directories to minimize redundant VFS syscalls
            var created_dirs: std.StringHashMapUnmanaged(void) = .empty;
            defer owned_keys.deinit(&created_dirs, self.allocator, .borrowed);

            var sanitize_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            var file_it = files.iterator();
            while (file_it.next()) |row| {
                const file_path = row.key_ptr.*;
                // Defense in depth: indexed paths must already be normalized relative paths.
                const clean = try cafs_mod.sanitizeEntryPath(&sanitize_buf, file_path);
                if (!std.mem.eql(u8, clean, file_path)) return error.UnsafeArchivePath;

                const dest_path = try self.allocator.print("{s}/{s}", .{ versioned_folder, file_path });
                defer self.allocator.free(dest_path);

                if (std.fs.path.dirname(dest_path)) |parent_dir| {
                    if (!created_dirs.contains(parent_dir)) {
                        try fs.makePath(parent_dir);
                        try created_dirs.put(self.allocator, try self.allocator.dupe(u8, parent_dir), {});
                    }
                }

                try self.cafs.linkBlob(row.value_ptr.*, dest_path);
            }

            if (locked.dependencies.count() > 0) {
                const nested_pkg_dir_path = try self.allocator.print(STORE_DIR ++ "/{s}-{s}/" ++ PACKAGE_DIR, .{ pkg_id, locked.resolved });
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

                    const dep_locked = self.lockfile.packages.get(dep_pkg_id) orelse return notLocked(dep_alias);
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

        var manifest_dep_it = self.manifest.dependencies.iterator();
        while (manifest_dep_it.next()) |entry| {
            const alias = entry.key_ptr.*;
            const url = entry.value_ptr.*;
            try validate.validateAlias(alias);
            const parsed = try provider.ParsedPackage.parse(url);
            const pkg_id = try parsed.pkgId(self.allocator);
            defer self.allocator.free(pkg_id);

            const locked = self.lockfile.packages.get(pkg_id) orelse return notLocked(alias);
            const link_name = try self.allocator.print(PACKAGE_DIR ++ "/{s}", .{alias});
            defer self.allocator.free(link_name);

            const target_path = try self.allocator.print(".store/{s}-{s}/pkg", .{ pkg_id, locked.resolved });
            defer self.allocator.free(target_path);

            fs.symLink(target_path, link_name) catch |err| {
                log.warn("Failed to link {s} -> {s}: {}", .{ link_name, target_path, err });
                return err;
            };
        }
    }

    /// A dependency resolve should have locked isn't in kupcad.lock: the install fails, as
    /// linking past it left the project without the package (an import of it failed later,
    /// far from the cause).
    fn notLocked(alias: []const u8) error{DependencyNotLocked} {
        log.warn("Dependency '{s}' is not in kupcad.lock, so it can't be linked; run `kupcad pkg install` again", .{alias});
        return error.DependencyNotLocked;
    }
};
