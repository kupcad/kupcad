const std = @import("std");
const Doctor = @import("../pkg/health.zig").Doctor;
const Manifest = @import("../pkg/manifest.zig").Manifest;
const Lockfile = @import("../pkg/lockfile.zig").Lockfile;
const Resolver = @import("../pkg/resolver.zig").Resolver;
const Cafs = @import("../pkg/cafs.zig").Cafs;
const Store = @import("../pkg/store.zig").Store;
const GC = @import("../pkg/gc.zig").GarbageCollector;
const paths = @import("../pkg/paths.zig");
const NativeVfs = @import("../vfs/native.zig").NativeVfs;

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const command = args_iter.next() orelse {
        std.debug.print("Usage: kupcad pkg <init|add|install|prune|doctor>\n", .{});
        return;
    };

    var native_vfs = NativeVfs.init(init.io);
    const fs = native_vfs.vfs();

    // -- init --
    if (std.mem.eql(u8, command, "init")) {
        var manifest = Manifest.init(allocator, "new-project");
        defer manifest.deinit();
        try manifest.save(fs);
        std.debug.print("Initialized kupcad.json\n", .{});
        return;
    }

    // Pass init.environ_map directly as it is already a pointer
    const global_dir = try paths.getGlobalDir(allocator, init.environ_map);
    defer allocator.free(global_dir);

    var cafs = try Cafs.init(allocator, init.io, global_dir, fs);
    defer cafs.deinit();

    const db_path = try std.fmt.allocPrint(allocator, "{s}/index.db", .{global_dir});
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

    var lockfile = Lockfile.init(allocator);
    defer lockfile.deinit();

    // -- add --
    if (std.mem.eql(u8, command, "add")) {
        const pkg_arg = args_iter.next() orelse {
            std.debug.print("Usage: kupcad pkg add <alias>=<url>\n", .{});
            return;
        };

        var split_iter = std.mem.splitScalar(u8, pkg_arg, '=');
        const alias = split_iter.next() orelse return error.InvalidSyntax;
        const url = split_iter.next() orelse return error.InvalidSyntax;

        try manifest.dependencies.put(try allocator.dupe(u8, alias), try allocator.dupe(u8, url));
        try manifest.save(fs);
        std.debug.print("Added {s} to kupcad.json. Running install...\n", .{alias});
    }

    // -- install -- (or fallthrough from add)
    if (std.mem.eql(u8, command, "install") or std.mem.eql(u8, command, "add")) {
        var resolver = Resolver.init(allocator, init.io, &cafs, &store, &manifest, &lockfile);
        try resolver.resolve();
        try resolver.linkWorkspace(fs);

        try lockfile.save(fs);
        std.debug.print("Workspace linked successfully.\n", .{});

        var gc = GC.init(allocator, init.io, &cafs, &store);
        try gc.lazyPrune();
        return;
    }

    std.debug.print("Unknown command: {s}\n", .{command});
}
