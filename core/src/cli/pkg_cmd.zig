const std = @import("std");
const Doctor = @import("../pkg/health.zig").Doctor;
const Manifest = @import("../pkg/manifest.zig").Manifest;
const Lockfile = @import("../pkg/lockfile.zig").Lockfile;
const Resolver = @import("../pkg/resolver.zig").Resolver;
const Cafs = @import("../pkg/cafs.zig").Cafs;
const Store = @import("../pkg/store.zig").Store;
const GC = @import("../pkg/gc.zig").GarbageCollector;
const ParsedPackage = @import("../pkg/providers/provider.zig").ParsedPackage;
const paths = @import("../pkg/paths.zig");
const log_helpers = @import("../log.zig");
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const validate = @import("../pkg/validate.zig");
const limits = @import("../pkg/limits.zig");

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const command = args_iter.next() orelse {
        log_helpers.printStderr(init.io, "Usage: kupcad pkg <init|add|install|prune|doctor>\n", .{});
        return;
    };

    var native_vfs = NativeVfs.init(init.io, std.Io.Dir.cwd());
    const fs = native_vfs.vfs();

    // -- init --
    if (std.mem.eql(u8, command, "init")) {
        var manifest = Manifest.init(allocator, "new-project");
        defer manifest.deinit();
        try manifest.save(fs);
        log_helpers.printStdout(init.io, "Initialized kupcad.json\n", .{});
        return;
    }

    const global_dir = try paths.getGlobalDir(allocator, init.environ_map);
    defer allocator.free(global_dir);

    var cafs = try Cafs.init(allocator, init.io, global_dir, fs);
    defer cafs.deinit();

    const db_path = try allocator.print("{s}/index.db", .{global_dir});
    defer allocator.free(db_path);
    var store = try Store.init(init.io, db_path);
    defer store.deinit();

    // -- prune --
    if (std.mem.eql(u8, command, "prune")) {
        var gc = GC.init(allocator, init.io, &cafs, &store);
        const force_flag = args_iter.next();
        const force = if (force_flag) |f| std.mem.eql(u8, f, "--force") else false;
        try gc.prune(force);
        return;
    }

    // -- doctor --
    if (std.mem.eql(u8, command, "doctor")) {
        var doc = Doctor.init(allocator, init.io, &cafs, &store);
        try doc.run();
        return;
    }

    var manifest = try Manifest.load(allocator, fs);
    defer manifest.deinit();

    // Load the existing lockfile so installs are pinned to the locked commits and
    // verified against the recorded integrity (missing file -> empty lockfile).
    var lockfile = Lockfile.load(allocator, fs) catch |err| {
        log_helpers.printStderr(init.io, "Error: failed to read kupcad.lock: {s}\n", .{@errorName(err)});
        return err;
    };
    defer lockfile.deinit();

    // -- add --
    if (std.mem.eql(u8, command, "add")) {
        const pkg_arg = args_iter.next() orelse {
            log_helpers.printStderr(init.io, "Usage: kupcad pkg add <alias>=<url>\n", .{});
            return;
        };

        var split_iter = std.mem.splitScalar(u8, pkg_arg, '=');
        const alias = split_iter.next() orelse return error.InvalidSyntax;
        const url = split_iter.rest();
        if (url.len == 0) return error.InvalidSyntax;

        validate.validateAlias(alias) catch |err| {
            log_helpers.printStderr(init.io, "Error: Invalid alias '{s}' (allowed: [A-Za-z0-9_.-], max {d} chars, no leading '.' or '-')\n", .{ alias, limits.MAX_ALIAS_LEN });
            return err;
        };

        // Eagerly validate the URL and print the detected SemVer constraint
        const parsed = ParsedPackage.parse(url) catch |err| {
            log_helpers.printStderr(init.io, "Error: Invalid package URL format '{s}'\n", .{url});
            return err;
        };

        try manifest.dependencies.put(try allocator.dupe(u8, alias), try allocator.dupe(u8, url));
        try manifest.save(fs);

        if (parsed.constraint) |c| {
            log_helpers.printStdout(init.io, "Added {s} with constraint {s}{d}.{d}.{d}. Running concurrent install...\n", .{ alias, @tagName(c.op), c.version.major, c.version.minor, c.version.patch });
        } else {
            log_helpers.printStdout(init.io, "Added {s} at reference '{s}'. Running concurrent install...\n", .{ alias, parsed.ref });
        }
    }

    // -- install -- (or fallthrough from add)
    if (std.mem.eql(u8, command, "install") or std.mem.eql(u8, command, "add")) {
        var resolver = Resolver.init(allocator, init.io, &cafs, &store, &manifest, &lockfile);
        defer resolver.deinit();

        // Any resolution/verification failure aborts before kupcad.lock is rewritten
        // and propagates so the process exits non-zero.
        resolver.resolve() catch |err| {
            log_helpers.printStderr(init.io, "Error: install failed: {s}\n", .{@errorName(err)});
            return err;
        };
        resolver.linkWorkspace(fs) catch |err| {
            log_helpers.printStderr(init.io, "Error: linking workspace failed: {s}\n", .{@errorName(err)});
            return err;
        };

        try lockfile.save(fs);
        log_helpers.printStdout(init.io, "Workspace linked successfully.\n", .{});

        var gc = GC.init(allocator, init.io, &cafs, &store);
        try gc.lazyPrune();
        return;
    }

    log_helpers.printStderr(init.io, "Unknown command: {s}\n", .{command});
}
