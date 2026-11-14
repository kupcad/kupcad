//! A body's parts (KupCAD's `decompose`): each outer shell, with the voids it holds, a body
//! of its own. A void belongs to the innermost outer shell around it (a solid in another's
//! cavity is a part, and so is the one around it with its cavity), as the overlap rules
//! decide it (`overlap.Solids`: by a point strictly inside one of the void's faces, which
//! a vertex is not where a solid touches the void). The mesh engine splits by its mesh's
//! connected components, so a void comes back from it as a part of its own, inside out;
//! here it stays with its solid. Each part is the body with the other shells taken away and
//! compacted, so its faces and edges keep their geometry, tags and attributes. A sheet's
//! shells are its parts too.

const std = @import("std");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const overlap = @import("../query/overlap.zig");
const Body = body_mod.Body;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// The parts of `body`, in the order of their outer shells in its table; owned by `allocator`, each
/// part too. The empty body has none.
pub fn decompose(allocator: std.mem.Allocator, body: *const Body, options: diagnostics.Options, diag: *Diagnostics) Error![]Body {
    try options.checkCancel();
    var solids = try overlap.Solids.init(allocator, body, options, diag);
    defer solids.deinit(allocator);
    var outers: std.ArrayList(types.ShellIndex) = .empty;
    defer outers.deinit(allocator);
    var shells = traverse.Shells.init(body);
    while (shells.next() catch return corrupt(diag)) |s| {
        const owner = solids.owner[@backingInt(s)];
        // A void around no outer shell is no part of any (the overlap rules' `shell_overlaps`)
        if (owner == overlap.NO_SOLID) return diag.fail(error.NotValid, .{ .code = .shell_overlaps, .entity = .of(.shell, @backingInt(s)), .label = "a void inside no outer shell", .threshold = 1 });
        if (owner == @backingInt(s)) try outers.append(allocator, s);
    }
    // In the order of the shells' table, whatever their list's links
    const ByIndex = struct {
        fn lessThan(_: void, x: types.ShellIndex, y: types.ShellIndex) bool {
            return @backingInt(x) < @backingInt(y);
        }
    };
    std.mem.sort(types.ShellIndex, outers.items, {}, ByIndex.lessThan);

    var parts: std.ArrayList(Body) = .empty;
    errdefer {
        for (parts.items) |*p| p.deinit();
        parts.deinit(allocator);
    }
    const keep = try allocator.alloc(bool, body.shells.items.len);
    defer allocator.free(keep);
    for (outers.items) |s| {
        try options.checkCancel();
        for (keep, solids.owner) |*k, owner| k.* = owner == @backingInt(s);
        var part = body.clone(allocator) catch |e| return tooMany(diag, e);
        errdefer part.deinit();
        try keepShells(&part, keep, diag);
        try parts.append(allocator, part);
    }
    return parts.toOwnedSlice(allocator);
}

/// `body` with every shell not in `keep` taken away (its faces, loops, coedges and edges,
/// and the vertices only they used), then compacted.
fn keepShells(body: *Body, keep: []const bool, diag: *Diagnostics) Error!void {
    var shells = traverse.Shells.init(body);
    var gone: std.ArrayList(types.ShellIndex) = .empty;
    defer gone.deinit(body.allocator);
    while (shells.next() catch return corrupt(diag)) |s| {
        if (!keep[@backingInt(s)]) try gone.append(body.allocator, s);
    }
    for (gone.items) |s| {
        var faces = traverse.Faces.init(body, s);
        while (faces.next() catch return corrupt(diag)) |f| {
            var loops = traverse.Loops.init(body, f);
            while (loops.next() catch return corrupt(diag)) |l| {
                var it = traverse.Coedges.init(body, l);
                while (it.next() catch return corrupt(diag)) |c| {
                    body.coedge(c).tombstone = true;
                    body.edge(body.coedge(c).edge).flags.tombstone = true;
                }
                body.loop(l).tombstone = true;
            }
            body.face(f).flags.tombstone = true;
        }
        body.removeShell(s);
        body.shell(s).tombstone = true;
    }
    // The vertices the kept edges and loops no longer reach
    const used = try body.allocator.alloc(bool, body.vertices.items.len);
    defer body.allocator.free(used);
    @memset(used, false);
    for (body.edges.items) |e| {
        if (e.flags.tombstone) continue;
        used[@backingInt(e.start)] = true;
        used[@backingInt(e.end)] = true;
    }
    for (body.loops.items) |l| {
        if (!l.tombstone and l.vertex != .none) used[@backingInt(l.vertex)] = true;
    }
    for (body.vertices.items, used) |*v, u| {
        if (u) continue;
        v.tombstone = true;
    }
    // A kept vertex's coedge may have been one taken away (two shells touching there)
    for (body.coedges.items, 0..) |c, i| {
        if (c.tombstone) continue;
        const start = body.coedgeStart(types.CoedgeIndex.of(i));
        const at = body.vertex(start).coedge;
        if (at == .none or body.coedge(at).tombstone) body.vertex(start).coedge = types.CoedgeIndex.of(i);
    }
    var remap = body.compact() catch |e| return tooMany(diag, e);
    remap.deinit(body.allocator);
}

fn tooMany(diag: *Diagnostics, err: error{ OutOfMemory, TooMany }) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooMany => diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = "entities" }),
    };
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
