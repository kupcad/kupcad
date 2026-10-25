//! `kupcad pkg`: the package manager's subcommands, `init`, `add`, `install`, `prune` and
//! `doctor`, over kupcad.json, kupcad.lock and the global package store.

const std = @import("std");
const Doctor = @import("../pkg/health.zig").Doctor;
const Manifest = @import("../pkg/manifest.zig").Manifest;
const Lockfile = @import("../pkg/lockfile.zig").Lockfile;
const Resolver = @import("../pkg/resolver.zig").Resolver;
const Cafs = @import("../pkg/cafs.zig").Cafs;
const Store = @import("../pkg/store.zig").Store;
const GC = @import("../pkg/gc.zig").GarbageCollector;
const provider = @import("../pkg/providers/provider.zig");
const ParsedPackage = provider.ParsedPackage;
const paths = @import("../pkg/paths.zig");
const log_helpers = @import("../log.zig");
const NativeVfs = @import("../vfs/native.zig").NativeVfs;
const Vfs = @import("../vfs/vfs.zig").Vfs;
const Reporter = @import("reporter.zig").Reporter;
const validate = @import("../pkg/validate.zig");
const limits = @import("../pkg/limits.zig");

const Outcome = @import("outcome.zig").Outcome;
const Args = @import("args.zig").Args;

const ADD_USAGE = "Usage: kupcad pkg add <alias>=<url>\n";

/// "Usage: kupcad pkg <init|add|install|prune|doctor>", generated from Subcommand, then
/// what each one does.
pub const USAGE = blk: {
    var list: []const u8 = "";
    for (@typeInfo(Subcommand).@"enum".field_names, 0..) |name, i| list = list ++ (if (i == 0) "" else "|") ++ name;
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

const Subcommand = enum { init, add, install, prune, doctor };

/// What `kupcad pkg` was asked to do: the subcommand and its arguments, read whole before
/// anything is opened, so a typo is a usage error rather than another action (`prune
/// --forse` pruned without --force).
pub const Request = union(Subcommand) {
    init,
    add: Dependency,
    install,
    prune: struct { force: bool },
    doctor,
};

/// The request `args` make, or null once what is wrong with them is reported.
pub fn parseRequest(args: *Args, reporter: Reporter) ?Request {
    const name = args.next() orelse {
        reporter.err(USAGE, .{});
        return null;
    };
    const command = std.meta.stringToEnum(Subcommand, name) orelse {
        reporter.err("Error: Unknown pkg command '{s}'\n" ++ USAGE, .{name});
        return null;
    };
    const request: Request = switch (command) {
        .init => .init,
        .install => .install,
        .doctor => .doctor,
        .add => .{ .add = parseDependency(args.next() orelse {
            reporter.err(ADD_USAGE, .{});
            return null;
        }, reporter) orelse return null },
        .prune => .{ .prune = .{ .force = if (args.next()) |flag| force: {
            if (!std.mem.eql(u8, flag, "--force")) return unexpected(reporter, name, flag);
            break :force true;
        } else false } },
    };
    if (args.next()) |extra| return unexpected(reporter, name, extra);
    return request;
}

/// A dependency `add` records: its alias, its URL as written and what the URL names.
pub const Dependency = struct {
    alias: []const u8,
    url: []const u8,
    package: ParsedPackage,
};

/// The dependency `<alias>=<url>` names, or null once what is wrong with it is reported.
fn parseDependency(arg: []const u8, reporter: Reporter) ?Dependency {
    var split_iter = std.mem.splitScalar(u8, arg, '=');
    const alias = split_iter.next() orelse "";
    const url = split_iter.rest();
    if (alias.len == 0 or url.len == 0) {
        reporter.err("Error: Expected <alias>=<url>, got '{s}'\n" ++ ADD_USAGE, .{arg});
        return null;
    }
    validate.validateAlias(alias) catch {
        reporter.err("Error: Invalid alias '{s}' (allowed: [A-Za-z0-9_.-], max {d} chars, no leading '.' or '-')\n", .{ alias, limits.MAX_ALIAS_LEN });
        return null;
    };
    const package = ParsedPackage.parse(url) catch |err| {
        reporter.err("Error: Invalid package URL '{s}': {s}\n", .{ url, provider.describeParseError(err) });
        return null;
    };
    return .{ .alias = alias, .url = url, .package = package };
}

fn unexpected(reporter: Reporter, command: []const u8, arg: []const u8) ?Request {
    reporter.err("Error: Unexpected argument '{s}' for kupcad pkg {s}\n" ++ USAGE, .{ arg, command });
    return null;
}

/// `kupcad pkg init`: a fresh kupcad.json, unless the project has one (it was overwritten,
/// dependencies and all, with exit status 0).
pub fn initManifest(allocator: std.mem.Allocator, fs: Vfs, reporter: Reporter) !Outcome {
    if (fs.readFile(allocator, "kupcad.json")) |existing| {
        allocator.free(existing);
        reporter.err("Error: kupcad.json already exists here; nothing changed. Edit it, or `kupcad pkg add` a dependency.\n", .{});
        return .failure;
    } else |err| if (err != error.FileNotFound) return err;
    var manifest = try Manifest.init(allocator, "new-project");
    defer manifest.deinit();
    try manifest.save(fs);
    reporter.out("Initialized kupcad.json\n", .{});
    return .success;
}

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *Args) !Outcome {
    // Read the request before touching the manifest or the global store, so a typo gets a
    // usage message rather than a manifest error or another action.
    const request = parseRequest(args_iter, .forProcess(init)) orelse return .failure;

    var native_vfs = NativeVfs.init(init.io, std.Io.Dir.cwd());
    const fs = native_vfs.vfs();

    if (request == .init) return initManifest(allocator, fs, .forProcess(init));

    const global_dir = paths.getGlobalDir(allocator, init.environ_map) catch |err| {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.HomeNotFound => log_helpers.printStderr(init.io, "Error: no home folder to keep packages in: set HOME, or KUPCAD_HOME to the folder\n", .{}),
            error.RelativeKupcadHome => log_helpers.printStderr(init.io, "Error: KUPCAD_HOME is '{s}': it must be an absolute path\n", .{init.environ_map.get("KUPCAD_HOME").?}),
        }
        return .failure;
    };
    defer allocator.free(global_dir);

    var cafs = try Cafs.init(allocator, init.io, global_dir, fs);
    defer cafs.deinit();

    const db_path = try allocator.print("{s}/index.db", .{global_dir});
    defer allocator.free(db_path);
    var store = try Store.init(init.io, db_path);
    defer store.deinit();

    switch (request) {
        .init => unreachable, // handled above: needs neither the store nor a manifest
        .prune => |prune| {
            var gc = GC.init(allocator, init.io, &cafs, &store, .{ .io = init.io });
            try gc.prune(prune.force);
            return .success;
        },
        .doctor => {
            var doc = Doctor.init(allocator, init.io, &cafs, &store, .{ .io = init.io });
            try doc.run();
            return .success;
        },
        .add => |dependency| return addOrInstall(init, allocator, dependency, fs, &cafs, &store),
        .install => return addOrInstall(init, allocator, null, fs, &cafs, &store),
    }
}

/// `add` records `added` in kupcad.json and then installs, exactly like `install` (no
/// `added`).
fn addOrInstall(init: std.process.Init, allocator: std.mem.Allocator, added: ?Dependency, fs: Vfs, cafs: *Cafs, store: *Store) !Outcome {
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

    if (added) |dependency| {
        // Saved only once the install succeeds, so a failed `add` leaves kupcad.json as it was.
        try manifest.setDependency(dependency.alias, dependency.url);

        if (dependency.package.constraint != null) {
            log_helpers.printStdout(init.io, "Added {s} at the highest tag matching {s}. Running concurrent install...\n", .{ dependency.alias, dependency.package.ref });
        } else {
            log_helpers.printStdout(init.io, "Added {s} at reference '{s}'. Running concurrent install...\n", .{ dependency.alias, dependency.package.ref });
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

    if (added != null) try manifest.save(fs);
    try lockfile.save(fs);
    log_helpers.printStdout(init.io, "Workspace linked successfully.\n", .{});

    var gc = GC.init(allocator, init.io, cafs, store, .{ .io = init.io });
    try gc.lazyPrune();
    return .success;
}
