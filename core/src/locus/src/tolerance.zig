//! What "close enough" means for a body (`Tolerance`, docs/architecture.md §6: one per
//! body, never a hard-coded epsilon anywhere else) and how finely a curve is cut into
//! straight edges (`Resolution`), which KupCAD imports so that both of its engines cut a
//! circle into the same polygon (§7.7, §9.3).

const std = @import("std");

/// Fewest straight edges an automatically resolved circle gets.
const MIN_AUTO_SEGMENTS: u32 = 5;

/// `angle`, as `1 − cos`: directions within about 0.8° are the same. Never scaled with the
/// model, since directions have no size (§6).
const ANGLE: f64 = 1e-4;
/// How much smaller than `zone` a `fromSize` model's zone can get: 0.01–1 mm models.
const SMALLEST_ZONE: f64 = 1e-6;
/// The largest zone the decade table gives (models of 1e4–1e6 mm).
const LARGEST_ZONE: f64 = 1e-3;
/// The zone a 1–100 mm model gets, and the host's usual `tolerance`.
const DEFAULT_ZONE: f64 = 1e-5;

/// The tolerances of one body (SMLib's scheme, §6). `zone` is the radius of every vertex's
/// and edge's tolerant neighbourhood; `xsect` the distance at which two things meet, and
/// the least at which two points are distinct; `approx` bounds every approximation (pcurves,
/// marched curves); `angle` compares directions as `1 − cos` and never scales; `param` is a
/// relative parametric tolerance. Make one with `fromZone` (the host's `tolerance`) or
/// `fromSize`; `merge` for an operation on two bodies.
pub const Tolerance = struct {
    zone: f64,
    xsect: f64,
    approx: f64,
    angle: f64 = ANGLE,
    param: f64,

    /// From the host's distance tolerance (`zone`), the rest in its proportions:
    /// `xsect = 2·zone`, `approx = zone / 2`, `param = zone`. `zone` must be finite and
    /// positive.
    pub fn fromZone(zone: f64) Tolerance {
        return .{ .zone = zone, .xsect = 2.0 * zone, .approx = zone / 2.0, .param = zone };
    }

    /// From the model's size (its largest extent, mm), by SMLib's decade table: 1e-6 under a
    /// millimetre, 1e-5 up to 100 mm, 1e-4 up to 10 m, 1e-3 beyond.
    pub fn fromSize(extent: f64) Tolerance {
        const zone: f64 = if (!(extent >= 1.0))
            SMALLEST_ZONE
        else if (extent < 100.0)
            DEFAULT_ZONE
        else if (extent < 10_000.0)
            DEFAULT_ZONE * 10.0
        else
            LARGEST_ZONE;
        return fromZone(zone);
    }

    /// The tolerance of a body scaled by `k` (its absolute value): the lengths (`zone`,
    /// `xsect`, `approx`) scaled with it, as OCCT's BRepTools_TrsfModification scales every
    /// tolerance of a shape with its scale factor, so that every relation the body held
    /// holds at the scale. `angle` has no size, and `param` is relative (the sweeps compare
    /// it with angles): both kept.
    pub fn scaled(self: Tolerance, k: f64) Tolerance {
        const a = @abs(k);
        return .{ .zone = self.zone * a, .xsect = self.xsect * a, .approx = self.approx * a, .angle = self.angle, .param = self.param };
    }

    /// The tolerance of an operation on two bodies: the looser of each field.
    pub fn merge(a: Tolerance, b: Tolerance) Tolerance {
        return .{
            .zone = @max(a.zone, b.zone),
            .xsect = @max(a.xsect, b.xsect),
            .approx = @max(a.approx, b.approx),
            .angle = @max(a.angle, b.angle),
            .param = @max(a.param, b.param),
        };
    }

    /// Whether every field is finite and positive, and `xsect` is at least `zone`: what an
    /// operation requires of the tolerance it is given.
    pub fn isValid(self: Tolerance) bool {
        inline for (.{ self.zone, self.xsect, self.approx, self.angle, self.param }) |v| {
            if (!(v > 0.0) or !(v - v == 0)) return false;
        }
        return self.xsect >= self.zone;
    }

    /// Whether two points are the same point: within `zone` of each other.
    pub fn samePoint(self: Tolerance, a: [3]f64, b: [3]f64) bool {
        const dx = a[0] - b[0];
        const dy = a[1] - b[1];
        const dz = a[2] - b[2];
        return dx * dx + dy * dy + dz * dz <= self.zone * self.zone;
    }

    /// Whether two things at distance `d` meet: within `xsect`.
    pub fn meets(self: Tolerance, d: f64) bool {
        return d <= self.xsect;
    }

    /// Whether two unit directions are the same direction (not merely parallel): their
    /// cosine within `angle` of 1.
    pub fn sameDirection(self: Tolerance, a: [3]f64, b: [3]f64) bool {
        return 1.0 - (a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) <= self.angle;
    }

    /// Whether two unit directions are parallel, either way round.
    pub fn parallel(self: Tolerance, a: [3]f64, b: [3]f64) bool {
        return 1.0 - @abs(a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) <= self.angle;
    }

    /// The sine of the angular tolerance: a direction within `angle` of another leaves it
    /// by at most this much per unit along it.
    pub fn angleSine(self: Tolerance) f64 {
        return @sqrt(self.angle * (2.0 - self.angle));
    }

    /// Whether two parameters of a curve with domain length `span` are the same.
    pub fn sameParam(self: Tolerance, t0: f64, t1: f64, span: f64) bool {
        return @abs(t0 - t1) <= self.param * @max(span, 1.0);
    }
};

/// How finely a curve is cut into straight edges wherever it has to be (meshing, export):
/// `segments` edges per full circle when set, otherwise as many as keep each edge within
/// `min_angle` degrees of arc and `min_length` long, whichever gives fewer (OpenSCAD's
/// $fn, $fa and $fs). KupCAD's mesh engine follows the same rule, so both kernels cut a
/// curve alike.
pub const Resolution = struct {
    segments: u32 = 0, // 0 = from min_angle, min_length and chord
    min_angle: f64 = 12.0,
    min_length: f64 = 2.0,
    /// The most a circle's edge may stray from the arc it stands for (its sagitta), in
    /// millimetres: small circles get the segments this takes, where the length rule
    /// alone made a 3.4 mm hole a 10-gon 3.2 mm across the flats, undersized for its
    /// screw. The angle rule still caps the count, so a large circle costs no more.
    chord: f64 = 0.02,

    /// The number of edges a full circle of `radius` gets: at most `min_angle` of arc
    /// each and no shorter than `min_length`, whichever gives fewer, but at least as many
    /// as keep the edges within `chord` of the arc, up to the angle rule's count; then
    /// rounded up to a multiple of 4, so a quarter arc ends on the axes and a half circle's
    /// chords reach its full width (an odd count put no vertex at 90°, and the mesh engine's
    /// box of an arc fell short of the exact engine's).
    pub fn segmentsFor(self: Resolution, radius: f64) u32 {
        if (self.segments > 0) return self.segments;
        if (!(radius > 0.0)) return (MIN_AUTO_SEGMENTS + 3) / 4 * 4;
        const by_angle = 360.0 / self.min_angle;
        const by_length = 2.0 * std.math.pi * radius / self.min_length;
        const by_chord = if (self.chord < radius) std.math.pi / std.math.acos(1.0 - self.chord / radius) else 1.0;
        const count = @ceil(@min(by_angle, @max(by_length, by_chord)));
        // Past u32 the count is meaningless anyway; callers clamp to their own limits.
        if (!(count < @as(f64, std.math.maxInt(u32)) - 4)) return std.math.maxInt(u32);
        const at_least = @max(MIN_AUTO_SEGMENTS, @as(u32, @intFromFloat(count)));
        return (at_least + 3) / 4 * 4;
    }

    /// The most a free-form curve's span may bow from its chord of length `chord`: the
    /// sagitta a circle's segment with that chord has at this resolution, `(L/2)·tan(θ/4)`
    /// for the turning `θ` a segment gets (`2π/segments` when set; else `min_angle`, or,
    /// for a chord within `min_length`, the turning of the coarsest circle,
    /// `2π/MIN_AUTO_SEGMENTS`, since a small circle is cut by length and keeps that many
    /// segments at least), so a free-form span passes by the rule that cuts a circle,
    /// the coarser of the two (`mesh/chords.zig`). Without a fixed count, every circle
    /// `segmentsFor` cuts strays at most `self.chord` from its arc, except where the angle
    /// rule caps its count, and then its segments turn at most `min_angle`. So the bow is
    /// at most the larger of the two, as for any circle with a segment of this chord. It
    /// stays an upper bound on a mesh's departure (`query/distance.zig`) for large circles
    /// as well as small.
    pub fn chordBow(self: Resolution, chord: f64) f64 {
        const turning: f64 = if (self.segments > 0)
            2.0 * std.math.pi / @as(f64, @floatFromInt(self.segments))
        else if (chord <= self.min_length)
            2.0 * std.math.pi / @as(f64, @floatFromInt(MIN_AUTO_SEGMENTS))
        else
            self.min_angle * std.math.pi / 180.0;
        const bow = 0.5 * chord * @tan(turning / 4.0);
        if (self.segments > 0) return bow;
        const by_angle = 0.5 * chord * @tan(self.min_angle * std.math.pi / 180.0 / 4.0);
        return @min(bow, @max(self.chord, by_angle));
    }
};
