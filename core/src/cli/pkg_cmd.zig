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
const Vfs = @import("../vfs/vfs.zig").Vfs;
const validate = @import("../pkg/validate.zig");
const limits = @import("../pkg/limits.zig");

const Outcome = @import("outcome.zig").Outcome;
const Args = @import("args.zig").Args;

const Subcommand = enum { init, add, install, prune, doctor };

const ADD_USAGE = "Usage: kupcad pkg add <alias>=<url>\n";

/// "Usage: kupcad pkg <init|add|install|prune|doctor>", generated from Subcommand, then
/// what each one does.
pub const USAGE = blk: {
    var list: []const u8 = "";
    for (std.meta.fieldNames(Subcommand), 0..) |name, i| list = list ++ (if (i == 0) "" else "|") ++ name;
    break :blk "Usage: kupcad pkg <" ++ list ++ ">\n" ++
        \\
        \\  init               Create kupcad.json in this directory
        \\  add <alias>=<url>  Add a dependency to kupcad.json and install
        \\  install            Install the dependencies, pinned by kupcad.lock
        \\  prune [--force]    Remove packages no project uses from the global store
        \\  doctor             Check the global store for missing or corrupt files
        \\
    ;
};

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    // Validate the subcommand before touching the manifest or the global store, so a typo
    // gets a usage message rather than a manifest error.
    const name = args_iter.next() orelse {
        log_helpers.printStderr(init.io, USAGE, .{});
        return .failure;
    };
    const command = std.meta.stringToEnum(Subcommand, name) orelse {
        log_helpers.printStderr(init.io, "Error: Unknown pkg command '{s}'\n" ++ USAGE, .{name});
        return .failure;
    };

    var native_vfs = NativeVfs.init(init.io, std.Io.Dir.cwd());
    const fs = native_vfs.vfs();

    if (command == .init) {
        var manifest = Manifest.init(allocator, "new-project");
        defer manifest.deinit();
        try manifest.save(fs);
        log_helpers.printStdout(init.io, "Initialized kupcad.json\n", .{});
        return .success;
    }

    const global_dir = try paths.getGlobalDir(allocator, init.environ_map);
    defer allocator.free(global_dir);

    var cafs = try Cafs.init(allocator, init.io, global_dir, fs);
    defer cafs.deinit();

    const db_path = try allocator.print("{s}/index.db", .{global_dir});
    defer allocator.free(db_path);
    var store = try Store.init(init.io, db_path);
    defer store.deinit();

    switch (command) {
        .init => unreachable, // handled above: needs neither the store nor a manifest
        .prune => {
            var gc = GC.init(allocator, init.io, &cafs, &store);
            const force = if (args_iter.next()) |f| std.mem.eql(u8, f, "--force") else false;
            try gc.prune(force);
            return .success;
        },
        .doctor => {
            var doc = Doctor.init(allocator, init.io, &cafs, &store);
            try doc.run();
            return .success;
        },
        .add, .install => return addOrInstall(init, allocator, args_iter, command, fs, &cafs, &store),
    }
}

/// `add` records a dependency in kupcad.json and then installs, exactly like `install`.
fn addOrInstall(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args, command: Subcommand, fs: Vfs, cafs: *Cafs, store: *Store) !Outcome {
    var manifest = Manifest.load(allocator, fs) catch |err| {
        log_helpers.printStderr(init.io, "Error: could not read kupcad.json: {s} (run `kupcad pkg init` to create one)\n", .{@errorName(err)});
        return .failure;
    };
    defer manifest.deinit();

    // Load the existing lockfile so installs are pinned to the locked commits and
    // verified against the recorded integrity (missing file -> empty lockfile).
    var lockfile = Lockfile.load(allocator, fs) catch |err| {
        log_helpers.printStderr(init.io, "Error: failed to read kupcad.lock: {s}\n", .{@errorName(err)});
        return .failure;
    };
    defer lockfile.deinit();

    if (command == .add) {
        const pkg_arg = args_iter.next() orelse {
            log_helpers.printStderr(init.io, ADD_USAGE, .{});
            return .failure;
        };

        var split_iter = std.mem.splitScalar(u8, pkg_arg, '=');
        const alias = split_iter.next() orelse "";
        const url = split_iter.rest();
        if (alias.len == 0 or url.len == 0) {
            log_helpers.printStderr(init.io, "Error: Expected <alias>=<url>, got '{s}'\n" ++ ADD_USAGE, .{pkg_arg});
            return .failure;
        }

        validate.validateAlias(alias) catch {
            log_helpers.printStderr(init.io, "Error: Invalid alias '{s}' (allowed: [A-Za-z0-9_.-], max {d} chars, no leading '.' or '-')\n", .{ alias, limits.MAX_ALIAS_LEN });
            return .failure;
        };

        // Eagerly validate the URL and print the detected SemVer constraint
        const parsed = ParsedPackage.parse(url) catch {
            log_helpers.printStderr(init.io, "Error: Invalid package URL format '{s}'\n", .{url});
            return .failure;
        };

        try manifest.dependencies.put(try allocator.dupe(u8, alias), try allocator.dupe(u8, url));
        try manifest.save(fs);

        if (parsed.constraint) |c| {
            log_helpers.printStdout(init.io, "Added {s} with constraint {s}{d}.{d}.{d}. Running concurrent install...\n", .{ alias, @tagName(c.op), c.version.major, c.version.minor, c.version.patch });
        } else {
            log_helpers.printStdout(init.io, "Added {s} at reference '{s}'. Running concurrent install...\n", .{ alias, parsed.ref });
        }
    }

    var resolver = Resolver.init(allocator, init.io, cafs, store, &manifest, &lockfile);
    defer resolver.deinit();

    // Any resolution/verification failure aborts before kupcad.lock is rewritten.
    resolver.resolve() catch |err| {
        log_helpers.printStderr(init.io, "Error: install failed: {s}\n", .{@errorName(err)});
        return .failure;
    };
    resolver.linkWorkspace(fs) catch |err| {
        log_helpers.printStderr(init.io, "Error: linking workspace failed: {s}\n", .{@errorName(err)});
        return .failure;
    };

    try lockfile.save(fs);
    log_helpers.printStdout(init.io, "Workspace linked successfully.\n", .{});

    var gc = GC.init(allocator, init.io, cafs, store);
    try gc.lazyPrune();
    return .success;
}
