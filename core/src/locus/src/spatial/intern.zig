//! Interning over a geometry arena (docs/architecture.md §5.1): points welded to the first
//! kept point within `zone` through a hashed grid, and lines, circles, planes, cylinders,
//! cones, spheres and tori to the first kept record that is the same geometry
//! (geometry/canonical.zig), each kind through a grid over its key point. "These two
//! faces lie on the same surface" is then an index compare. Ellipses, NURBS and the swept
//! kinds are added as they come: they are made once each, by construction.
//!
//! Every lookup visits a fixed set of cells and takes the least index, so the result is
//! the same whatever the hash map does; the post-condition "no two kept points within
//! zone" holds by construction. A candidate before the first that is the same, which is
//! the zone from the record to within rounding (`canonical.verdict`), is refused
//! (`AtTolerance`, D27): one computation would find it the same and another not.

const std = @import("std");
const vec = @import("../math/vec.zig");
const types = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const surfaces = @import("../geometry/surfaces.zig");
const canonical = @import("../geometry/canonical.zig");
const Geometry = @import("../geometry/arena.zig").Geometry;
const Tolerance = @import("../tolerance.zig").Tolerance;
const grid = @import("grid.zig");
const SCALE_GUARD = @import("../diagnostics.zig").SCALE_GUARD;
const Vec3 = vec.Vec3;
const CurveRef = types.CurveRef;
const SurfaceRef = types.SurfaceRef;
const PointIndex = types.PointIndex;

pub const Error = error{
    OutOfMemory,
    TooMany,
    OutOfRange,
    /// A record the zone from a kept one to within rounding (`Interner.refused` says what
    /// was measured).
    AtTolerance,
};

/// A grid over one kind's key points, with the keys it indexes.
const KeyGrid = struct {
    welder: grid.PointWelder,
    keys: std.ArrayList(Vec3) = .empty,

    fn init(radius: f64, margin: f64) KeyGrid {
        return .{ .welder = grid.PointWelder.initWithMargin(radius, margin) };
    }

    fn deinit(self: *KeyGrid, allocator: std.mem.Allocator) void {
        self.welder.deinit(allocator);
        self.keys.deinit(allocator);
    }

    /// Every kept index whose key is within `reach` of `key`, in ascending order, into
    /// `out`.
    fn candidates(self: *const KeyGrid, allocator: std.mem.Allocator, key: Vec3, reach: f64, out: *std.ArrayList(u32)) Error!void {
        try self.welder.near(allocator, self.keys.items, key, reach, out);
    }

    fn add(self: *KeyGrid, allocator: std.mem.Allocator, key: Vec3) Error!void {
        try self.keys.append(allocator, key);
        errdefer _ = self.keys.pop();
        try self.welder.add(allocator, self.keys.items, @intCast(self.keys.items.len - 1));
    }
};

pub const Interner = struct {
    tol: Tolerance,
    points: grid.PointWelder,
    lines: KeyGrid,
    circles: KeyGrid,
    planes: KeyGrid,
    cylinders: KeyGrid,
    cones: KeyGrid,
    spheres: KeyGrid,
    tori: KeyGrid,
    scratch: std.ArrayList(u32) = .empty,
    /// The point the lines', planes' and axes' keys are taken from (`canonical.lineKey`):
    /// the first point given, so it moves with the model and the keys are the model's size
    /// from it, whatever its distance from the origin.
    at: ?Vec3 = null,
    /// The largest coordinate of any record given: what a comparison's rounding is at most,
    /// so a lookup that reaches the zone and that rounding misses no candidate.
    largest: f64 = 0,
    /// What the last `AtTolerance` measured.
    refused: ?canonical.Comparison = null,

    /// An interner for an empty arena at `tol`: points weld within `zone`, records are
    /// looked up within `zone` of their key.
    pub fn init(tol: Tolerance) Interner {
        const margin = largestBand(tol);
        return .{
            .tol = tol,
            .points = grid.PointWelder.initWithMargin(tol.zone, margin),
            .lines = KeyGrid.init(tol.zone, margin),
            .circles = KeyGrid.init(tol.zone, margin),
            .planes = KeyGrid.init(tol.zone, margin),
            .cylinders = KeyGrid.init(tol.zone, margin),
            .cones = KeyGrid.init(tol.zone, margin),
            .spheres = KeyGrid.init(tol.zone, margin),
            .tori = KeyGrid.init(tol.zone, margin),
        };
    }

    pub fn deinit(self: *Interner, allocator: std.mem.Allocator) void {
        self.points.deinit(allocator);
        inline for (.{ "lines", "circles", "planes", "cylinders", "cones", "spheres", "tori" }) |name| @field(self, name).deinit(allocator);
        self.scratch.deinit(allocator);
        self.* = undefined;
    }

    /// The point keys are taken from, `p` when none was given before.
    fn keyOrigin(self: *Interner, p: Vec3) Vec3 {
        if (self.at == null) self.at = p;
        return self.at.?;
    }

    /// How far a lookup reaches for a record of `points` (and lengths up to `size`): the
    /// zone and the rounding of the largest coordinate seen, these included, at most the
    /// rounding at the largest coordinate the tolerance takes (`largestBand`, what the
    /// grids' cells allow for). A coordinate or length past that is refused (`OutOfRange`,
    /// the scale guard's `too_large_for_tolerance`): its rounding is past what the zone can
    /// decide (keys taken from the model's own point never reach the grid's own limit).
    fn reach(self: *Interner, points: []const Vec3, size: f64) Error!f64 {
        const magnitude = @max(canonical.magnitude(points), size);
        if (!(magnitude <= self.tol.zone / SCALE_GUARD)) return error.OutOfRange;
        self.largest = @max(self.largest, magnitude);
        return self.tol.zone + canonical.Comparison.distance(0, self.tol.zone, self.largest).band;
    }

    /// The first candidate the same, null when none is; a candidate before it at the
    /// tolerance is refused. `verdict(i)` is candidate `i`'s.
    fn first(self: *Interner, context: anytype) Error!?u32 {
        for (self.scratch.items) |i| switch (context.verdict(i)) {
            .same => return i,
            .apart => {},
            .at_tolerance => |c| {
                self.refused = c;
                return error.AtTolerance;
            },
        };
        return null;
    }

    /// The index of `p` in the arena: the first kept point within `zone`, else `p` added.
    pub fn point(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, p: Vec3) Error!PointIndex {
        _ = self.keyOrigin(p);
        try self.points.near(allocator, g.points.items, p, try self.reach(&.{p}, 0), &self.scratch);
        const Points = struct {
            kept: []const Vec3,
            p: Vec3,
            zone: f64,
            fn verdict(c: @This(), i: u32) canonical.Verdict {
                return canonical.verdict(&.{canonical.Comparison.distance(vec.distance(c.kept[i], c.p), c.zone, canonical.magnitude(&.{ c.kept[i], c.p }))});
            }
        };
        if (try self.first(Points{ .kept = g.points.items, .p = p, .zone = self.tol.zone })) |found| return PointIndex.of(found);
        const index = try g.addPoint(allocator, p);
        errdefer _ = g.points.pop();
        try self.points.add(allocator, g.points.items, @backingInt(index));
        return index;
    }

    /// The line `item` through `a` and `b`: a kept line that is the same and holds both
    /// `a` and `b` within `zone`, else `item` added. The same key and direction within
    /// the angle are not enough: two lines through one point a fraction of a degree apart
    /// are one line there and apart further along, so a line is shared only over the
    /// extent that asks for it.
    pub fn line(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, item: curves.Line, a: Vec3, b: Vec3) Error!CurveRef {
        const at = self.keyOrigin(a);
        const key = canonical.lineKey(item, at);
        try self.lines.candidates(allocator, key, try self.reach(&.{ item.o, a, b }, 0), &self.scratch);
        const Lines = struct {
            kept: []const curves.Line,
            item: curves.Line,
            at: Vec3,
            a: Vec3,
            b: Vec3,
            tol: Tolerance,
            fn verdict(c: @This(), i: u32) canonical.Verdict {
                return canonical.verdict(&canonical.sameLine(c.kept[i], c.item, c.at, c.a, c.b, c.tol));
            }
        };
        if (try self.first(Lines{ .kept = g.lines.items, .item = item, .at = at, .a = a, .b = b, .tol = self.tol })) |i| return CurveRef.of(.line, i);
        const ref = try g.addLine(allocator, item);
        errdefer _ = g.lines.pop();
        try self.lines.add(allocator, key);
        return ref;
    }

    pub fn circle(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, item: curves.Circle) Error!CurveRef {
        try self.circles.candidates(allocator, item.c, try self.reach(&.{item.c}, item.r), &self.scratch);
        if (try self.first(Records(curves.Circle, canonical.sameCircle){ .kept = g.circles.items, .item = item, .tol = self.tol })) |i| return CurveRef.of(.circle, i);
        const ref = try g.addCircle(allocator, item);
        errdefer _ = g.circles.pop();
        try self.circles.add(allocator, item.c);
        return ref;
    }

    /// The plane `item` for a face spanning `holds` (its corners): a kept plane that is the
    /// same and holds every one of them within `zone`, else `item` added. A face of known
    /// exact geometry (a cap of a circle, a sketch's plane) may give none.
    pub fn plane(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, item: surfaces.Plane, holds: []const Vec3) Error!SurfaceRef {
        const at = self.keyOrigin(item.frame.origin);
        const key = canonical.planeKey(item, at);
        _ = try self.reach(holds, 0);
        try self.planes.candidates(allocator, key, try self.reach(&.{item.frame.origin}, 0), &self.scratch);
        const Planes = struct {
            kept: []const surfaces.Plane,
            item: surfaces.Plane,
            at: Vec3,
            holds: []const Vec3,
            tol: Tolerance,
            fn verdict(c: @This(), i: u32) canonical.Verdict {
                var tally: canonical.Tally = .{};
                for (canonical.samePlane(c.kept[i], c.item, c.at, c.tol)) |comparison| tally.add(comparison);
                for (c.holds) |p| tally.add(canonical.planeHolds(c.kept[i], p, c.tol));
                return tally.verdict();
            }
        };
        if (try self.first(Planes{ .kept = g.planes.items, .item = item, .at = at, .holds = holds, .tol = self.tol })) |i| return SurfaceRef.of(.plane, i);
        const ref = try g.addPlane(allocator, item);
        errdefer _ = g.planes.pop();
        try self.planes.add(allocator, key);
        return ref;
    }

    pub fn cylinder(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, item: surfaces.Cylinder) Error!SurfaceRef {
        const at = self.keyOrigin(item.frame.origin);
        const key = canonical.axisKey(item.frame, at);
        try self.cylinders.candidates(allocator, key, try self.reach(&.{item.frame.origin}, item.r), &self.scratch);
        if (try self.first(Keyed(surfaces.Cylinder, canonical.sameCylinder){ .kept = g.cylinders.items, .item = item, .at = at, .tol = self.tol })) |i| return SurfaceRef.of(.cylinder, i);
        const ref = try g.addCylinder(allocator, item);
        errdefer _ = g.cylinders.pop();
        try self.cylinders.add(allocator, key);
        return ref;
    }

    pub fn cone(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, item: surfaces.Cone) Error!SurfaceRef {
        try self.cones.candidates(allocator, canonical.coneKey(item), try self.reach(&.{ item.frame.origin, canonical.coneKey(item) }, 0), &self.scratch);
        if (try self.first(Records(surfaces.Cone, canonical.sameCone){ .kept = g.cones.items, .item = item, .tol = self.tol })) |i| return SurfaceRef.of(.cone, i);
        const ref = try g.addCone(allocator, item);
        errdefer _ = g.cones.pop();
        try self.cones.add(allocator, canonical.coneKey(item));
        return ref;
    }

    pub fn sphere(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, item: surfaces.Sphere) Error!SurfaceRef {
        try self.spheres.candidates(allocator, item.frame.origin, try self.reach(&.{item.frame.origin}, item.r), &self.scratch);
        if (try self.first(Records(surfaces.Sphere, canonical.sameSphere){ .kept = g.spheres.items, .item = item, .tol = self.tol })) |i| return SurfaceRef.of(.sphere, i);
        const ref = try g.addSphere(allocator, item);
        errdefer _ = g.spheres.pop();
        try self.spheres.add(allocator, item.frame.origin);
        return ref;
    }

    pub fn torus(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, item: surfaces.Torus) Error!SurfaceRef {
        try self.tori.candidates(allocator, item.frame.origin, try self.reach(&.{item.frame.origin}, item.major + item.minor), &self.scratch);
        if (try self.first(Records(surfaces.Torus, canonical.sameTorus){ .kept = g.tori.items, .item = item, .tol = self.tol })) |i| return SurfaceRef.of(.torus, i);
        const ref = try g.addTorus(allocator, item);
        errdefer _ = g.tori.pop();
        try self.tori.add(allocator, item.frame.origin);
        return ref;
    }
};

/// The rounding of the largest coordinate `tol` takes (`zone / SCALE_GUARD`): how far past
/// the zone a lookup may have to reach.
fn largestBand(tol: Tolerance) f64 {
    return canonical.Comparison.distance(0, tol.zone, tol.zone / SCALE_GUARD).band;
}

/// A lookup's candidates of type `T` compared with `same(kept, item, tol)`.
fn Records(comptime T: type, comptime same: anytype) type {
    return struct {
        kept: []const T,
        item: T,
        tol: Tolerance,
        fn verdict(c: @This(), i: u32) canonical.Verdict {
            return canonical.verdict(&same(c.kept[i], c.item, c.tol));
        }
    };
}

/// A lookup's candidates of type `T` compared with `same(kept, item, at, tol)`, keyed from `at`.
fn Keyed(comptime T: type, comptime same: anytype) type {
    return struct {
        kept: []const T,
        item: T,
        at: Vec3,
        tol: Tolerance,
        fn verdict(c: @This(), i: u32) canonical.Verdict {
            return canonical.verdict(&same(c.kept[i], c.item, c.at, c.tol));
        }
    };
}
