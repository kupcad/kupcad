//! The degeneracy corpus as OCCT's test scripts state their cases (`checknbshapes`,
//! `checkprops -s -v`, `checkmaxtol`; M4's exit, architecture §9.2): per case, per
//! operation, the result's vertices, edges, faces, solids and voids, its area, its volume
//! and the largest gap the boolean recorded, each answer worked out by hand (in the case's
//! comment), never read off the kernel; the volume identities on every case,
//! V(A ∪ B) + V(A ∩ B) = V(A) + V(B), V(A − B) = V(A) − V(A ∩ B); and rigid moves commuting
//! with the boolean on every case and a few hulls (§9.2's invariance of measures: both
//! operands under one turn and move give the counts, area and volume of the boolean
//! moved, the move far out among them). The operands of the hand-worked cases are boxes,
//! so each answer has a closed form; the corpus's other configurations (a vertex on a face,
//! a knife edge, a V groove, slivers, the fuzzer's finds) are degeneracy_test.zig's, with
//! the identities there too.
//!
//! OCCT's own cases as rows (research/occt-tests.md §2): `TURNED`, its `bop*_simple` pairs
//! of the unit box and a box turned about z, all four of OCCT's operations on each, the
//! identities and the rigid moves too; `CHAINS`, its pockets and slots cut in turn
//! (`bcut_simple`) and the boolean bugs that are boxes (`bugs/modalg_*`). Their coordinates
//! and OCCT's areas are OCCT's (LGPL-2.1, its tests used as data only); every volume and
//! count, and every area's closed form, is worked out here, OCCT's six digits the check
//! that the reading of its script is right.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const mat = @import("../math/mat.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Body = @import("../topology/body.zig").Body;
const check = @import("../topology/check.zig");
const mass = @import("../measure/mass.zig");
const overlap_rules = @import("../query/overlap.zig");
const transform = @import("../construct/transform.zig");
const solid_hull = @import("../construct/hull.zig");
const primitives = @import("../construct/primitives.zig");
const sweep = @import("../construct/sweep.zig");
const diagnostics = @import("../diagnostics.zig");
const pipeline = @import("pipeline.zig");
const helpers = @import("pipeline_test.zig");
const Vec3 = vec.Vec3;
const Diagnostics = diagnostics.Diagnostics;
const radians = std.math.degreesToRadians;

const tol = Tolerance.fromZone(1e-5);
/// The answers are exact; the measures are sums of products of the boxes' coordinates.
const CLOSE = 1e-9;
/// A merged vertex's centre is rounded at its coordinates: its gap may pass half the
/// distance it merged by that much (64 ulps of the largest coordinate, 2, as D27 reckons).
const GAP_ROUNDING = 64 * std.math.floatEps(f64) * 2;
/// Where the far rigid move takes the operands: coordinates of 1e5, a hundredth of what the
/// tolerance takes (`SCALE_GUARD`), where a coordinate's ulp is 1.5e-11.
const FAR: Vec3 = .{ 1e5, -2e5, 3e5 };
/// How far the operands reach from the origin before a move, at most (the hulls' 4 × √3).
const REACH = 7;
/// A measure's rounding at a distance, in ulps: the divergence theorem sums terms the size
/// of the distance times a face's area, each rounded (64, as D27 reckons).
const ROUNDING_ULPS = 64;
const SQRT2: f64 = std.math.sqrt2;
const SQRT3: f64 = @sqrt(3.0);
const SQRT5: f64 = @sqrt(5.0);
/// OCCT's C6 and D4 turn a box √31/4 long by 34.73° about its corner at the origin, so its
/// far corner falls a hair short of the diagonal through (1, 1): no closed form in the
/// angle, their measures are worked out in its cosine and tangent.
const BAR_COS: f64 = @cos(radians(34.73));
const BAR_TAN: f64 = @tan(radians(34.73));
const BAR_LENGTH: f64 = @sqrt(31.0) / 4.0;
/// D4's box is ½ wide: its far long side crosses x = 0 at `D4_HIGH` and y = 1 at
/// `D4_ACROSS`; `D4_CAP` is what it covers of the unit square (the square less the
/// triangle under its near side and the one over its far side).
const D4_HIGH: f64 = 0.5 / BAR_COS;
const D4_ACROSS: f64 = (1 - D4_HIGH) / BAR_TAN;
const D4_CAP: f64 = 1 - BAR_TAN / 2 - (1 - D4_HIGH) * D4_ACROSS / 2;
/// The most boxes a chain of `CHAINS` folds.
const MAX_CHAIN = 16;
/// `bcut_simple`'s block and its first pocket (origin and size), as OCCT's profiles and
/// prisms make them.
const BLOCK: [2]Vec3 = .{ .{ 0, 0, 0 }, .{ 150, 200, 40 } };
const POCKET: [2]Vec3 = .{ .{ 25, 25, 20 }, .{ 75, 100, 30 } };

/// What one operation must give. `vertices` and `edges` are null where solids touch along
/// an edge or at a corner: each solid keeps its own edge there (`EdgeSpec.copy`), a
/// representation's choice OCCT's compounds make otherwise, so the faces, solids and
/// measures say what the result is.
pub const Expect = struct {
    vertices: ?usize,
    edges: ?usize,
    faces: usize,
    solids: usize,
    voids: usize = 0,
    area: f64,
    volume: f64,
    /// The largest gap the report may record: 0 where every vertex is exact.
    max_gap: f64 = 0,
    /// How far the measures may be from the answer: the slab of faces closer than the
    /// intersection tolerance, which the boolean takes for one plane.
    slack: f64 = CLOSE,
};

const EMPTY: Expect = .{ .vertices = 0, .edges = 0, .faces = 0, .solids = 0, .area = 0, .volume = 0 };

/// A box's counts, area and volume.
fn boxOf(dx: f64, dy: f64, dz: f64) Expect {
    return .{ .vertices = 8, .edges = 12, .faces = 6, .solids = 1, .area = 2 * (dx * dy + dy * dz + dz * dx), .volume = dx * dy * dz };
}

pub const Case = struct {
    name: []const u8,
    a: [2]Vec3,
    b: [2]Vec3,
    @"union": Expect,
    intersection: Expect,
    difference: Expect,
};

pub const CASES = [_]Case{
    .{
        // Identical: the union and the intersection are the box, the difference empty
        .name = "identical boxes",
        .a = .{ .{ 0, 0, 0 }, .{ 2, 2, 2 } },
        .b = .{ .{ 0, 0, 0 }, .{ 2, 2, 2 } },
        .@"union" = boxOf(2, 2, 2),
        .intersection = boxOf(2, 2, 2),
        .difference = EMPTY,
    },
    .{
        // Nested: the union is the outer box, the intersection the inner, the difference a
        // box with a cube-shaped void (both boxes' counts; area 96 + 24; 64 − 8)
        .name = "a cube inside a cube",
        .a = .{ .{ 0, 0, 0 }, .{ 4, 4, 4 } },
        .b = .{ .{ 1, 1, 1 }, .{ 3, 3, 3 } },
        .@"union" = boxOf(4, 4, 4),
        .intersection = boxOf(2, 2, 2),
        .difference = .{ .vertices = 16, .edges = 24, .faces = 12, .solids = 1, .voids = 1, .area = 120, .volume = 56 },
    },
    .{
        // A box in another's corner, three faces touching with equal normals: the union is
        // the big box, the difference it with a corner notched: 7 of its corners and the
        // notch's 7, the three faces at the corner L-shaped, its other three, the notch's
        // three (V − E + F = 2: 14 − 21 + 9); the notch takes three unit squares and
        // gives three back
        .name = "faces touching with equal normals, a box in another's corner",
        .a = .{ .{ 0, 0, 0 }, .{ 2, 2, 2 } },
        .b = .{ .{ 0, 0, 0 }, .{ 1, 1, 1 } },
        .@"union" = boxOf(2, 2, 2),
        .intersection = boxOf(1, 1, 1),
        .difference = .{ .vertices = 14, .edges = 21, .faces = 9, .solids = 1, .area = 24, .volume = 7 },
    },
    .{
        // Two unit cubes face to face, whole: one 2 × 1 × 1 box; touching in a face only,
        // no volume in common
        .name = "faces touching with opposite normals, whole",
        .a = .{ .{ 0, 0, 0 }, .{ 1, 1, 1 } },
        .b = .{ .{ 1, 0, 0 }, .{ 2, 1, 1 } },
        .@"union" = boxOf(2, 1, 1),
        .intersection = EMPTY,
        .difference = boxOf(1, 1, 1),
    },
    .{
        // Face to face in part: the union is a prism on the octagon (0,0) (2,0) (2,1) (3,1)
        // (3,3) (2,3) (2,2) (0,2) of area 6 and perimeter 12, 2 high: 16 vertices, 24
        // edges, 10 faces, area 2·6 + 12·2, volume 12; the difference keeps the box whole
        .name = "faces touching with opposite normals, in part",
        .a = .{ .{ 0, 0, 0 }, .{ 2, 2, 2 } },
        .b = .{ .{ 2, 1, 0 }, .{ 3, 3, 2 } },
        .@"union" = .{ .vertices = 16, .edges = 24, .faces = 10, .solids = 1, .area = 36, .volume = 12 },
        .intersection = EMPTY,
        .difference = boxOf(2, 2, 2),
    },
    .{
        // Coplanar overlap (top and bottom in one plane): the union a prism on the octagon
        // (0,0) (2,0) (2,1) (3,1) (3,3) (1,3) (1,2) (0,2), area 7, perimeter 12 (area
        // 14 + 24, volume 14); the intersection the unit square's prism; the difference a
        // prism on the hexagon (0,0) (2,0) (2,1) (1,1) (1,2) (0,2), area 3, perimeter 8
        .name = "coplanar overlap",
        .a = .{ .{ 0, 0, 0 }, .{ 2, 2, 2 } },
        .b = .{ .{ 1, 1, 0 }, .{ 3, 3, 2 } },
        .@"union" = .{ .vertices = 16, .edges = 24, .faces = 10, .solids = 1, .area = 38, .volume = 14 },
        .intersection = boxOf(1, 1, 2),
        .difference = .{ .vertices = 12, .edges = 18, .faces = 8, .solids = 1, .area = 22, .volume = 6 },
    },
    .{
        // Overlapping at a corner: the union's vertices are each cube's 7 outer corners
        // and the 6 points where an edge of one meets a face of the other; its faces each
        // cube's 3 outer ones whole and 3 L-shaped (V − E + F = 2: 20 − 30 + 12); area
        // 2 · (24 − 3); the difference a cube notched at the far corner
        .name = "two cubes overlapping at a corner",
        .a = .{ .{ 0, 0, 0 }, .{ 2, 2, 2 } },
        .b = .{ .{ 1, 1, 1 }, .{ 3, 3, 3 } },
        .@"union" = .{ .vertices = 20, .edges = 30, .faces = 12, .solids = 1, .area = 42, .volume = 15 },
        .intersection = boxOf(1, 1, 1),
        .difference = .{ .vertices = 14, .edges = 21, .faces = 9, .solids = 1, .area = 24, .volume = 7 },
    },
    .{
        // The same moved to (1000, -700, 300), where rounding is a thousand times coarser
        // than at the origin: the same answers
        .name = "two cubes overlapping at a corner, at (1000, -700, 300)",
        .a = .{ .{ 1000, -700, 300 }, .{ 1002, -698, 302 } },
        .b = .{ .{ 1001, -699, 301 }, .{ 1003, -697, 303 } },
        .@"union" = .{ .vertices = 20, .edges = 30, .faces = 12, .solids = 1, .area = 42, .volume = 15 },
        .intersection = boxOf(1, 1, 1),
        .difference = .{ .vertices = 14, .edges = 21, .faces = 9, .solids = 1, .area = 24, .volume = 7 },
    },
    .{
        // Touching at a corner: the union two solids, nothing in common
        .name = "a vertex on a vertex",
        .a = .{ .{ 0, 0, 0 }, .{ 1, 1, 1 } },
        .b = .{ .{ 1, 1, 1 }, .{ 2, 2, 2 } },
        .@"union" = .{ .vertices = null, .edges = null, .faces = 12, .solids = 2, .area = 12, .volume = 2 },
        .intersection = EMPTY,
        .difference = boxOf(1, 1, 1),
    },
    .{
        // Touching along an edge: two solids, nothing in common
        .name = "an edge on an edge",
        .a = .{ .{ 0, 0, 0 }, .{ 1, 1, 1 } },
        .b = .{ .{ 1, 1, 0 }, .{ 2, 2, 1 } },
        .@"union" = .{ .vertices = null, .edges = null, .faces = 12, .solids = 2, .area = 12, .volume = 2 },
        .intersection = EMPTY,
        .difference = boxOf(1, 1, 1),
    },
    .{
        // A gap of 1e-3, far past the tolerance: two boxes, the second 0.999 long
        .name = "a near-tangent gap of 1e-3",
        .a = .{ .{ 0, 0, 0 }, .{ 1, 1, 1 } },
        .b = .{ .{ 1.001, 0, 0 }, .{ 2, 1, 1 } },
        .@"union" = .{ .vertices = 16, .edges = 24, .faces = 12, .solids = 2, .area = 6 + 2 * (0.999 + 0.999 + 1), .volume = 1.999 },
        .intersection = EMPTY,
        .difference = boxOf(1, 1, 1),
    },
    .{
        // An overlap of 1e-6, within the tolerance: the faces are one plane, the boxes
        // touch, and the merged vertices' balls are half the overlap; the measures hold to
        // the slab between the planes (1e-6 times the face)
        .name = "a near-tangent overlap of 1e-6",
        .a = .{ .{ 0, 0, 0 }, .{ 1, 1, 1 } },
        .b = .{ .{ 1 - 1e-6, 0, 0 }, .{ 2, 1, 1 } },
        .@"union" = withGap(boxOf(2, 1, 1), 1e-6),
        .intersection = withGap(EMPTY, 1e-6),
        .difference = withGap(boxOf(1, 1, 1), 1e-6),
    },
};

/// A pair of OCCT's `bop*_simple` grids: `a` a box by its corners (the unit box unless
/// stated), `b` a box by OCCT's origin and size turned `turn` radians about `axis` through
/// `pivot`; what each of OCCT's four operations gives, its `tuc` (b − a) among them. A
/// prism on an n-gon has 2n vertices, 3n edges and n + 2 faces, its area twice the
/// polygon's plus the perimeter times the height; the polygons named in plan are the
/// results' sections, each worked out by hand and checked at 60 digits against a
/// clipping of the two sections, OCCT's areas the check of the reading.
pub const Turned = struct {
    name: []const u8,
    a: [2]Vec3 = .{ .{ 0, 0, 0 }, .{ 1, 1, 1 } },
    origin: Vec3,
    size: Vec3,
    pivot: Vec3 = .{ 0, 0, 0 },
    axis: Vec3 = vec.Z3,
    turn: f64 = 0,
    intersection: Expect,
    difference: Expect,
    @"union": Expect,
    /// `b − a`.
    swapped: Expect,
};

pub const TURNED = [_]Turned{
    .{
        // After OCCT `tests/boolean/bop*_simple/A9`: its coordinates and areas; volumes and
        // counts worked out here. A slab across the box, four pairs of faces in one plane
        // (x = 0, x = 1, top, bottom): the intersection the slab, the difference the box
        // less it, two boxes ¼ deep apart (area 2 · 3), the union the box
        .name = "A9: a slab across the box, its faces in four of the box's planes",
        .origin = .{ 0, 0.25, 0 },
        .size = .{ 1, 0.5, 1 },
        .intersection = boxOf(1, 0.5, 1),
        .difference = .{ .vertices = 16, .edges = 24, .faces = 12, .solids = 2, .area = 6, .volume = 0.5 },
        .@"union" = boxOf(1, 1, 1),
        .swapped = EMPTY,
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/B3`: its coordinates and areas; volumes and
        // counts worked out here. A cube of ½ under and in front of the box, touching it
        // along the first half of its edge y = z = 0, one end shared: nothing in common, the
        // union both boxes touching (6 + 3/2, 1 + ⅛)
        .name = "B3: an edge on half an edge, one end shared",
        .origin = .{ 0, -0.5, -0.5 },
        .size = .{ 0.5, 0.5, 0.5 },
        .intersection = EMPTY,
        .difference = boxOf(1, 1, 1),
        .@"union" = .{ .vertices = null, .edges = null, .faces = 12, .solids = 2, .area = 7.5, .volume = 1.125 },
        .swapped = boxOf(0.5, 0.5, 0.5),
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/C3`: its coordinates and areas; volumes and
        // counts worked out here. A box √2 × √2/2 turned 45°, its long side on the box's
        // diagonal (0,0)–(1,1), the box's corner (0,1) on its far side, both only to the
        // turn's rounding. In plan the intersection the triangle (0,0) (1,1) (0,1), the
        // difference the other half, each of area ½ and perimeter 2 + √2 (3 + √2); the
        // union the pentagon (0,0) (1,0) (1,1) (½,3/2) (−½,½), area 3/2, perimeter 2 + 2√2
        // (5 + 2√2); the swapped difference the triangles left of x = 0 and above y = 1, of
        // area ¼ and perimeter 1 + √2 each, touching along the box's edge at (0,1)
        .name = "C3: a turned box along the face diagonal, a corner on its far side",
        .origin = .{ 0, 0, 0 },
        .size = .{ SQRT2, SQRT2 / 2, 1 },
        .turn = radians(45),
        .intersection = .{ .vertices = 6, .edges = 9, .faces = 5, .solids = 1, .area = 3 + SQRT2, .volume = 0.5 },
        .difference = .{ .vertices = 6, .edges = 9, .faces = 5, .solids = 1, .area = 3 + SQRT2, .volume = 0.5 },
        .@"union" = .{ .vertices = 10, .edges = 15, .faces = 7, .solids = 1, .area = 5 + 2 * SQRT2, .volume = 1.5 },
        .swapped = .{ .vertices = null, .edges = null, .faces = 10, .solids = 2, .area = 3 + 2 * SQRT2, .volume = 0.5 },
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/C4`: its coordinates and areas; volumes and
        // counts worked out here. A square √2/2 on a side turned 45°: the diamond (0,0)
        // (½,½) (0,1) (−½,½), two corners on the box's. In plan the intersection the
        // triangle (0,0) (½,½) (0,1), area ¼, perimeter 1 + √2 (3/2 + √2); the difference
        // the square notched by it, a pentagon of area ¾ and perimeter 3 + √2 (9/2 + √2);
        // the union the square and the diamond's other half, a pentagon of area 5/4 and
        // perimeter 3 + √2 (11/2 + √2); the swapped difference that half (3/2 + √2)
        .name = "C4: a diamond with two corners on the box's",
        .origin = .{ 0, 0, 0 },
        .size = .{ SQRT2 / 2, SQRT2 / 2, 1 },
        .turn = radians(45),
        .intersection = .{ .vertices = 6, .edges = 9, .faces = 5, .solids = 1, .area = 1.5 + SQRT2, .volume = 0.25 },
        .difference = .{ .vertices = 10, .edges = 15, .faces = 7, .solids = 1, .area = 4.5 + SQRT2, .volume = 0.75 },
        .@"union" = .{ .vertices = 10, .edges = 15, .faces = 7, .solids = 1, .area = 5.5 + SQRT2, .volume = 1.25 },
        .swapped = .{ .vertices = 6, .edges = 9, .faces = 5, .solids = 1, .area = 1.5 + SQRT2, .volume = 0.25 },
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/C5`: its coordinates and areas; volumes and
        // counts worked out here. A bar √2 × ¼ turned 45° from the corner (0,0) to (1,1),
        // sticking out at both. In plan, with c = √2/4, the intersection the quadrilateral
        // (0,0) (1,1) (1 − c,1) (0,c), area √2/4 − 1/16, perimeter 5√2/2 − ½ (3√2 − 5/8);
        // the difference the triangles (0,0) (1,0) (1,1) and (0,c) (1 − c,1) (0,1), apart
        // (17/16 − √2/4; 45/8 + √2); the union an octagon, the bar's ends added, perimeter
        // 5 − √2/2 (17/16; 57/8 − √2/2); the swapped difference those ends, right
        // triangles of legs ¼, apart (1/16; 9/8 + √2/2)
        .name = "C5: a bar from corner to corner",
        .origin = .{ 0, 0, 0 },
        .size = .{ SQRT2, 0.25, 1 },
        .turn = radians(45),
        .intersection = .{ .vertices = 8, .edges = 12, .faces = 6, .solids = 1, .area = 3 * SQRT2 - 5.0 / 8.0, .volume = SQRT2 / 4 - 1.0 / 16.0 },
        .difference = .{ .vertices = 12, .edges = 18, .faces = 10, .solids = 2, .area = 45.0 / 8.0 + SQRT2, .volume = 17.0 / 16.0 - SQRT2 / 4 },
        .@"union" = .{ .vertices = 16, .edges = 24, .faces = 10, .solids = 1, .area = 57.0 / 8.0 - SQRT2 / 2, .volume = 17.0 / 16.0 },
        .swapped = .{ .vertices = 12, .edges = 18, .faces = 10, .solids = 2, .area = 9.0 / 8.0 + SQRT2 / 2, .volume = 1.0 / 16.0 },
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/C6`: its coordinates and areas; volumes and
        // counts worked out here. A bar L = √31/4 long and ¼ wide turned 34.73°, its far
        // corner 1.5e-3 past x = 1 just under the corner (1,1), its near one past x = 0.
        // In plan, c the turn's cosine: the intersection the parallelogram between the
        // bar's long sides over 0 ≤ x ≤ 1, area ¼/c, perimeter 2·(1 + ¼)/c (3/c); the
        // difference the triangle under it and the quadrilateral over it, apart (1 − ¼/c;
        // 6 + 1/c); the union a decagon (1 + L/4 − ¼/c; 13/2 + 5L/2 − 3/c); the swapped
        // difference the bar's ends, a triangle and the spike past x = 1, apart (L/4 − ¼/c;
        // ½ + 5L/2 − 2/c)
        .name = "C6: a bar whose corner pokes 1.5e-3 past the box's side beside its corner",
        .origin = .{ 0, 0, 0 },
        .size = .{ BAR_LENGTH, 0.25, 1 },
        .turn = radians(34.73),
        .intersection = .{ .vertices = 8, .edges = 12, .faces = 6, .solids = 1, .area = 3 / BAR_COS, .volume = 0.25 / BAR_COS },
        .difference = .{ .vertices = 14, .edges = 21, .faces = 11, .solids = 2, .area = 6 + 1 / BAR_COS, .volume = 1 - 0.25 / BAR_COS },
        .@"union" = .{ .vertices = 20, .edges = 30, .faces = 12, .solids = 1, .area = 6.5 + 2.5 * BAR_LENGTH - 3 / BAR_COS, .volume = 1 + BAR_LENGTH / 4 - 0.25 / BAR_COS },
        .swapped = .{ .vertices = 14, .edges = 21, .faces = 11, .solids = 2, .area = 0.5 + 2.5 * BAR_LENGTH - 2 / BAR_COS, .volume = BAR_LENGTH / 4 - 0.25 / BAR_COS },
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/D4`: its coordinates and areas; volumes and
        // counts worked out here. A bar L = √31/4 long and ½ wide turned 34.73°: its far
        // end passes 3.85e-4 outside the corner (1,1), its near one past x = 0. In plan, c
        // and t the turn's cosine and tangent, h = `D4_HIGH`, x₁ = `D4_ACROSS`: the
        // intersection the pentagon (0,0) (1,t) (1,1) (x₁,1) (0,h) of area `D4_CAP`,
        // perimeter 1/c + (1 − t) + (1 − x₁) + x₁/c + h; the difference the triangles
        // (0,0) (1,0) (1,t) and (0,h) (x₁,1) (0,1), apart; the union a nonagon, the bar's
        // ends added (perimeter 3 + t + 2L − (1 + x₁)/c + x₁ − h); the swapped difference
        // those ends, a triangle and a pentagon through the neck at (1,1), apart
        // (perimeter 3 + h + 2L − t − x₁ − (1 + x₁)/c)
        .name = "D4: a bar whose end passes 3.85e-4 outside the box's corner",
        .origin = .{ 0, 0, 0 },
        .size = .{ BAR_LENGTH, 0.5, 1 },
        .turn = radians(34.73),
        .intersection = .{ .vertices = 10, .edges = 15, .faces = 7, .solids = 1, .area = 2 * D4_CAP + 1 / BAR_COS + (1 - BAR_TAN) + (1 - D4_ACROSS) + D4_ACROSS / BAR_COS + D4_HIGH, .volume = D4_CAP },
        .difference = .{ .vertices = 12, .edges = 18, .faces = 10, .solids = 2, .area = 2 * (1 - D4_CAP) + (1 + BAR_TAN + 1 / BAR_COS) + (1 - D4_HIGH + D4_ACROSS + D4_ACROSS / BAR_COS), .volume = 1 - D4_CAP },
        .@"union" = .{ .vertices = 18, .edges = 27, .faces = 11, .solids = 1, .area = 2 * (1 + BAR_LENGTH / 2 - D4_CAP) + 3 + BAR_TAN + 2 * BAR_LENGTH - (1 + D4_ACROSS) / BAR_COS + D4_ACROSS - D4_HIGH, .volume = 1 + BAR_LENGTH / 2 - D4_CAP },
        .swapped = .{ .vertices = 16, .edges = 24, .faces = 12, .solids = 2, .area = 2 * (BAR_LENGTH / 2 - D4_CAP) + 3 + D4_HIGH + 2 * BAR_LENGTH - BAR_TAN - D4_ACROSS - (1 + D4_ACROSS) / BAR_COS, .volume = BAR_LENGTH / 2 - D4_CAP },
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/D7`: its coordinates and areas; volumes and
        // counts worked out here. A unit box turned 30° about its edge on the box's edge
        // x = y = 1, the faces there at 30° and 60° to the box's: touching along the edge,
        // nothing in common
        .name = "D7: an edge on an edge, the faces at 30°",
        .origin = .{ 1, 1, 0 },
        .size = .{ 1, 1, 1 },
        .pivot = .{ 1, 1, 1 },
        .turn = radians(30),
        .intersection = EMPTY,
        .difference = boxOf(1, 1, 1),
        .@"union" = .{ .vertices = null, .edges = null, .faces = 12, .solids = 2, .area = 12, .volume = 2 },
        .swapped = boxOf(1, 1, 1),
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/M8`: its coordinates and areas; volumes and
        // counts worked out here. D7's box ½ high: touching along the edge's lower half,
        // one end shared (6 + 4, 1 + ½)
        .name = "M8: an edge on half an edge, the faces at 30°",
        .origin = .{ 1, 1, 0 },
        .size = .{ 1, 1, 0.5 },
        .pivot = .{ 1, 1, 1 },
        .turn = radians(30),
        .intersection = EMPTY,
        .difference = boxOf(1, 1, 1),
        .@"union" = .{ .vertices = null, .edges = null, .faces = 12, .solids = 2, .area = 10, .volume = 1.5 },
        .swapped = boxOf(1, 1, 0.5),
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/F5`: its coordinates and areas; volumes and
        // counts worked out here. A square √2/2 on a side turned −45° about (0,½): the
        // diamond on the box's edge midpoints. In plan the intersection the diamond, area
        // ½, perimeter 2√2 (1 + 2√2); the difference the four corner triangles, legs ½,
        // each touching the next at a midpoint: a ring of four prisms (½; 4 · (¼ + 1 +
        // √2/2)); the union the box
        .name = "F5: a diamond on the box's edge midpoints, a ring of four left",
        .origin = .{ 0, 0.5, 0 },
        .size = .{ SQRT2 / 2, SQRT2 / 2, 1 },
        .pivot = .{ 0, 0.5, 0 },
        .turn = radians(-45),
        .intersection = .{ .vertices = 8, .edges = 12, .faces = 6, .solids = 1, .area = 1 + 2 * SQRT2, .volume = 0.5 },
        .difference = .{ .vertices = null, .edges = null, .faces = 20, .solids = 4, .area = 5 + 2 * SQRT2, .volume = 0.5 },
        .@"union" = boxOf(1, 1, 1),
        .swapped = EMPTY,
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/G2`: its coordinates and areas; volumes and
        // counts worked out here. A box 3√5/8 × √5/4 turned atan(½) about (¼,0): corners
        // (¼,0) (1,⅜) (¾,⅞) (0,½), three on the box's edges. In plan the intersection the
        // rectangle, area 15/32, perimeter 5√5/4 (15/16 + 5√5/4); the difference the
        // triangles (0,0) (¼,0) (0,½) and (¼,0) (1,0) (1,⅜) and the pentagon (0,½) (¾,⅞)
        // (1,⅜) (1,1) (0,1), each touching the next at a corner of the rectangle: a ring of
        // three (17/32; 17/16 + 4 + 5√5/4); the union the box
        .name = "G2: a turned box with three corners on the box's edges, a ring of three left",
        .origin = .{ 0.25, 0, 0 },
        .size = .{ 3 * SQRT5 / 8, SQRT5 / 4, 1 },
        .pivot = .{ 0.25, 0, 0 },
        .turn = std.math.atan2(@as(f64, 1), 2),
        .intersection = .{ .vertices = 8, .edges = 12, .faces = 6, .solids = 1, .area = 15.0 / 16.0 + 5 * SQRT5 / 4, .volume = 15.0 / 32.0 },
        .difference = .{ .vertices = null, .edges = null, .faces = 17, .solids = 3, .area = 81.0 / 16.0 + 5 * SQRT5 / 4, .volume = 17.0 / 32.0 },
        .@"union" = boxOf(1, 1, 1),
        .swapped = EMPTY,
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/G8`: its coordinates and areas; volumes and
        // counts worked out here. A square ½ on a side turned −30° about (0,¼), inside the
        // box with corners on x = 0 and y = 0 at (0,¼) and (√3/4,0): the difference the
        // triangle between them and the origin and the rest, a heptagon, touching along two
        // separate edges (¾; perimeters ¾ + √3/4 and 21/4 − √3/4: 3/2 + 6)
        .name = "G8: a turned square with two corners on the box's sides, two solids touching twice",
        .origin = .{ 0, 0.25, 0 },
        .size = .{ 0.5, 0.5, 1 },
        .pivot = .{ 0, 0.25, 0 },
        .turn = radians(-30),
        .intersection = boxOf(0.5, 0.5, 1),
        .difference = .{ .vertices = null, .edges = null, .faces = 14, .solids = 2, .area = 7.5, .volume = 0.75 },
        .@"union" = boxOf(1, 1, 1),
        .swapped = EMPTY,
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/H7`: its coordinates and areas; volumes and
        // counts worked out here. A bar 0.1 × ½ turned 240° about (0,¼): its long side runs
        // from (0,¼) to (√3/4,0) across the corner, its other 0.1 nearer the origin,
        // crossing the box's edges at k·(√3/4,0) and k·(0,¼), k = 1 − 4√3/15, and its ends
        // stick out past x = 0 and y = 0. In plan the intersection the trapezoid between,
        // area (√3/32)(1 − k²) = 1/20 − √3/150, perimeter 6/5 − √3/15 (13/10 − 2√3/25);
        // the difference the triangle at the origin and a pentagon, apart (19/20 + √3/150;
        // 67/10 − 14√3/75); the union a decagon, perimeter 4 + √3/15 (1 + √3/150; 6 +
        // 2√3/25); the swapped difference the bar's two ends, triangles, apart (√3/150;
        // 2/5 + 16√3/75)
        .name = "H7: a bar 0.1 wide across the box's corner, thin strips in its top and bottom",
        .origin = .{ 0, 0.25, 0 },
        .size = .{ 0.1, 0.5, 1 },
        .pivot = .{ 0, 0.25, 0 },
        .turn = radians(240),
        .intersection = .{ .vertices = 8, .edges = 12, .faces = 6, .solids = 1, .area = 13.0 / 10.0 - 2 * SQRT3 / 25, .volume = 1.0 / 20.0 - SQRT3 / 150 },
        .difference = .{ .vertices = 16, .edges = 24, .faces = 12, .solids = 2, .area = 67.0 / 10.0 - 14 * SQRT3 / 75, .volume = 19.0 / 20.0 + SQRT3 / 150 },
        .@"union" = .{ .vertices = 20, .edges = 30, .faces = 12, .solids = 1, .area = 6 + 2 * SQRT3 / 25, .volume = 1 + SQRT3 / 150 },
        .swapped = .{ .vertices = 12, .edges = 18, .faces = 10, .solids = 2, .area = 2.0 / 5.0 + 16 * SQRT3 / 75, .volume = SQRT3 / 150 },
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/I9`: its coordinates and areas; volumes and
        // counts worked out here. A square ½ on a side turned −45° about (0,¼), a corner
        // there on x = 0, the next d = √2/4 − ¼ under y = 0. In plan the intersection the
        // square less the triangle under y = 0 (area d² = (3 − 2√2)/16), a pentagon of
        // area (1 + 2√2)/16 and perimeter ½ + √2 (5/8 + 5√2/4); the difference the triangle
        // (0,0) (¼,0) (0,¼) and a heptagon, touching along the edge at (0,¼) ((15 −
        // 2√2)/16; 59/8 − √2/4); the union a heptagon, the corner under y = 0 added (1 +
        // d²; 63/8 − 5√2/4); the swapped difference that corner's triangle (d²; 7/8 − √2/4)
        .name = "I9: a turned square with a corner on the box's side, poking out below",
        .origin = .{ 0, 0.25, 0 },
        .size = .{ 0.5, 0.5, 1 },
        .pivot = .{ 0, 0.25, 0 },
        .turn = radians(-45),
        .intersection = .{ .vertices = 10, .edges = 15, .faces = 7, .solids = 1, .area = 5.0 / 8.0 + 5 * SQRT2 / 4, .volume = (1 + 2 * SQRT2) / 16 },
        .difference = .{ .vertices = null, .edges = null, .faces = 14, .solids = 2, .area = 59.0 / 8.0 - SQRT2 / 4, .volume = (15 - 2 * SQRT2) / 16 },
        .@"union" = .{ .vertices = 14, .edges = 21, .faces = 9, .solids = 1, .area = 63.0 / 8.0 - 5 * SQRT2 / 4, .volume = 1 + (3 - 2 * SQRT2) / 16 },
        .swapped = .{ .vertices = 6, .edges = 9, .faces = 5, .solids = 1, .area = 7.0 / 8.0 - SQRT2 / 4, .volume = (3 - 2 * SQRT2) / 16 },
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/L1`: its coordinates and areas; volumes and
        // counts worked out here. A unit square turned 45° about (½,−¼), a diamond through
        // every side of the box, nothing on anything. In plan its sides x + y = ¼, x − y =
        // ¾, x + y = ¼ + √2 and y − x = √2 − ¾ cut the box's corners off with legs ¼, ¼, e,
        // e, e = 7/4 − √2: the intersection an octagon of area 7√2/2 − 33/8, perimeter 8√2 −
        // 8 (15√2 − 65/4); the difference the four corners, apart, perimeter 4 (41/8 −
        // 7√2/2; 57/4 − 7√2); the union a 16-gon of perimeter 16 − 8√2 (49/8 − 7√2/2;
        // 113/4 − 15√2); the swapped difference the diamond's four tips, apart, as the
        // difference
        .name = "L1: a turned square crossing every side of the box",
        .origin = .{ 0.5, -0.25, 0 },
        .size = .{ 1, 1, 1 },
        .pivot = .{ 0.5, -0.25, 0 },
        .turn = radians(45),
        .intersection = .{ .vertices = 16, .edges = 24, .faces = 10, .solids = 1, .area = 15 * SQRT2 - 65.0 / 4.0, .volume = 7 * SQRT2 / 2 - 33.0 / 8.0 },
        .difference = .{ .vertices = 24, .edges = 36, .faces = 20, .solids = 4, .area = 57.0 / 4.0 - 7 * SQRT2, .volume = 41.0 / 8.0 - 7 * SQRT2 / 2 },
        .@"union" = .{ .vertices = 32, .edges = 48, .faces = 18, .solids = 1, .area = 113.0 / 4.0 - 15 * SQRT2, .volume = 49.0 / 8.0 - 7 * SQRT2 / 2 },
        .swapped = .{ .vertices = 24, .edges = 36, .faces = 20, .solids = 4, .area = 57.0 / 4.0 - 7 * SQRT2, .volume = 41.0 / 8.0 - 7 * SQRT2 / 2 },
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/P4`: its coordinates and areas; volumes and
        // counts worked out here. A box ½ × ½ × 1 through the box's top at its back, its
        // side y = 1 in the box's: the intersection a cube of ½; the difference the box
        // notched at its top back edge, its four other faces whole, top and back notched,
        // the notch's four (V 8 + 8, E 12 + 1 + 11; 6 − ½ + 1); the union the box with the
        // cube on top, the backs one face (V 8 + 8, E 24; 6 + 3/2 − ½); the swapped
        // difference the cube on top
        .name = "P4: a box through the top, a side in the box's plane",
        .origin = .{ 0.25, 0.5, 0.5 },
        .size = .{ 0.5, 0.5, 1 },
        .intersection = boxOf(0.5, 0.5, 0.5),
        .difference = .{ .vertices = 16, .edges = 24, .faces = 10, .solids = 1, .area = 6.5, .volume = 0.875 },
        .@"union" = .{ .vertices = 16, .edges = 24, .faces = 10, .solids = 1, .area = 7, .volume = 1.125 },
        .swapped = boxOf(0.5, 0.5, 0.5),
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/P6`: its coordinates and areas; volumes and
        // counts worked out here. P4's box turned 90° about (¼,¼): x ∈ [−½, 0] against the
        // box's side x = 0 over y ∈ [¼, ¾], z ∈ [½, 1] (to the turn's rounding), rising past
        // the top. The union one solid: the box's side notched to a U of eight corners, its
        // top's edge there split twice, the turned box's side x = 0 above the top (V 8 + 10,
        // E 28, F 6 + 6; 6 + 5/2 − ½)
        .name = "P6: a box against the side, part of its face on the side's, past the top",
        .origin = .{ 0.25, 0.5, 0.5 },
        .size = .{ 0.5, 0.5, 1 },
        .pivot = .{ 0.25, 0.25, 0 },
        .turn = radians(90),
        .intersection = EMPTY,
        .difference = boxOf(1, 1, 1),
        .@"union" = .{ .vertices = 18, .edges = 28, .faces = 12, .solids = 1, .area = 8, .volume = 1.25 },
        .swapped = boxOf(0.5, 0.5, 1),
    },
    .{
        // After OCCT `tests/boolean/bop*_simple/Q9`: its coordinates and areas; volumes and
        // counts worked out here. A unit box turned −30° about the x axis and moved to
        // (1,1,3) (here turned about the x axis through (1,1,3), the same), against a box 3
        // on a side: its edge y = 1, z = 3 lies in the big box's top while it crosses the
        // top. Its section x = const is the square (1,3) (1 + √3/2, 5/2) (3/2 + √3/2,
        // 5/2 + √3/2) (3/2, 3 + √3/2); under z = 3 the triangle of legs 1 and 1/√3, area
        // √3/6 and perimeter 1 + √3, the intersection a prism 1 long on it (1 + 4√3/3); the
        // difference the big box grooved by it, the top holed (V 8 + 6, E 12 + 9, F 6 + 4;
        // 54 − 2/√3 + 1 + 1/√3 + √3/3 = 55); the union with the rest above the top, a
        // prism on a quadrilateral of area 1 − √3/6 (V 8 + 8, E 12 + 12, F 6 + 5; 59 −
        // 4√3/3); the swapped difference that prism (5)
        .name = "Q9: a turned box's edge in the other's top, crossing it",
        .a = .{ .{ 0, 0, 0 }, .{ 3, 3, 3 } },
        .origin = .{ 1, 1, 3 },
        .size = .{ 1, 1, 1 },
        .pivot = .{ 1, 1, 3 },
        .axis = vec.X3,
        .turn = radians(-30),
        .intersection = .{ .vertices = 6, .edges = 9, .faces = 5, .solids = 1, .area = 1 + 4 * SQRT3 / 3, .volume = SQRT3 / 6 },
        .difference = .{ .vertices = 14, .edges = 21, .faces = 10, .solids = 1, .area = 55, .volume = 27 - SQRT3 / 6 },
        .@"union" = .{ .vertices = 16, .edges = 24, .faces = 11, .solids = 1, .area = 59 - 4 * SQRT3 / 3, .volume = 28 - SQRT3 / 6 },
        .swapped = .{ .vertices = 8, .edges = 12, .faces = 6, .solids = 1, .area = 5, .volume = 1 - SQRT3 / 6 },
    },
};

/// One of OCCT's chains: boxes by OCCT's origin and size folded from the left by `op`
/// (`pipeline.chain`), and what it gives. The answers are worked out on the grid of the
/// boxes' coordinates (a face is the boundary cells' faces in one plane and facing one
/// way, joined across their edges), by hand and by a script that counts them so.
pub const Chain = struct {
    name: []const u8,
    boxes: []const [2]Vec3,
    op: pipeline.Op = .difference,
    want: Expect,
};

pub const CHAINS = [_]Chain{
    .{
        // After OCCT `tests/boolean/bcut_simple/H4` (its profiles and prisms as boxes): its
        // coordinates and area; volume and counts worked out here. Two pockets 20 deep
        // from the top of the block, crossing, their floors from two steps one face: in
        // plan their union an octagon of area 2 · 7500 − 2500 and perimeter 500 (1 200 000
        // − 20 · 12 500; 88 000 + 20 · 500); the block's six faces, the top holed, the
        // floor and eight walls; V 8 + 8 + 8, E 12 + 3 · 8
        .name = "bcut_simple/H4: two pockets crossing, one floor",
        .boxes = &.{ BLOCK, POCKET, .{ .{ 50, 75, 20 }, .{ 75, 100, 30 } } },
        .want = .{ .vertices = 24, .edges = 36, .faces = 15, .solids = 1, .area = 98000, .volume = 950000 },
    },
    .{
        // After OCCT `tests/boolean/bcut_simple/I3`: its coordinates and area; volume and
        // counts worked out here. H4's pockets in a block 100 deep, y from 50 to 150: they
        // break through both long sides, so the top is in two and each long side a U; in
        // the block their union is of area 2 · 5625 − 2500 and its walls 250 long (600 000
        // − 20 · 8750; 50 000 − 2 · 1500 + 20 · 250); faces bottom, two ends, two U's, two
        // tops, the floor, six walls; V 8 + 2 · 4 + 4 + 4, E 36 by V − E + F = 2
        .name = "bcut_simple/I3: two pockets breaking through both sides, the top in two",
        .boxes = &.{ .{ .{ 0, 50, 0 }, .{ 150, 100, 40 } }, POCKET, .{ .{ 50, 75, 20 }, .{ 75, 100, 30 } } },
        .want = .{ .vertices = 24, .edges = 36, .faces = 14, .solids = 1, .area = 52000, .volume = 425000 },
    },
    .{
        // After OCCT `tests/boolean/bcut_simple/I4`: its coordinates and area; volume and
        // counts worked out here. I3's block and first pocket, the second tool 3 high over
        // the block (z from 47 to 50): a step that meets nothing (600 000 − 20 · 5625;
        // 50 000 − 1500 + 20 · 225); faces four whole, the side y = 50 a U, the top a U,
        // the floor, three walls; V 8 + 4 + 2 + 2, E 24
        .name = "bcut_simple/I4: a pocket, then a tool that misses",
        .boxes = &.{ .{ .{ 0, 50, 0 }, .{ 150, 100, 40 } }, POCKET, .{ .{ 50, 75, 47 }, .{ 75, 100, 3 } } },
        .want = .{ .vertices = 16, .edges = 24, .faces = 10, .solids = 1, .area = 53000, .volume = 487500 },
    },
    .{
        // After OCCT `tests/boolean/bcut_simple/J8`: its coordinates and area; volume and
        // counts worked out here. H4's first pocket from the top and the second from the
        // bottom, its ceiling in the first's floor's plane facing the other way: where they
        // overlap (50 × 50) an opening through, genus 1 (1 200 000 − 2 · 150 000; 88 000 −
        // 2 · 7500 + 2 · 5000 + 2 · 20 · 350); faces the block's six (top and bottom
        // holed), each pocket's L-shaped floor or ceiling and four walls; V 8 + 4 + 4 + 10
        // at z = 20, E 40 by V − E + F − 2 holes = 0
        .name = "bcut_simple/J8: a pocket from the top, one from the bottom, floor on ceiling",
        .boxes = &.{ BLOCK, POCKET, .{ .{ 50, 75, -10 }, .{ 75, 100, 30 } } },
        .want = .{ .vertices = 26, .edges = 40, .faces = 16, .solids = 1, .area = 97000, .volume = 900000 },
    },
    .{
        // After OCCT `tests/boolean/bcut_simple/K8`: its coordinates and area; volume and
        // counts worked out here. The second pocket against the first's wall y = 125, half
        // of it: the wall between them goes, one pocket of eight walls, perimeter 500
        // (1 200 000 − 20 · (7500 + 3750); 88 000 + 20 · 500); V 24, E 36 as H4's
        .name = "bcut_simple/K8: a pocket against another's wall, the wall between gone",
        .boxes = &.{ BLOCK, POCKET, .{ .{ 50, 125, 20 }, .{ 75, 50, 30 } } },
        .want = .{ .vertices = 24, .edges = 36, .faces = 15, .solids = 1, .area = 98000, .volume = 975000 },
    },
    .{
        // After OCCT `tests/boolean/bcut_simple/K9`: its coordinates and area; volume and
        // counts worked out here. K8 with the second pocket flush with the first's wall
        // x = 25 too: those walls one face, six walls, perimeter 450 (1 200 000 − 20 ·
        // (7500 + 2500); 88 000 + 20 · 450); V 8 + 6 + 6, E 30
        .name = "bcut_simple/K9: two pockets flush, their walls x = 25 one face",
        .boxes = &.{ BLOCK, POCKET, .{ .{ 25, 125, 20 }, .{ 50, 50, 30 } } },
        .want = .{ .vertices = 20, .edges = 30, .faces = 13, .solids = 1, .area = 97000, .volume = 1000000 },
    },
    .{
        // After OCCT `tests/boolean/bcut_simple/L1`: its coordinates and area; volume and
        // counts worked out here. A slot 25 wide through the block across the pocket, its
        // floor one face with the pocket's: the top in two, the ends U's, ten walls (two on
        // each of x = 50 and x = 75 apart, two on each of y = 25 and y = 125, x = 25,
        // x = 100), 500 long (1 200 000 − 20 · 10 000; 88 000 − 2 · 500 + 20 · 500)
        .name = "bcut_simple/L1: a slot through a pocket, their floors one face",
        .boxes = &.{ BLOCK, POCKET, .{ .{ 50, -25, 20 }, .{ 25, 280, 30 } } },
        .want = .{ .vertices = 32, .edges = 48, .faces = 18, .solids = 1, .area = 97000, .volume = 1000000 },
    },
    .{
        // After OCCT `tests/boolean/bcut_simple/K7`: its coordinates and area; volume and
        // counts worked out here. A pocket from the top (floor z = 20), one from the bottom
        // (ceiling z = 20) and a slot 5 high buried between, its floor one face with the
        // first pocket's and open over the second's ceiling where they overlap (25 × 25):
        // a passage from top to bottom, genus 1 (1 750 000 − 75 000 − 75 000 − 5 · (7500 −
        // 625)); faces the block's six (top and bottom holed), four walls each, the floor,
        // the slot's ceiling, the second pocket's L-shaped ceiling; V 8 + 4 + 4 + 14 at
        // z = 20 + 6 at z = 25, E 55 by V − E + F − 2 holes = 0
        .name = "bcut_simple/K7: a buried slot joining a top pocket and a bottom one",
        .boxes = &.{ .{ .{ 0, 0, 0 }, .{ 175, 250, 40 } }, .{ .{ 25, 25, 20 }, .{ 50, 75, 30 } }, .{ .{ 100, 150, -10 }, .{ 50, 75, 30 } }, .{ .{ 50, 75, 20 }, .{ 75, 100, 5 } } },
        .want = .{ .vertices = 36, .edges = 55, .faces = 21, .solids = 1, .area = 145250, .volume = 1565625 },
    },
    .{
        // After OCCT `tests/bugs/modalg_1/buc60801`, its first two cuts: coordinates from
        // it; measures and counts worked out here. A block notched from its side x = −10
        // and then from its side y = 30: the notches leave the corner [−10, 0] × [20, 30]
        // touching the rest along the line x = 0, y = 20, two solids, an L-shaped prism
        // (in plan area 700, perimeter 120) and a prism 10 × 10, 40 high (28 000 + 4000;
        // 1400 + 4800 + 200 + 1600)
        .name = "buc60801, two cuts: a block left in two touching along an edge",
        .boxes = &.{ .{ .{ -10, -10, -10 }, .{ 30, 40, 40 } }, .{ .{ -20, 0, -20 }, .{ 20, 20, 100 } }, .{ .{ 0, 20, -20 }, .{ 50, 20, 100 } } },
        .want = .{ .vertices = null, .edges = null, .faces = 14, .solids = 2, .area = 8000, .volume = 32000 },
    },
    .{
        // OCCT's third cut, `B(−20,−20,20; 100,100,100)`, takes both above z = 20: two
        // solids still touching along the line, 30 high (14 faces; 1400 + 3600 + 200 + 1200;
        // 21 000 + 3000), its answer. It crosses the line they touch along, where each
        // solid's own edge is the other's copy (refused `below_feature_size` until the paves
        // took copies for where faces meet, 2026-11-14)
        .name = "buc60801, three cuts: both pieces cut down, still touching along the edge",
        .boxes = &.{ .{ .{ -10, -10, -10 }, .{ 30, 40, 40 } }, .{ .{ -20, 0, -20 }, .{ 20, 20, 100 } }, .{ .{ 0, 20, -20 }, .{ 50, 20, 100 } }, .{ .{ -20, -20, 20 }, .{ 100, 100, 100 } } },
        .want = .{ .vertices = null, .edges = null, .faces = 14, .solids = 2, .area = 6400, .volume = 24000 },
    },
    .{
        // After OCCT `tests/bugs/modalg_7/bug28485_1` (its counts: OCCT's convention and
        // Locus's agree here), its area and volume: a cube of 6 on the middle of a cube of
        // 10's side, that side holed by the square they share (600 + 216 − 2 · 36; 1000 +
        // 216); faces 6 + 5, V 8 + 8, E 12 + 12
        .name = "bug28485_1: a cube on the middle of another's face, the face holed",
        .boxes = &.{ .{ .{ 0, 0, 0 }, .{ 10, 10, 10 } }, .{ .{ 10, 2, 2 }, .{ 6, 6, 6 } } },
        .op = .@"union",
        .want = .{ .vertices = 16, .edges = 24, .faces = 11, .solids = 1, .area = 744, .volume = 1216 },
    },
    .{
        // After OCCT `tests/bugs/modalg_5/bug25354_37`: its coordinates (it checks the
        // section only); measures and counts worked out here. Two cubes of 10 face to face
        // over a 7 × 6 rectangle in a corner of each, no edge of either aligned: the faces
        // there L-shaped (1200 − 2 · 42); each cube's corners, and the two points where an
        // edge of one crosses an edge of the other (V 18), four edges split by them (E 28)
        .name = "bug25354_37: cubes face to face over a corner rectangle, united",
        .boxes = &.{ .{ .{ 0, 0, 0 }, .{ 10, 10, 10 } }, .{ .{ 10, 3, 4 }, .{ 10, 10, 10 } } },
        .op = .@"union",
        .want = .{ .vertices = 18, .edges = 28, .faces = 12, .solids = 1, .area = 1116, .volume = 2000 },
    },
    .{
        // The same: nothing in common
        .name = "bug25354_37: cubes face to face over a corner rectangle, intersected",
        .boxes = &.{ .{ .{ 0, 0, 0 }, .{ 10, 10, 10 } }, .{ .{ 10, 3, 4 }, .{ 10, 10, 10 } } },
        .op = .intersection,
        .want = EMPTY,
    },
    .{
        // The same: the first whole
        .name = "bug25354_37: cubes face to face over a corner rectangle, the second taken",
        .boxes = &.{ .{ .{ 0, 0, 0 }, .{ 10, 10, 10 } }, .{ .{ 10, 3, 4 }, .{ 10, 10, 10 } } },
        .want = boxOf(10, 10, 10),
    },
    .{
        // After OCCT `tests/bugs/modalg_6/bug27878_6`, its 4 × 4 unit cubes (OCCT joins
        // them at once; folded here those with i + j even first): those eight touch each
        // other along nine vertical edges and share no face, eight solids (8 · 6)
        .name = "bug27878_6: eight cubes of a checkerboard joined, touching along edges",
        .boxes = &checkerboard(8),
        .op = .@"union",
        .want = .{ .vertices = null, .edges = null, .faces = 48, .solids = 8, .area = 48, .volume = 8 },
    },
    .{
        // The other eight joined to them one by one, each step joining touching solids
        // through faces: the slab 4 × 4 × 1, every face merged
        .name = "bug27878_6: the checkerboard filled, one slab",
        .boxes = &checkerboard(16),
        .op = .@"union",
        .want = boxOf(4, 4, 1),
    },
};

/// bug27878_6's unit cubes at (i, j, 0), i and j from 0 to 3, as origin and size: the
/// eight with i + j even first, then the others, `count` of them.
fn checkerboard(comptime count: usize) [count][2]Vec3 {
    var out: [count][2]Vec3 = undefined;
    var n: usize = 0;
    for ([_]usize{ 0, 1 }) |parity| {
        for (0..4) |i| for (0..4) |j| {
            if ((i + j) % 2 != parity or n == count) continue;
            out[n] = .{ .{ @floatFromInt(i), @floatFromInt(j), 0 }, .{ 1, 1, 1 } };
            n += 1;
        };
    }
    return out;
}

/// `e` from a boolean whose merged vertices may carry gaps up to half of `overlap` (within
/// the zone) and their centre's rounding, its measures within the slab `overlap` thick
/// over a unit face (twice that over the sides it lengthens or shortens).
fn withGap(e: Expect, overlap: f64) Expect {
    var out = e;
    out.max_gap = overlap / 2 + GAP_ROUNDING;
    out.slack = 4 * overlap + CLOSE;
    return out;
}

fn expectCase(name: []const u8, a: *const Body, b: *const Body, op: pipeline.Op, want: Expect) !void {
    errdefer std.debug.print("case \"{s}\", {s}\n", .{ name, @tagName(op) });
    // The result passes the checker, the overlap rules and its report's own checks
    var result = try helpers.sound(a, b, op);
    defer result.deinit();
    var report = pipeline.Report.init(testing.allocator);
    defer report.deinit();
    var again = try helpers.reported(a, b, op, .{}, &report);
    defer again.deinit();
    const counts = result.counts();
    errdefer std.debug.print("got {d} vertices, {d} edges, {d} faces, shells {any}\n", .{ counts.vertices, counts.edges, counts.faces, helpers.shellKinds(&result) });
    if (want.vertices) |v| try testing.expectEqual(v, counts.vertices);
    if (want.edges) |e| try testing.expectEqual(e, counts.edges);
    try testing.expectEqual(want.faces, counts.faces);
    try testing.expectEqual([2]usize{ want.solids, want.voids }, helpers.shellKinds(&result));
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const m = try mass.mass(&result, .{}, &diag);
    try testing.expectApproxEqAbs(want.area, m.area, want.slack);
    try testing.expectApproxEqAbs(want.volume, m.volume, want.slack);
    errdefer std.debug.print("largest gap {e}, at most {e}\n", .{ report.max_gap, want.max_gap });
    try testing.expect(report.max_gap <= want.max_gap);
}

test "corpus: each case's counts, area, volume and largest gap, every operation" {
    for (CASES) |case| {
        var a = try helpers.box(case.a[0], case.a[1]);
        defer a.deinit();
        var b = try helpers.box(case.b[0], case.b[1]);
        defer b.deinit();
        try expectCase(case.name, &a, &b, .@"union", case.@"union");
        try expectCase(case.name, &a, &b, .intersection, case.intersection);
        try expectCase(case.name, &a, &b, .difference, case.difference);
    }
}

test "corpus: the volume identities hold on every case" {
    for (CASES) |case| {
        errdefer std.debug.print("case \"{s}\"\n", .{case.name});
        var a = try helpers.box(case.a[0], case.a[1]);
        defer a.deinit();
        var b = try helpers.box(case.b[0], case.b[1]);
        defer b.deinit();
        var u = try helpers.sound(&a, &b, .@"union");
        defer u.deinit();
        var i = try helpers.sound(&a, &b, .intersection);
        defer i.deinit();
        var d = try helpers.sound(&a, &b, .difference);
        defer d.deinit();
        const slack = @max(case.@"union".slack, case.intersection.slack, case.difference.slack);
        const va = try helpers.volume(&a);
        const vb = try helpers.volume(&b);
        const vi = try helpers.volume(&i);
        try testing.expectApproxEqAbs(va + vb, try helpers.volume(&u) + vi, slack);
        try testing.expectApproxEqAbs(va - vi, try helpers.volume(&d), slack);
    }
}

/// The rigid moves the corpus is held under: a turn off every axis with a short move, a
/// quarter turn with a move, and an eighth turn with the move far out (`FAR`).
fn rigidMoves() [3]mat.Affine {
    return .{
        mat.Affine.translate(.{ 0.5, -1, 2 }).compose(&mat.Affine.rotate(vec.normalized(.{ 1, 2, 3 }).?, 0.3)),
        mat.Affine.translate(.{ -3, 1, 0.5 }).compose(&mat.Affine.rotate(vec.X3, std.math.pi / 2.0)),
        mat.Affine.translate(FAR).compose(&mat.Affine.rotate(vec.normalized(.{ 1, 1, 0 }).?, std.math.pi / 4.0)),
    };
}

fn movedBy(body: *const Body, move: *const mat.Affine) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return transform.transform(testing.allocator, body, move, .{}, &diag);
}

/// `a op b` and the boolean of `a` and `b` under each rigid move: the same counts and
/// shells, the same area and volume to `slack` and the measures' rounding where the move
/// took them.
fn expectCommutes(a: *const Body, b: *const Body, op: pipeline.Op, slack: f64) !void {
    const moves = rigidMoves();
    return expectCommutesUnder(a, b, op, slack, &moves);
}

/// `expectCommutes` under `moves` alone.
fn expectCommutesUnder(a: *const Body, b: *const Body, op: pipeline.Op, slack: f64, moves: []const mat.Affine) !void {
    var result = try helpers.sound(a, b, op);
    defer result.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const m = try mass.mass(&result, .{}, &diag);
    for (moves, 0..) |move, k| {
        errdefer std.debug.print("{s}, under rigid move {d}\n", .{ @tagName(op), k });
        var moved_a = try movedBy(a, &move);
        defer moved_a.deinit();
        var moved_b = try movedBy(b, &move);
        defer moved_b.deinit();
        var moved = try helpers.sound(&moved_a, &moved_b, op);
        defer moved.deinit();
        try testing.expectEqual(result.counts(), moved.counts());
        try testing.expectEqual(helpers.shellKinds(&result), helpers.shellKinds(&moved));
        const mm = try mass.mass(&moved, .{}, &diag);
        const distance = vec.length(move.translation) + REACH;
        const close = slack + ROUNDING_ULPS * std.math.floatEps(f64) * distance * @max(m.area, 1);
        try testing.expectApproxEqAbs(m.area, mm.area, close);
        try testing.expectApproxEqAbs(m.volume, mm.volume, close);
    }
}

/// Pairs of hulls of grid points, each pair meeting where boxes cannot: slanted faces
/// touching, corners on faces, edges crossing slanted faces.
const HULLS = [_]struct { name: []const u8, a: []const Vec3, b: []const Vec3, pinched: ?pipeline.Op = null }{
    .{
        // Two tetrahedra sharing a slanted face whole
        .name = "tetrahedra face to face",
        .a = &.{ .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 0, 2, 0 }, .{ 0, 0, 2 } },
        .b = &.{ .{ 2, 0, 0 }, .{ 0, 2, 0 }, .{ 0, 0, 2 }, .{ 2, 2, 2 } },
    },
    .{
        // An octahedron in a cube, each corner on a face of the cube: the difference is a
        // void touching its outer shell at six points, refused by design (Leo, 2026-11-14;
        // STEP's brep_with_voids cannot hold it, OpenCascade read two solids)
        .name = "an octahedron's corners on a cube's faces",
        .a = &.{ .{ 0, 0, 0 }, .{ 4, 0, 0 }, .{ 0, 4, 0 }, .{ 4, 4, 0 }, .{ 0, 0, 4 }, .{ 4, 0, 4 }, .{ 0, 4, 4 }, .{ 4, 4, 4 } },
        .b = &.{ .{ 2, 2, 0 }, .{ 2, 2, 4 }, .{ 2, 0, 2 }, .{ 2, 4, 2 }, .{ 0, 2, 2 }, .{ 4, 2, 2 } },
        .pinched = .difference,
    },
    .{
        // A pyramid through a wedge: edges crossing slanted faces
        .name = "a pyramid through a wedge",
        .a = &.{ .{ 0, 0, 0 }, .{ 4, 0, 0 }, .{ 4, 4, 0 }, .{ 0, 4, 0 }, .{ 2, 2, 4 } },
        .b = &.{ .{ 1, -1, 1 }, .{ 3, -1, 1 }, .{ 1, 5, 1 }, .{ 3, 5, 1 }, .{ 2, -1, 3 }, .{ 2, 5, 3 } },
    },
};

test "corpus: rigid moves commute with the boolean on every case, every operation" {
    for (CASES) |case| {
        errdefer std.debug.print("case \"{s}\"\n", .{case.name});
        var a = try helpers.box(case.a[0], case.a[1]);
        defer a.deinit();
        var b = try helpers.box(case.b[0], case.b[1]);
        defer b.deinit();
        try expectCommutes(&a, &b, .@"union", case.@"union".slack);
        try expectCommutes(&a, &b, .intersection, case.intersection.slack);
        try expectCommutes(&a, &b, .difference, case.difference.slack);
    }
}

test "corpus: rigid moves commute with the boolean on hulls, every operation" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for (HULLS) |pair| {
        errdefer std.debug.print("hulls \"{s}\"\n", .{pair.name});
        var a = try solid_hull.hull(testing.allocator, tol, pair.a, &diag);
        defer a.deinit();
        var b = try solid_hull.hull(testing.allocator, tol, pair.b, &diag);
        defer b.deinit();
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            if (pair.pinched == op) {
                diag.clear();
                try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, &a, &b, op, .{}, &diag, null));
                try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
                continue;
            }
            try expectCommutes(&a, &b, op, CLOSE);
        }
    }
}

/// Row `row`'s operands: the box `a` and the box `b`, turned.
fn turnedPair(row: Turned) ![2]Body {
    var a = try helpers.box(row.a[0], row.a[1]);
    errdefer a.deinit();
    var b = try helpers.box(row.origin, vec.add(row.origin, row.size));
    if (row.turn == 0) return .{ a, b };
    defer b.deinit();
    return .{ a, try helpers.turned(&b, row.pivot, row.axis, row.turn) };
}

/// `e` for a row whose box is turned: its corners carry the turn's rounding, so a vertex
/// meant to lie on the other's may be merged with a gap of that rounding.
fn turnedGap(row: Turned, e: Expect) Expect {
    var out = e;
    if (row.turn != 0) out.max_gap = @max(e.max_gap, GAP_ROUNDING);
    return out;
}

test "corpus: OCCT's turned box pairs, each operation's counts, area, volume and largest gap, the operands either way" {
    for (TURNED) |row| {
        var pair = try turnedPair(row);
        defer for (&pair) |*body| body.deinit();
        const a = &pair[0];
        const b = &pair[1];
        try expectCase(row.name, a, b, .intersection, turnedGap(row, row.intersection));
        try expectCase(row.name, a, b, .difference, turnedGap(row, row.difference));
        try expectCase(row.name, a, b, .@"union", turnedGap(row, row.@"union"));
        errdefer std.debug.print("the operands swapped\n", .{});
        try expectCase(row.name, b, a, .difference, turnedGap(row, row.swapped));
        // The union and intersection of `b` and `a` are those of `a` and `b`
        try expectCase(row.name, b, a, .@"union", turnedGap(row, row.@"union"));
        try expectCase(row.name, b, a, .intersection, turnedGap(row, row.intersection));
    }
}

test "corpus: the volume identities hold on every turned pair, both differences" {
    for (TURNED) |row| {
        errdefer std.debug.print("case \"{s}\"\n", .{row.name});
        var pair = try turnedPair(row);
        defer for (&pair) |*body| body.deinit();
        const a = &pair[0];
        const b = &pair[1];
        var u = try helpers.sound(a, b, .@"union");
        defer u.deinit();
        var i = try helpers.sound(a, b, .intersection);
        defer i.deinit();
        var d = try helpers.sound(a, b, .difference);
        defer d.deinit();
        var s = try helpers.sound(b, a, .difference);
        defer s.deinit();
        const va = try helpers.volume(a);
        const vb = try helpers.volume(b);
        const vi = try helpers.volume(&i);
        try testing.expectApproxEqAbs(va + vb, try helpers.volume(&u) + vi, CLOSE);
        try testing.expectApproxEqAbs(va - vi, try helpers.volume(&d), CLOSE);
        try testing.expectApproxEqAbs(vb - vi, try helpers.volume(&s), CLOSE);
    }
}

test "corpus: rigid moves commute with the boolean on every turned pair, both differences" {
    // The far move alone (turned about (1, 1, 0) and taken to coordinates of 1e5): the
    // pairs are turned already, and every move of CASES is three times their booleans
    const moves = rigidMoves();
    const far = moves[2..3];
    for (TURNED) |row| {
        errdefer std.debug.print("case \"{s}\"\n", .{row.name});
        var pair = try turnedPair(row);
        defer for (&pair) |*body| body.deinit();
        const a = &pair[0];
        const b = &pair[1];
        try expectCommutesUnder(a, b, .@"union", CLOSE, far);
        try expectCommutesUnder(a, b, .intersection, CLOSE, far);
        try expectCommutesUnder(a, b, .difference, CLOSE, far);
        errdefer std.debug.print("the operands swapped\n", .{});
        try expectCommutesUnder(b, a, .difference, CLOSE, far);
    }
}

/// `operands` folded by `op`, checked: every rule of the checker and the overlap rules
/// pass it.
fn soundChain(operands: []const *const Body, op: pipeline.Op, report: *pipeline.Report) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var result = pipeline.chain(testing.allocator, operands, op, .{}, &diag, report) catch |e| {
        std.debug.print("chain {s}: {f}\n", .{ @tagName(op), diag });
        return e;
    };
    errdefer result.deinit();
    var checked = try check.run(testing.allocator, &result, .global);
    defer checked.deinit(testing.allocator);
    if (checked.first()) |f| {
        std.debug.print("chain {s}, the checker: {f}\n", .{ @tagName(op), f });
        return error.TestUnexpectedResult;
    }
    overlap_rules.check(testing.allocator, &result, .{}, &diag) catch |e| {
        std.debug.print("chain {s}, the overlap rules: {f}\n", .{ @tagName(op), diag });
        return e;
    };
    return result;
}

/// `body`'s counts, shells and measures, and the largest gap its boolean reported, as
/// `want` has them.
fn expectMeasures(body: *const Body, max_gap: f64, want: Expect) !void {
    const counts = body.counts();
    errdefer std.debug.print("got {d} vertices, {d} edges, {d} faces, shells {any}\n", .{ counts.vertices, counts.edges, counts.faces, helpers.shellKinds(body) });
    if (want.vertices) |v| try testing.expectEqual(v, counts.vertices);
    if (want.edges) |e| try testing.expectEqual(e, counts.edges);
    try testing.expectEqual(want.faces, counts.faces);
    try testing.expectEqual([2]usize{ want.solids, want.voids }, helpers.shellKinds(body));
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const m = try mass.mass(body, .{}, &diag);
    try testing.expectApproxEqAbs(want.area, m.area, want.slack);
    try testing.expectApproxEqAbs(want.volume, m.volume, want.slack);
    try testing.expect(max_gap <= want.max_gap);
}

/// A box by OCCT's origin and size.
fn boxBy(origin_size: [2]Vec3) !Body {
    return helpers.box(origin_size[0], vec.add(origin_size[0], origin_size[1]));
}

test "corpus: OCCT's chains of pockets, slots and contacts, each result's counts, area, volume and largest gap" {
    for (CHAINS) |chain| {
        errdefer std.debug.print("chain \"{s}\"\n", .{chain.name});
        var bodies: [MAX_CHAIN]Body = undefined;
        var made: usize = 0;
        defer for (bodies[0..made]) |*body| body.deinit();
        var operands: [MAX_CHAIN]*const Body = undefined;
        for (chain.boxes) |origin_size| {
            bodies[made] = try boxBy(origin_size);
            operands[made] = &bodies[made];
            made += 1;
        }
        var report = pipeline.Report.init(testing.allocator);
        defer report.deinit();
        var result = try soundChain(operands[0..made], chain.op, &report);
        defer result.deinit();
        try expectMeasures(&result, report.max_gap, chain.want);
    }
}

test "corpus: OCCT's U-shaped prism, a slot across its arms whose far wall is one face with the notch's end (bcut_simple/H1)" {
    // After OCCT `tests/boolean/bcut_simple/H1`: its coordinates and area; volume and
    // counts worked out here. A U (the octagon (0,0) (1,0) (1,3) (2,3) (2,0) (3,0) (3,5)
    // (0,5), area 12, perimeter 22) 2 high: V 16, E 24, F 10 (24 + 44). A slot y ∈ [2, 3],
    // z ∈ [1, 2] across both arms: the top in three (the arms' ends and the bar), the
    // sides x = 0 and x = 3 and the notch's x = 1 and x = 2 notched, the slot's floor and
    // near wall in two each, its far wall y = 3 one face with the notch's end (a T): 16
    // faces; area unchanged (six unit squares taken, six added), volume 24 − 2
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var outline = try primitives.polygon(testing.allocator, tol, &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 3 }, .{ 2, 3 }, .{ 2, 0 }, .{ 3, 0 }, .{ 3, 5 }, .{ 0, 5 } }, &diag);
    defer outline.deinit();
    var u = try sweep.extrude(testing.allocator, &outline, .{ 0, 0, 2 }, .{}, &diag);
    defer u.deinit();
    try expectMeasures(&u, 0, .{ .vertices = 16, .edges = 24, .faces = 10, .solids = 1, .area = 68, .volume = 24 });
    var slot = try boxBy(.{ .{ -1, 2, 1 }, .{ 5, 1, 3 } });
    defer slot.deinit();
    var report = pipeline.Report.init(testing.allocator);
    defer report.deinit();
    var cut = try soundChain(&.{ &u, &slot }, .difference, &report);
    defer cut.deinit();
    try expectMeasures(&cut, report.max_gap, .{ .vertices = 28, .edges = 42, .faces = 16, .solids = 1, .area = 68, .volume = 22 });
}

test "corpus: OCCT's slab of 16 cubes joined, then its copy moved onto it (bug27878_6)" {
    // After OCCT `tests/bugs/modalg_6/bug27878_6`: its coordinates, area and volume; counts
    // worked out here (OCCT's 78 faces keep every cube's faces apart). The slab, then the
    // slab moved by (½, ½, 1): face to face over 3.5 × 3.5 (96 − 2 · 12.25; 32); each
    // slab's five faces away from the other and its L-shaped face against it; V 8 + 8 and
    // the two points where an edge of one crosses an edge of the other, E 28 by
    // V − E + F = 2
    var bodies: [16]Body = undefined;
    var made: usize = 0;
    defer for (bodies[0..made]) |*body| body.deinit();
    var operands: [16]*const Body = undefined;
    for (checkerboard(16)) |origin_size| {
        bodies[made] = try boxBy(origin_size);
        operands[made] = &bodies[made];
        made += 1;
    }
    var report = pipeline.Report.init(testing.allocator);
    defer report.deinit();
    var slab = try soundChain(&operands, .@"union", &report);
    defer slab.deinit();
    try expectMeasures(&slab, report.max_gap, boxOf(4, 4, 1));
    var above = try helpers.moved(&slab, .{ 0.5, 0.5, 1 });
    defer above.deinit();
    var again = pipeline.Report.init(testing.allocator);
    defer again.deinit();
    var both = try soundChain(&.{ &slab, &above }, .@"union", &again);
    defer both.deinit();
    try expectMeasures(&both, again.max_gap, .{ .vertices = 18, .edges = 28, .faces = 12, .solids = 1, .area = 71.5, .volume = 32 });
}
