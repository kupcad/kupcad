//! Interning over a geometry arena (docs/architecture.md §5.1): points welded to the first
//! kept point within `zone` through a hashed grid, and lines, circles, planes, cylinders,
//! cones, spheres and tori to the first kept record that is the same geometry
//! (geometry/canonical.zig), each kind through a grid over its key point. "These two
//! faces lie on the same surface" is then an index compare. Ellipses, NURBS and the swept
//! kinds are added as they come: they are made once each, by construction.
//!
//! Every lookup visits a fixed set of cells and takes the least index, so the result is
//! the same whatever the hash map does; the post-condition "no two kept points within
//! zone" holds by construction.

const std = @import("std");
const vec = @import("../math/vec.zig");
const types = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const surfaces = @import("../geometry/surfaces.zig");
const canonical = @import("../geometry/canonical.zig");
const Geometry = @import("../geometry/arena.zig").Geometry;
const Tolerance = @import("../tolerance.zig").Tolerance;
const grid = @import("grid.zig");
const Vec3 = vec.Vec3;
const CurveRef = types.CurveRef;
const SurfaceRef = types.SurfaceRef;
const PointIndex = types.PointIndex;

pub const Error = error{ OutOfMemory, TooMany, OutOfRange };

/// A grid over one kind's key points, with the keys it indexes.
const KeyGrid = struct {
    welder: grid.PointWelder,
    keys: std.ArrayList(Vec3) = .empty,

    fn init(radius: f64) KeyGrid {
        return .{ .welder = grid.PointWelder.init(radius) };
    }

    fn deinit(self: *KeyGrid, allocator: std.mem.Allocator) void {
        self.welder.deinit(allocator);
        self.keys.deinit(allocator);
    }

    /// Every kept index whose key is within the radius of `key`, in ascending order, into
    /// `out`.
    const Candidates = struct {
        keys: []const Vec3,
        key: Vec3,
        radius_sq: f64,
        found: *std.ArrayList(u32),
        allocator: std.mem.Allocator,
        failed: bool = false,

        fn visit(self: *Candidates, index: u32) bool {
            if (vec.distanceSq(self.keys[index], self.key) <= self.radius_sq) {
                self.found.append(self.allocator, index) catch {
                    self.failed = true;
                    return false;
                };
            }
            return true;
        }
    };

    fn candidates(self: *const KeyGrid, allocator: std.mem.Allocator, key: Vec3, out: *std.ArrayList(u32)) Error!void {
        out.clearRetainingCapacity();
        var c = Candidates{ .keys = self.keys.items, .key = key, .radius_sq = self.welder.radius * self.welder.radius, .found = out, .allocator = allocator };
        try self.welder.grid.query(key, self.welder.radius, &c, Candidates.visit);
        if (c.failed) return error.OutOfMemory;
        std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
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

    /// An interner for an empty arena at `tol`: points weld within `zone`, records are
    /// looked up within `zone` of their key.
    pub fn init(tol: Tolerance) Interner {
        return .{
            .tol = tol,
            .points = grid.PointWelder.init(tol.zone),
            .lines = KeyGrid.init(tol.zone),
            .circles = KeyGrid.init(tol.zone),
            .planes = KeyGrid.init(tol.zone),
            .cylinders = KeyGrid.init(tol.zone),
            .cones = KeyGrid.init(tol.zone),
            .spheres = KeyGrid.init(tol.zone),
            .tori = KeyGrid.init(tol.zone),
        };
    }

    pub fn deinit(self: *Interner, allocator: std.mem.Allocator) void {
        self.points.deinit(allocator);
        inline for (.{ "lines", "circles", "planes", "cylinders", "cones", "spheres", "tori" }) |name| @field(self, name).deinit(allocator);
        self.scratch.deinit(allocator);
        self.* = undefined;
    }

    /// The index of `p` in the arena: the first kept point within `zone`, else `p` added.
    pub fn point(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, p: Vec3) Error!PointIndex {
        if (try self.points.find(g.points.items, p)) |found| return PointIndex.of(found);
        const index = try g.addPoint(allocator, p);
        errdefer _ = g.points.pop();
        try self.points.add(allocator, g.points.items, @backingInt(index));
        return index;
    }

    pub fn line(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, item: curves.Line) Error!CurveRef {
        try self.lines.candidates(allocator, canonical.lineKey(item), &self.scratch);
        for (self.scratch.items) |i| if (canonical.sameLine(g.lines.items[i], item, self.tol)) return CurveRef.of(.line, i);
        const ref = try g.addLine(allocator, item);
        errdefer _ = g.lines.pop();
        try self.lines.add(allocator, canonical.lineKey(item));
        return ref;
    }

    pub fn circle(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, item: curves.Circle) Error!CurveRef {
        try self.circles.candidates(allocator, item.c, &self.scratch);
        for (self.scratch.items) |i| if (canonical.sameCircle(g.circles.items[i], item, self.tol)) return CurveRef.of(.circle, i);
        const ref = try g.addCircle(allocator, item);
        errdefer _ = g.circles.pop();
        try self.circles.add(allocator, item.c);
        return ref;
    }

    pub fn plane(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, item: surfaces.Plane) Error!SurfaceRef {
        try self.planes.candidates(allocator, canonical.planeKey(item), &self.scratch);
        for (self.scratch.items) |i| if (canonical.samePlane(g.planes.items[i], item, self.tol)) return SurfaceRef.of(.plane, i);
        const ref = try g.addPlane(allocator, item);
        errdefer _ = g.planes.pop();
        try self.planes.add(allocator, canonical.planeKey(item));
        return ref;
    }

    pub fn cylinder(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, item: surfaces.Cylinder) Error!SurfaceRef {
        try self.cylinders.candidates(allocator, canonical.axisKey(item.frame), &self.scratch);
        for (self.scratch.items) |i| if (canonical.sameCylinder(g.cylinders.items[i], item, self.tol)) return SurfaceRef.of(.cylinder, i);
        const ref = try g.addCylinder(allocator, item);
        errdefer _ = g.cylinders.pop();
        try self.cylinders.add(allocator, canonical.axisKey(item.frame));
        return ref;
    }

    pub fn cone(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, item: surfaces.Cone) Error!SurfaceRef {
        try self.cones.candidates(allocator, canonical.coneKey(item), &self.scratch);
        for (self.scratch.items) |i| if (canonical.sameCone(g.cones.items[i], item, self.tol)) return SurfaceRef.of(.cone, i);
        const ref = try g.addCone(allocator, item);
        errdefer _ = g.cones.pop();
        try self.cones.add(allocator, canonical.coneKey(item));
        return ref;
    }

    pub fn sphere(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, item: surfaces.Sphere) Error!SurfaceRef {
        try self.spheres.candidates(allocator, item.frame.origin, &self.scratch);
        for (self.scratch.items) |i| if (canonical.sameSphere(g.spheres.items[i], item, self.tol)) return SurfaceRef.of(.sphere, i);
        const ref = try g.addSphere(allocator, item);
        errdefer _ = g.spheres.pop();
        try self.spheres.add(allocator, item.frame.origin);
        return ref;
    }

    pub fn torus(self: *Interner, allocator: std.mem.Allocator, g: *Geometry, item: surfaces.Torus) Error!SurfaceRef {
        try self.tori.candidates(allocator, item.frame.origin, &self.scratch);
        for (self.scratch.items) |i| if (canonical.sameTorus(g.tori.items[i], item, self.tol)) return SurfaceRef.of(.torus, i);
        const ref = try g.addTorus(allocator, item);
        errdefer _ = g.tori.pop();
        try self.tori.add(allocator, item.frame.origin);
        return ref;
    }
};
