//! Mass properties (docs/architecture.md §7.6): the volume and the area of a body, summed
//! over its shells from the integrals over their faces (`topology/integrals.zig`, the one
//! measure of what a shell encloses, which the checker and `markVoids` take too), and its
//! genus by Euler–Poincaré over every shell, as the mesh engine counts it: `1 − χ/2`.

const std = @import("std");
const diagnostics = @import("../diagnostics.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const integrals = @import("../topology/integrals.zig");
const Body = body_mod.Body;
const Diagnostics = diagnostics.Diagnostics;
const Error = diagnostics.Error;

/// What a body measures: its volume (0 for a sheet), its area (a sheet's is its faces'),
/// and what the quadrature's two rules still differed by, a bound on their error.
pub const Mass = struct {
    volume: f64,
    area: f64,
    volume_error: f64,
    area_error: f64,
};

/// The mass properties of `body`.
pub fn mass(body: *const Body, options: diagnostics.Options, diag: *Diagnostics) Error!Mass {
    try options.checkCancel();
    const place = integrals.placeOf(body);
    var total: integrals.Integrals = .{};
    var shells = traverse.Shells.init(body);
    while (shells.next() catch return corrupt(diag)) |s| {
        const terms = try integrals.shell(body, s, place, options, diag);
        total.volume += terms.volume;
        total.area += terms.area;
        total.volume_error += terms.volume_error;
        total.area_error += terms.area_error;
    }
    return .{
        .volume = if (body.kind == .sheet) 0 else total.volume,
        .area = total.area,
        .volume_error = total.volume_error,
        .area_error = total.area_error,
    };
}

/// The genus of `body` as the mesh engine counts it over every shell at once: `1 − χ/2`
/// for χ the sum of the shells' Euler characteristics (a sphere 0, a torus 1, two
/// spheres −1); a sheet has none and answers 0. Degenerate edges are points of the
/// surface, not edges of the graph.
pub fn genus(body: *const Body, diag: *Diagnostics) Error!i32 {
    if (body.kind == .sheet) return 0;
    var chi: i64 = 0;
    var shells = traverse.Shells.init(body);
    while (shells.next() catch return corrupt(diag)) |s| {
        if (body.shell(s).kind == .sheet) continue;
        chi += shellCharacteristic(body, s) catch return corrupt(diag);
    }
    if (@mod(chi, 2) != 0) return diag.fail(error.NotValid, .{ .code = .euler_poincare, .entity = .of(.body, 0), .measured = @floatFromInt(chi) });
    return @intCast(1 - @divExact(chi, 2));
}

/// `V − E + F − (L − F)` of one shell, its vertices and edges counted once each through
/// its faces.
fn shellCharacteristic(body: *const Body, s: types.ShellIndex) !i64 {
    var faces_n: i64 = 0;
    var loops_n: i64 = 0;
    var vertex_seen = std.AutoHashMapUnmanaged(u32, void).empty;
    defer vertex_seen.deinit(body.allocator);
    var edge_seen = std.AutoHashMapUnmanaged(u32, void).empty;
    defer edge_seen.deinit(body.allocator);
    var faces = traverse.Faces.init(body, s);
    while (try faces.next()) |f| {
        faces_n += 1;
        var loops = traverse.Loops.init(body, f);
        while (try loops.next()) |l| {
            loops_n += 1;
            if (body.loop(l).vertex != .none) try vertex_seen.put(body.allocator, @backingInt(body.loop(l).vertex), {});
            var it = traverse.Coedges.init(body, l);
            while (try it.next()) |c| {
                const e = body.coedge(c).edge;
                if (!body.edge(e).flags.degenerate) try edge_seen.put(body.allocator, @backingInt(e), {});
                try vertex_seen.put(body.allocator, @backingInt(body.coedgeStart(c)), {});
            }
        }
    }
    const v: i64 = @intCast(vertex_seen.count());
    const e: i64 = @intCast(edge_seen.count());
    return v - e + faces_n - (loops_n - faces_n);
}

fn corrupt(diag: *Diagnostics) Error {
    return diag.fail(error.NotValid, .{ .code = .loop_not_closed, .label = "the body" });
}
