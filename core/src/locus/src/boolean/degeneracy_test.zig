//! The degeneracy corpus, planar part (KNOWLEDGE §11; research/solidcraft.md §1, tier 02):
//! one named test per configuration where operands meet in something thinner than a volume,
//! each result through the checker at level 2, the overlap rules and its report
//! (`pipeline_test.sound`), with its volume exact and the volume identities holding:
//! identical boxes, a cube inside a cube, a cube-shaped void, faces touching with equal and
//! with opposite normals, coplanar overlap, an edge on a face, an edge on an edge, a vertex
//! on a face, on an edge and on a vertex, a cut through a vertex and along an edge, a knife
//! edge, a mirrored copy united with its original, a pocket flush with the top, near-tangent
//! gaps and overlaps of 1e-3 and 1e-6, a knife-edge wedge, a V groove pinching the bottom to
//! a line and a pocket pinched to a face, walls 1e-4 apart joined, operands far from the
//! origin, two 1000-sided prisms and 64 pegs (their times are the benchmark's).

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const diagnostics = @import("../diagnostics.zig");
const mat = @import("../math/mat.zig");
const Body = @import("../topology/body.zig").Body;
const primitives = @import("../construct/primitives.zig");
const mass = @import("../measure/mass.zig");
const decompose = @import("../construct/decompose.zig");
const check = @import("../topology/check.zig");
const pipeline = @import("pipeline.zig");
const point_in_body = @import("../query/point_in_body.zig");
const FaceIndex = @import("../query/index.zig").FaceIndex;
const trim = @import("trim.zig");
const helpers = @import("pipeline_test.zig");
const box = helpers.box;
const sound = helpers.sound;
const volume = helpers.volume;
const expectShape = helpers.expectShape;
const expectIdentities = helpers.expectIdentities;
const shellKinds = helpers.shellKinds;
const turned = helpers.turned;
const Vec3 = vec.Vec3;
const types = @import("../topology/types.zig");
const overlap = @import("../query/overlap.zig");
const VertexIndex = types.VertexIndex;
const Diagnostics = diagnostics.Diagnostics;

const tol = Tolerance.fromZone(1e-5);
const CLOSE = 1e-9;
/// The middle of the solids fuzzer's grid, which it turns a placement about.
const FUZZ_GRID_MIDDLE: Vec3 = .{ 2, 2, 2 };
/// The solids fuzzer's turn at the angular tolerance (`1 − cos` of it is the tolerance less
/// 1.4e-14) and one clear of it, and how far the hull of the tests of a top that shallow to
/// a plate's is lifted: the find's (two of its top's corners 1.8e-4 under the plate's top,
/// the intersection tolerance 2e-4) and its neighbours, down to 5e-5 over it.
pub const TURN_AT_ANGLE: f64 = 0.014142253476507214;
const TURN_PAST_ANGLE: f64 = 0.02;
const SHALLOW_LIFTS = [_]f64{ 2.0000000063948848e-5, 6e-5, 1e-4, 1.5e-4, 2.5e-4 };
/// The hull of those tests, as the fuzzer drew it: its top the four points at z = 4.
pub const SHALLOW_HULL = [_]Vec3{ .{ 0, 3, 1 }, .{ 4, 3, 4 }, .{ 2, 3, 4 }, .{ 0, 1, 1 }, .{ 1, 4, 1 }, .{ 2, 0, 4 }, .{ 0, 1, 4 } };
/// The hull of the tests of a top that shallow whose two corners under the plate's top are
/// the ends of one of its edges (the seam a piece of that edge, not a section): its top
/// from x = 0 to that edge at x = 2, the face beyond the edge sloping down into the plate.
const EDGE_HULL = [_]Vec3{ .{ 0, 0, 4 }, .{ 2, 0, 4 }, .{ 2, 3, 4 }, .{ 0, 3, 4 }, .{ 4, 0, 2 }, .{ 4, 3, 2 }, .{ 0, 0, 1 }, .{ 0, 3, 1 }, .{ 4, 0, 1 }, .{ 4, 3, 1 } };
/// The turns of the tests of a prism's face shallow to the face of the other operand its
/// edge lies in (the ridge): parallel to that face within the angular tolerance and not in
/// one plane with it (the second the solids fuzzer's turn at the tolerance), and past it.
const RIDGE_TURNS = [_]f64{ 0.005, TURN_AT_ANGLE, TURN_PAST_ANGLE };
/// How far such a prism is lifted off the face its ridge lies in: within the intersection
/// tolerance (2e-5) over it and under it.
const RIDGE_LIFTS = [_]f64{ 1e-5, -1e-5 };
/// Those prisms' cross-sections in x and y (`ridgePrism` extrudes them along z), the ridge
/// through the origin and the face from it along +x the shallow one once the prism is
/// turned about the ridge: a wedge over y = 0, a wedge under it, a wedge whose shallow face
/// is a strip `RIDGE_STRIP` wide, and a block notched down to the ridge, its edge there
/// concave.
pub const RIDGE_WEDGE = [_]vec.Vec2{ .{ 0, 0 }, .{ 3, 0 }, .{ -1, 1 } };
pub const RIDGE_WEDGE_UNDER = [_]vec.Vec2{ .{ 0, 0 }, .{ -1, -1 }, .{ 3, 0 } };
const RIDGE_STRIP: f64 = 1e-3;
pub const RIDGE_STRIPPED = [_]vec.Vec2{ .{ 0, 0 }, .{ RIDGE_STRIP, 0 }, .{ 1, 1 }, .{ -1, 1 } };
pub const RIDGE_NOTCHED = [_]vec.Vec2{ .{ -4, -3 }, .{ 3, -3 }, .{ 3, 0 }, .{ 0, 0 }, .{ -1, 1 }, .{ -4, 1 } };
/// The strip's turns, both past the angular tolerance: its far edge within the tolerance
/// of the face the ridge lies in (1.8e-5 off it, the strip in that face's plane as the
/// paves hold it) and past it (2.1e-5).
const RIDGE_STRIP_TURN_ON: f64 = 0.018;
const RIDGE_STRIP_TURN_OFF: f64 = 0.021;
/// The hull of the tests of a slab's top with an edge over its plane, as the solids fuzzer
/// drew it (its corners at z = 2 the ends of that edge); the turns of the plate that cuts
/// the slab from it, the find's and its neighbours (a top 2.7e-7 rad off level either
/// way, and level); and how far the plate over the slab is lifted: its bottom within the
/// tolerance of the top's plane (2e-4; the top 2e-4 under z = 2, the edge 1.8e-4 over
/// it), past that of the plane and within it of the edge (the find's 5e-5 among them),
/// and past it of the edge too.
const LIPPED_HULL = [_]Vec3{ .{ 1, 3, 1 }, .{ 1, 4, 4 }, .{ 2, 3, 4 }, .{ 3, 0, 2 }, .{ 2, 2, 4 }, .{ 4, 2, 0 }, .{ 0, 1, 2 } };
const LIPPED_TURNS = [_]f64{ 0.000001, 0, -0.000001 };
const LIPPED_LIFTS_IN_PLANE = [_]f64{ -1.5e-4, -5e-5, -1e-5 };
const LIPPED_LIFTS_APART = [_]f64{ 1e-5, 5e-5, 1e-4, 1.5e-4 };
const LIPPED_LIFTS_CLEAR = [_]f64{ 1.9e-4, 2.5e-4 };
/// The slab of the tests of corners off their own face's plane (D28: a boolean keeps an
/// edge on its source's line), made as the solids fuzzer made the slab above, at any
/// height of the edge: the hull's nudge, the cutting plate's tolerance, the height of the
/// hull's edge between its corners (0, 1, 2) and (3, 0, 2), and how far over the top's
/// plane the edge lies, within the tolerance (2e-4) over it and under it. The slab's
/// bottom has one corner as far off its plane the same way, the hull's (1, 3, 1).
pub const LIP_NUDGE: Vec3 = .{ 2.000000005684342e-5, -2e-3, -2e-5 };
pub const LIP_TOLERANCE = Tolerance.fromZone(1e-4);
pub const LIP_Z: f64 = 2 + LIP_NUDGE[2];
const LIP_OVER: f64 = 1.8e-4;
const LIP_UNDER: f64 = -1.8e-4;
/// Rectangles in x and y against that slab's top and bottom: past both all round, inside
/// the top clear of the edge, and across the edge (two sides crossing it, a third inside
/// the top); and the bottom's corner off its plane, where the hull's (1, 3, 1) is.
pub const FOOT_COVER = [2][2]f64{ .{ -1, -1.5 }, .{ 4.5, 4.5 } };
pub const FOOT_INSIDE = [2][2]f64{ .{ 1.5, 1.5 }, .{ 2.2, 2.2 } };
pub const FOOT_ACROSS = [2][2]f64{ .{ 1, -1 }, .{ 2, 1.5 } };
pub const BOTTOM_CORNER = [2]f64{ 1 + LIP_NUDGE[0], 3 + LIP_NUDGE[1] };
/// The lifted edge's height over its top's plane and a box's bottom's over the edge, the
/// bottom within the tolerance (2e-4) of the edge and past it of the plane, by 1e-5 to
/// 7e-5.
const LIP_HINGE_WINDOW = [_][2]f64{ .{ LIP_OVER, 3e-5 }, .{ 1.5e-4, 8e-5 }, .{ 1e-4, 1.2e-4 }, .{ 1e-4, 1.7e-4 } };
/// The tests of what lies by that edge without touching the slab (the edge's sliver: what
/// lies between the edge and the line its two faces' planes meet along, the edge 1.8e-4
/// off the top's plane and the planes at 42°, so 2.7e-4 from the edge). Turns of the slab
/// and what meets it, whole: none, and four about skew axes (a point's first rays go to
/// the faces nearest it by their boxes, which a turn reorders), the first shifted far out
/// as the edge matrix's move is.
pub const SLIVER_TURNS = [_]struct { axis: Vec3, angle: f64, shift: Vec3 }{
    .{ .axis = vec.Z3, .angle = 0, .shift = vec.ZERO3 },
    .{ .axis = .{ 1, 2, 3 }, .angle = 0.3, .shift = .{ 1e3, -2e3, 500 } },
    .{ .axis = .{ 3, -1, 2 }, .angle = 1.1, .shift = vec.ZERO3 },
    .{ .axis = .{ 0, 1, 0 }, .angle = 2.0, .shift = vec.ZERO3 },
    .{ .axis = .{ -2, 1, 1 }, .angle = 0.7, .shift = vec.ZERO3 },
};
/// How far the points about the edge reach across it and over it either way, in half
/// tolerances.
const SLIVER_HALVES: i32 = 6;
/// Where a box's bottom edge lies along the lifted edge, in tolerances in from it and
/// over it: its foot on the slab's side face 1.1e-4 to 1.2e-4 along that face from the
/// edge, past the zone (1e-4), the first the edge matrix's find.
const SLIVER_BOXES = [_][2]f64{ .{ 1.5, 0.85 }, .{ 1.25, 0.6 }, .{ 1.9, 1.25 }, .{ 2.1, 1.5 }, .{ 2.5, 1.9 }, .{ 3, 2.5 } };
/// How two solids of those tests meet: joined into one solid with nothing in common,
/// two solids (apart, or touching along an edge or at a point), overlapping (one solid
/// joined, a solid in common), or refused below the minimum feature size either way round.
const Meeting = enum { one_solid, two_solids, overlap, refused };
/// The other operand of such a test: a box over a rectangle of the top, its bottom `lift`
/// over the top's plane; a box under a rectangle of the bottom, its top `lift` over the
/// bottom's plane (into the slab); a box as it stands; a box in the frame of the lifted
/// edge (x along it from its middle, y across it into the top, z the height) or of its
/// end at the hull's corner (0, 1, 2); the hull of points in the edge's frame.
pub const LipShape = union(enum) {
    on_top: struct { foot: [2][2]f64, lift: f64 },
    under: struct { foot: [2][2]f64, lift: f64 },
    box: [2]Vec3,
    by_edge: [2]Vec3,
    by_end: [2]Vec3,
    wedge: [6]Vec3,
};
const LipCase = struct { lip: f64, shape: LipShape, want: Meeting };
/// A box sitting on the top (the paves' `liesIn`, `blocksInside` and `hingedWithin`, the
/// pipeline's one plane for a group, `Provenance.representative`): its bottom between the
/// top's plane and the edge, under the plane, at the edge's height, over the edge within
/// the tolerance of it and past that.
const LIP_ON_TOP = [_]LipCase{
    .{ .lip = LIP_OVER, .shape = .{ .on_top = .{ .foot = FOOT_COVER, .lift = 1e-4 } }, .want = .one_solid },
    .{ .lip = LIP_OVER, .shape = .{ .on_top = .{ .foot = FOOT_COVER, .lift = -1e-4 } }, .want = .refused },
    .{ .lip = LIP_OVER, .shape = .{ .on_top = .{ .foot = FOOT_COVER, .lift = LIP_OVER + 1e-4 } }, .want = .refused },
    .{ .lip = LIP_OVER, .shape = .{ .on_top = .{ .foot = FOOT_INSIDE, .lift = -1e-4 } }, .want = .one_solid },
    .{ .lip = LIP_OVER, .shape = .{ .on_top = .{ .foot = FOOT_INSIDE, .lift = LIP_OVER + 1e-4 } }, .want = .two_solids },
    .{ .lip = LIP_OVER, .shape = .{ .on_top = .{ .foot = FOOT_ACROSS, .lift = LIP_OVER } }, .want = .one_solid },
    .{ .lip = LIP_OVER, .shape = .{ .on_top = .{ .foot = FOOT_ACROSS, .lift = LIP_OVER + 2.5e-4 } }, .want = .two_solids },
    .{ .lip = LIP_UNDER, .shape = .{ .on_top = .{ .foot = FOOT_COVER, .lift = LIP_UNDER } }, .want = .one_solid },
    .{ .lip = LIP_UNDER, .shape = .{ .on_top = .{ .foot = FOOT_COVER, .lift = 1e-4 } }, .want = .refused },
    .{ .lip = LIP_UNDER, .shape = .{ .on_top = .{ .foot = FOOT_INSIDE, .lift = LIP_UNDER - 1e-4 } }, .want = .overlap },
    .{ .lip = LIP_UNDER, .shape = .{ .on_top = .{ .foot = FOOT_ACROSS, .lift = -1e-4 } }, .want = .one_solid },
    .{ .lip = LIP_UNDER, .shape = .{ .on_top = .{ .foot = FOOT_ACROSS, .lift = LIP_UNDER - 1e-4 } }, .want = .refused },
};
/// A box through the top at right angles (edge–edge against the edge's own line,
/// edge–face beside it, `in_face.placeWithin`, a section along the face's boundary,
/// `alongBoundary` and `runOnPlane`): sides across the edge; a side along it, on it and
/// 1e-4 inside it, the box inside or outside; an upright edge through it 1.5e-4 either
/// side; and a side 3e-4 inside it, where the slab's top and the face under the edge are
/// 9e-5 apart with the edge over the plane and 4.5e-4 with it under.
const LIP_THROUGH = [_]LipCase{
    .{ .lip = LIP_OVER, .shape = .{ .box = .{ .{ 1, -1, 1.5 }, .{ 2, 1.5, 3 } } }, .want = .overlap },
    .{ .lip = LIP_UNDER, .shape = .{ .box = .{ .{ 1, -1, 1.5 }, .{ 2, 1.5, 3 } } }, .want = .overlap },
    .{ .lip = LIP_OVER, .shape = .{ .by_edge = .{ .{ -0.5, 0, 1.5 }, .{ 0.5, 1, 3 } } }, .want = .overlap },
    .{ .lip = LIP_UNDER, .shape = .{ .by_edge = .{ .{ -0.5, 1e-4, 1.5 }, .{ 0.5, 1 + 1e-4, 3 } } }, .want = .overlap },
    .{ .lip = LIP_OVER, .shape = .{ .by_edge = .{ .{ -0.5, -1 - 1e-4, 1.5 }, .{ 0.5, -1e-4, 3 } } }, .want = .two_solids },
    .{ .lip = LIP_UNDER, .shape = .{ .by_edge = .{ .{ 0, 1.5e-4, 1.5 }, .{ 1, 1 + 1.5e-4, 3 } } }, .want = .overlap },
    .{ .lip = LIP_OVER, .shape = .{ .by_edge = .{ .{ 0, -1 - 1.5e-4, 1.5 }, .{ 1, -1.5e-4, 3 } } }, .want = .two_solids },
    .{ .lip = LIP_OVER, .shape = .{ .by_edge = .{ .{ -0.5, 3e-4, 1.5 }, .{ 0.5, 1 + 3e-4, 3 } } }, .want = .refused },
    .{ .lip = LIP_UNDER, .shape = .{ .by_edge = .{ .{ -0.5, 3e-4, 1.5 }, .{ 0.5, 1 + 3e-4, 3 } } }, .want = .overlap },
};
/// An edge, a corner or a wedge's edge on the lifted edge (vertex–vertex and vertex–edge
/// with a corner off its face's plane, common blocks, `hingedWithin`): a box's bottom edge
/// along it, the box over the top or beside it, and 1e-4 over it; a box's corner at its
/// end, beside the slab, over the top, and 1.5e-4 over it; a wedge's edge down onto it, on
/// it and 1e-4 past it (2.8e-4 from the top's plane), and a wedge's edge against it from
/// the side.
const LIP_ALONG = [_]LipCase{
    .{ .lip = LIP_OVER, .shape = .{ .by_edge = .{ .{ -0.5, 0, LIP_Z }, .{ 0.5, 1, 3 } } }, .want = .one_solid },
    .{ .lip = LIP_UNDER, .shape = .{ .by_edge = .{ .{ -0.5, 0, LIP_Z }, .{ 0.5, 1, 3 } } }, .want = .one_solid },
    .{ .lip = LIP_UNDER, .shape = .{ .by_edge = .{ .{ -0.5, -1, LIP_Z }, .{ 0.5, 0, 3 } } }, .want = .two_solids },
    .{ .lip = LIP_OVER, .shape = .{ .by_edge = .{ .{ -0.5, 0, LIP_Z + 1e-4 }, .{ 0.5, 1, 3 } } }, .want = .refused },
    .{ .lip = LIP_OVER, .shape = .{ .by_end = .{ .{ -1, -1, LIP_Z }, .{ 0, 0, 3 } } }, .want = .two_solids },
    .{ .lip = LIP_UNDER, .shape = .{ .by_end = .{ .{ 0, 0, LIP_Z }, .{ 1, 1, 3 } } }, .want = .one_solid },
    .{ .lip = LIP_OVER, .shape = .{ .by_end = .{ .{ 0, 0, LIP_Z + 1.5e-4 }, .{ 1, 1, 3 } } }, .want = .refused },
    .{ .lip = LIP_OVER, .shape = .{ .wedge = wedgeOver(0) }, .want = .two_solids },
    .{ .lip = LIP_OVER, .shape = .{ .wedge = wedgeOver(1e-4) }, .want = .refused },
    .{ .lip = LIP_UNDER, .shape = .{ .wedge = wedgeOver(-1e-4) }, .want = .refused },
    .{ .lip = LIP_UNDER, .shape = .{ .wedge = .{ .{ -0.5, -1e-4, LIP_Z }, .{ 0.5, -1e-4, LIP_Z }, .{ -0.5, -0.5, LIP_Z + 0.3 }, .{ 0.5, -0.5, LIP_Z + 0.3 }, .{ -0.5, -0.5, LIP_Z - 0.3 }, .{ 0.5, -0.5, LIP_Z - 0.3 } } }, .want = .two_solids },
};
/// A box against the bottom's one corner off its plane (vertex–face and vertex–vertex,
/// `blocksInside`): under the whole bottom, its top between the bottom's plane and the
/// corner, past the plane the other way, and 1e-4 past the corner; its own corner at
/// that corner in the bottom's plane, under the slab or beside it; and through the
/// bottom there, an upright edge on the corner.
const LIP_UNDER_BOTTOM = [_]LipCase{
    .{ .lip = LIP_OVER, .shape = .{ .under = .{ .foot = FOOT_COVER, .lift = 1e-4 } }, .want = .one_solid },
    .{ .lip = LIP_OVER, .shape = .{ .under = .{ .foot = FOOT_COVER, .lift = -1e-4 } }, .want = .refused },
    .{ .lip = LIP_OVER, .shape = .{ .under = .{ .foot = FOOT_COVER, .lift = LIP_OVER + 1e-4 } }, .want = .overlap },
    .{ .lip = LIP_OVER, .shape = .{ .under = .{ .foot = .{ .{ BOTTOM_CORNER[0], BOTTOM_CORNER[1] - 1 }, .{ BOTTOM_CORNER[0] + 1, BOTTOM_CORNER[1] } }, .lift = 0 } }, .want = .one_solid },
    .{ .lip = LIP_OVER, .shape = .{ .under = .{ .foot = .{ .{ BOTTOM_CORNER[0] - 1, BOTTOM_CORNER[1] }, .{ BOTTOM_CORNER[0], BOTTOM_CORNER[1] + 1 } }, .lift = 0 } }, .want = .two_solids },
    .{ .lip = LIP_OVER, .shape = .{ .box = .{ .{ BOTTOM_CORNER[0], BOTTOM_CORNER[1] - 1, 0 }, .{ BOTTOM_CORNER[0] + 1, BOTTOM_CORNER[1], 1.5 } } }, .want = .overlap },
    .{ .lip = LIP_UNDER, .shape = .{ .box = .{ .{ BOTTOM_CORNER[0] - 1, BOTTOM_CORNER[1], 0 }, .{ BOTTOM_CORNER[0], BOTTOM_CORNER[1] + 1, 1.5 } } }, .want = .overlap },
    .{ .lip = LIP_UNDER, .shape = .{ .under = .{ .foot = FOOT_COVER, .lift = -1e-4 } }, .want = .one_solid },
    .{ .lip = LIP_UNDER, .shape = .{ .under = .{ .foot = FOOT_COVER, .lift = 1e-4 } }, .want = .refused },
};
/// The solids of the tests of an edge from a corner within the tolerance of a side's
/// plane and off the side, as the solids fuzzer drew them (the nightly of 2026-11-20, bp;
/// zone 1e-4, an intersection tolerance of 2e-4): a box with its side at x = 2.0003, the
/// cavity that leaves that side a wall 3 tolerances thick, and a plate through both whose
/// side is 1e-4 inside the box's (their union has one face there in the plate's plane,
/// the box's edges 1e-4 off it, D28); and the hull, zone 1e-5, whose corner (2, 1, 4)
/// comes to the box's top edge at y = 1, 2.5e-4 from the side's edges and 1.5e-4 from the
/// side's plane, on the far side of it from them.
const OFFSIDE_TOLERANCE = Tolerance.fromZone(1e-4);
const OFFSIDE_BOX = [2]Vec3{ .{ 0.25, 1, 1 }, .{ 2 + 1.5 * OFFSIDE_TOLERANCE.xsect, 4, 4 } };
const OFFSIDE_CAVITY = [2]Vec3{ .{ 0.5, 1.25, 1.25 }, .{ 2 - 1.5 * OFFSIDE_TOLERANCE.xsect, 3.75, 3.75 } };
const OFFSIDE_BOX_NUDGE: Vec3 = .{ 0, 0, -5e-5 };
const OFFSIDE_PLATE = [2]Vec3{ .{ -48, 2, 1.5 }, .{ 2, 102, 2.5 } };
const OFFSIDE_PLATE_NUDGE: Vec3 = .{ 2.000000014495072e-4, 5e-5, 0 };
const OFFSIDE_HULL = [_]Vec3{ .{ 3, 3, 2 }, .{ 2, 1, 4 }, .{ 0, 3, 4 }, .{ 3, 3, 3 }, .{ 0, 2, 0 }, .{ 1, 3, 3 }, .{ 3, 0, 2 } };
const OFFSIDE_HULL_NUDGE: Vec3 = .{ 5e-5, 0, -1.999999999431566e-4 };
/// The plane those solids are mirrored in: y = 2.5, the box's own middle.
const OFFSIDE_MIRROR_Y: f64 = 5;
/// How far the hull of those tests is shifted: in x, its corner 1.6e-4 to 1.9e-4 from the
/// side's plane (within the tolerance of it) and 2.5e-4 (clear of it); in y, the corner's
/// foot on the footprint of the side's edge or outside it, and inside it.
const OFFSIDE_NEAR = [_]f64{ -1e-5, -3e-5, -4e-5 };
const OFFSIDE_CLEAR: f64 = -1e-4;
const OFFSIDE_OUT = [_]f64{ 0, -4e-6, -3e-5, -6e-5 };
const OFFSIDE_IN = [_]f64{ 1e-5, 3e-5 };
/// OCCT's bug33361 (research/occt-tests.md, O6): four convex hexahedra from a real model,
/// their corners meant to meet 9.6e-5 to 1.7e-4 apart, coordinates near 128; its own
/// numbers, as the case gives them.
const BUG33361 = [4][8]Vec3{
    .{ .{ -13.1319809553115, 86.7822037750006, -0.00566973476865229 }, .{ -128.558636709231, 86.5345485791916, -0.00570258843333704 }, .{ -100.69915263562, -4.39311321186025, -0.00566084285433277 }, .{ -79.6175928285065, -4.39310160958954, -0.0056548256445943 }, .{ -14.129603767474, 86.2679145189996, -19.5413698283793 }, .{ -127.672333074639, 86.0243014066245, -19.5414021458256 }, .{ -99.9691824161271, -4.39312007067491, -19.5413606345018 }, .{ -80.240198192502, -4.39310921279638, -19.5413550033513 } },
    .{ .{ 127.874808332641, 87.0848242748098, -0.00573631640736139 }, .{ 4.13755363440343, 86.8193381629493, -0.00577153550167253 }, .{ 87.7714933163724, -4.39312459253253, -0.00571376462476536 }, .{ 108.964655532952, -4.39311292884125, -0.00570771556087379 }, .{ 127.250964034433, 86.5713396058731, -19.5413363036311 }, .{ 5.24619819968578, 86.3095706585265, -19.5413710296105 }, .{ 88.4127315018899, -4.39313150014382, -19.5413135815986 }, .{ 108.446956291808, -4.39312047427561, -19.5413078633248 } },
    .{ .{ 108.933394491783, -4.52270499989385, -0.0678854291688111 }, .{ 71.6392583557696, -4.82783796975667, 0.111191412258037 }, .{ 71.3588792617103, 151.745015502843, 0.0366204967163988 }, .{ 127.845048470054, 86.9672826319557, -0.202979251077327 }, .{ 109.955308180154, -5.58542764710532, 46.9881961078522 }, .{ 70.0688762581537, -5.90713971196433, 46.9762651891041 }, .{ 69.7567011034265, 151.061981157248, 47.828071244823 }, .{ 128.441716305279, 83.7679782847199, 47.4778456953173 } },
    .{ .{ -122.825413548196, 67.8222420317801, -0.00583425335077337 }, .{ 121.414994525437, 55.8353479065558, -0.00563439528369258 }, .{ 127.874867553719, 87.0848594871004, -0.00564196037409204 }, .{ -128.558663169796, 86.5344601820726, -0.00584644818335889 }, .{ -122.343446023918, 68.6316879811904, -19.5414411166127 }, .{ 121.07295954832, 56.6852348873057, -19.5412518461508 }, .{ 127.250997928568, 86.5713737315812, -19.5412353309277 }, .{ -127.67235532236, 86.0242158147956, -19.5414386144761 } },
};
/// OCCT's C6 and D4 (corpus_test.zig's `TURNED`): a box √31/4 long, ¼ or ½ wide, turned
/// 34.73° about its corner at the origin against the unit box.
const BAR_TURN = std.math.degreesToRadians(34.73);
const BAR_LENGTH = @sqrt(31.0) / 4.0;
/// The scales the probes take D4's neck to (3.85e-4 wide at 1: 19, 2, 1 and ½
/// intersection tolerances) and C6's spike (1.53e-3 at 1: 77, 2, 1 and ½).
const D4_SCALES = [_]f64{ 1, 0.104, 0.052, 0.026 };
const C6_SCALES = [_]f64{ 1, 0.026, 0.013, 0.0065 };
/// H7's bar (0.1 wide) thinned to these many intersection tolerances.
const H7_WIDTHS = [_]f64{ 5, 3, 1.5 };
/// How far the spec case's second box stands over the first's height and depth: within
/// the zone, and five intersection tolerances.
const OVERSIZES = [_]f64{ 1e-6, 1e-4 };
/// The hull of the tests of a flat tetrahedron cut to a strip along its upper edge, as the
/// solids fuzzer drew it: its edge between (3, 1, 4) and (3, 3, 4) runs over that edge.
const FLAT_HULL = [_]Vec3{ .{ 1, 4, 1 }, .{ 3, 3, 4 }, .{ 4, 0, 1 }, .{ 4, 4, 3 }, .{ 3, 1, 4 } };
/// The tetrahedron of those tests, two opposite edges through (3, 1), the lower along x and
/// the upper along y from 0 to 2: how many intersection tolerances apart the two are in z
/// and half the lower edge's length (the fuzzer's 3 and 1, the corner at the upper edge's
/// end a right angle from above; that corner sharper and blunter; and the edges nearer and
/// farther, all past the minimum feature size, 2); and where it lies, how far under the
/// hull's edge and nudged along its own upper edge (the fuzzer's 2e-3 under, the strip the
/// hull cuts of it 3e-3 wide, nudged either way, and ten times as far under).
const FLAT_SHAPES = [_][2]f64{ .{ 3, 1 }, .{ 3, 0.5 }, .{ 3, 2 }, .{ 2.5, 1 }, .{ 4, 1 } };
const FLAT_PLACES = [_][2]f64{ .{ 2e-3, 1e-5 }, .{ 2e-3, -1e-5 }, .{ 2e-2, 1e-5 } };
/// The solid of the tests of a face by a corner of a pocket's mouth, as the solids fuzzer
/// made it: a box less a cavity (the fuzzer's wall with a gap of 2.5 intersection
/// tolerances, moved and nudged as it placed it), cut by a hull moved up 1 and nudged
/// 5e-6 in y. The cut leaves the cavity a pocket open through the hull's face; where the
/// pocket's ceiling (z = 2.75002) and its side (y = 3.25), a reflex edge between them, meet
/// that face is the corner (1.8750267, 3.25, 2.75002), a notch's corner of the face.
const POCKET_OUTER = [2]Vec3{ .{ 1.25, 2, 1 }, .{ 3.000025, 4, 3 } };
const POCKET_CAVITY = [2]Vec3{ .{ 1.5, 2.25, 1.25 }, .{ 2.999975, 3.75, 2.75 } };
const POCKET_MOVE: Vec3 = .{ 0, 1, 0 };
const POCKET_NUDGE: Vec3 = .{ 0, 0, 2.0000000071054275e-5 };
const POCKET_CUTTER = [_]Vec3{ .{ 0, 2, 0 }, .{ 2, 4, 4 }, .{ 0, 2, 4 }, .{ 4, 4, 4 }, .{ 3, 2, 2 }, .{ 0, 3, 0 }, .{ 0, 2, 3 }, .{ 3, 2, 4 } };
const POCKET_CUTTER_MOVE: Vec3 = .{ 0, 0, 1 };
const POCKET_CUTTER_NUDGE: Vec3 = .{ 0, 5e-6, 0 };
/// The hull of those tests, as the fuzzer drew, scaled and moved it: its face in the plane
/// 2x + z = 6.5 (`POCKET_FACE_NORMAL` its outward normal) has that corner 3.27e-5 behind
/// it, `POCKET_FOUND_DEPTH` intersection tolerances inside the hull.
const POCKET_HULL = [_]Vec3{ .{ 2, 0, 3 }, .{ 2, 4, 0 }, .{ 2, 1, 1 }, .{ 0, 4, 4 }, .{ 4, 1, 0 }, .{ 1, 2, 4 }, .{ 1, 2, 2 } };
const POCKET_HULL_SCALE: Vec3 = .{ 2, 1, 2 };
const POCKET_HULL_MOVE: Vec3 = .{ -0.5, 0, -0.5 };
const POCKET_FACE_NORMAL: Vec3 = .{ -0.8944271909999161, 0, -0.44721359549995804 };
const POCKET_FOUND_DEPTH: f64 = 1.635;
/// The solid and the hull of those tests are mirrored in the plane y = 2: a y becomes
/// this less it.
const POCKET_MIRROR_Y: f64 = 4;
/// How the hull of those tests meets the pocket's corner, by how many intersection
/// tolerances the corner lies behind its face (`PocketCase.depth`; at the fuzzer's,
/// `POCKET_FOUND_DEPTH`, the hull is as it drew it): the face clear of the corner on its far side and
/// the corner on the face, each operation made; the corner past its reach of the face and
/// within the minimum feature size of where the face meets the pocket's faces, refused (at
/// 1.2 tolerances as an edge too short to split, the face crossing an edge of the pocket
/// 1.9e-5 from the corner, in the corner's strip, the steepest crossing taken first; the
/// audit of the ties, 2026-11-25);
/// the face cutting the corner's three edges, the chord between its crossings of the
/// mouth's two edges within reach of them (the find's and either side of it), where the
/// solids are joined, the tip of the corner the hull holds a sliver (the intersection
/// and the hull less the solid refused); and the face farther in, each operation made.
const PocketCase = struct { depth: f64, want: enum { made, below_feature_size, edge_too_short, sliver_tip } };
const POCKET_CASES = [_]PocketCase{
    .{ .depth = -1.5, .want = .made },
    .{ .depth = 0.5, .want = .made },
    .{ .depth = 1.2, .want = .edge_too_short },
    .{ .depth = 1.4, .want = .below_feature_size },
    .{ .depth = 1.5, .want = .sliver_tip },
    .{ .depth = POCKET_FOUND_DEPTH, .want = .sliver_tip },
    .{ .depth = 1.8, .want = .sliver_tip },
    .{ .depth = 2.2, .want = .made },
    .{ .depth = 5, .want = .made },
};
/// The two hulls of the tests of an edge along another's within the tolerance, as the
/// solids fuzzer drew them (the second before its quarter turn about z): the first's edge
/// from (3, 0, 2) to (2, 0, 0), once moved, and the second's from (3, 0, 2) to (4, 0, 4),
/// once turned, run along each other, the two corners at (3, 0, 2) the nudges apart; and
/// the first hull's nudge.
const ALONG_HULL = [_]Vec3{ .{ 4, 1, 3 }, .{ 4, 0, 2 }, .{ 3, 2, 1 }, .{ 4, 4, 0 }, .{ 3, 2, 0 }, .{ 3, 0, 0 } };
const ALONG_OTHER = [_]Vec3{ .{ 3, 4, 1 }, .{ 1, 4, 3 }, .{ 4, 0, 3 }, .{ 0, 0, 4 }, .{ 0, 1, 2 }, .{ 3, 3, 0 } };
const ALONG_NUDGE: Vec3 = .{ 0, 0, 2.000000005684342e-5 };
/// How the two hulls of those tests meet, whichever comes first: every operation made;
/// their intersection refused for a sliver (the corner the two edges cut off the first
/// hull's face, narrower than the zone on the line the result's edge keeps) and the rest
/// made; that and the second less the first refused alike; or every operation refused,
/// an edge too short or features below the minimum size.
const Along = enum { made, sliver_in_common, sliver_in_common_and_rest, edge_too_short, below_feature_size };
/// The second hull's nudges in those tests (the fuzzer's first, the two edges 1.67e-5
/// apart at a tolerance of 2e-5 and the corners 4.15e-5): the second edge inside the
/// first hull's face or outside it, by the zone and by half of it, level with the first
/// or to one side, the corners two tolerances apart along the edges or one and a half.
/// Two of them (the second edge outside by half the zone, the corners two tolerances
/// apart, to one side or level) have a corner of the intersection at 0.9 of the sliver
/// limit, refused since the sliver measure walks each curve to its own end: walked from
/// each curve's start only, it overstated that corner both ways round (2026-11-22).
const ALONG_CASES = [_]struct { nudge: Vec3, meet: Along }{
    .{ .nudge = .{ -5e-6, 1e-5, -2.000000005684342e-5 }, .meet = .made },
    .{ .nudge = .{ -5e-6, 1e-5, -1e-5 }, .meet = .made },
    .{ .nudge = .{ -5e-6, 5e-6, -2.000000005684342e-5 }, .meet = .made },
    .{ .nudge = .{ -5e-6, 5e-6, -1e-5 }, .meet = .made },
    .{ .nudge = .{ -5e-6, -5e-6, -2.000000005684342e-5 }, .meet = .made },
    .{ .nudge = .{ -5e-6, -5e-6, -1e-5 }, .meet = .sliver_in_common },
    .{ .nudge = .{ -5e-6, -1e-5, -2.000000005684342e-5 }, .meet = .sliver_in_common },
    .{ .nudge = .{ -5e-6, -1e-5, -1e-5 }, .meet = .sliver_in_common },
    .{ .nudge = .{ 0, 1e-5, -2.000000005684342e-5 }, .meet = .edge_too_short },
    .{ .nudge = .{ 0, 1e-5, -1e-5 }, .meet = .below_feature_size },
    .{ .nudge = .{ 0, 5e-6, -2.000000005684342e-5 }, .meet = .made },
    .{ .nudge = .{ 0, 5e-6, -1e-5 }, .meet = .sliver_in_common_and_rest },
    .{ .nudge = .{ 0, -5e-6, -2.000000005684342e-5 }, .meet = .sliver_in_common },
    .{ .nudge = .{ 0, -5e-6, -1e-5 }, .meet = .sliver_in_common_and_rest },
    .{ .nudge = .{ 0, -1e-5, -2.000000005684342e-5 }, .meet = .edge_too_short },
    .{ .nudge = .{ 0, -1e-5, -1e-5 }, .meet = .below_feature_size },
};
/// The operands of the tests of an edge along a sloped face (the solids fuzzer's find bx,
/// as it drew them): a box, a plate (zone 1e-4, an intersection tolerance of 2e-4) whose
/// edge at x = 2.0002, z = 4 runs along y, and a hull whose face in the plane z = x +
/// 2.0001 (45°, `SLOPE_FACE_NORMAL` its outward normal) has that edge 2.1213e-4 below it.
const SLOPE_BOX = [2]Vec3{ .{ 2, 3, 2 }, .{ 3, 4, 4 } };
const SLOPE_BOX_MOVE: Vec3 = .{ -1, 1, 0 };
const SLOPE_PLATE = [2]Vec3{ .{ -98, -48, 2 }, .{ 2, 102, 3 } };
const SLOPE_PLATE_SCALE: Vec3 = .{ 1, 2, 2 };
const SLOPE_PLATE_NUDGE: Vec3 = .{ 1.9999999710098565e-4, 5e-5, -1e-15 };
const SLOPE_HULL = [_]Vec3{ .{ 2, 1, 1 }, .{ 1, 3, 0 }, .{ 1, 3, 4 }, .{ 0, 4, 1 }, .{ 1, 4, 0 }, .{ 4, 2, 3 }, .{ 0, 2, 4 } };
const SLOPE_HULL_AXIS: Vec3 = .{ 0, 1, 0 };
const SLOPE_HULL_SCALE: Vec3 = .{ 2, 0.5, 2 };
const SLOPE_HULL_NUDGE: Vec3 = .{ -5e-5, 5e-5, 5e-5 };
/// The hull's nudges in z in the tests about that find (the fuzzer's 5e-5): the plate's
/// edge from 1.84e-4 under the sloped face's plane (within the intersection tolerance) to
/// 2.62e-4 under it (past it by 0.62 of the zone), in steps of about 7e-6.
pub const SLOPE_LIFTS = [_]f64{ 1e-5, 2e-5, 3e-5, 4e-5, 5e-5, 6e-5, 7e-5, 8e-5, 1e-4, 1.2e-4 };
/// The last of `SLOPE_LIFTS` with the plate's edge within the intersection tolerance of the
/// hull's face's plane (1.98e-4 under it): from the next on the edge, its ends on the face
/// by their reach, lies past it, and the union is refused `below_feature_size` either way
/// round (`pave.runOnPlane`; Leo, 2026-11-24).
pub const SLOPE_LIFT_WITHIN: f64 = 3e-5;
/// How the three operands of those tests are turned together: in place and about three
/// skew axes (`SLIVER_TURNS` but its far shift, where the box's side and the plate's, 2e-4
/// apart in place, are the intersection tolerance to rounding and their union is refused
/// `at_tolerance` before the hull comes).
pub const SLOPE_TURNS = [_]@TypeOf(SLIVER_TURNS[0]){ SLIVER_TURNS[0], SLIVER_TURNS[2], SLIVER_TURNS[3], SLIVER_TURNS[4] };
/// The hull of those tests tilted alone about an axis through the middle of the plate's
/// edge along its sloped face (`SLOPE_EDGE_MIDDLE`), so the edge's height over the face's
/// plane changes along it: about x (along the edge's run, from 4 to 5 in y) and about z,
/// each by these angles, every union made (tilted 5e-5 the other way about x, the edge's
/// height at one end passes the intersection tolerance by more than the zone, refused
/// `gap_too_large`).
const SLOPE_TILT_AXES = [_]Vec3{ vec.X3, vec.Z3 };
const SLOPE_TILTS = [_]f64{ 1e-5, 2e-5, 5e-5, -2e-5 };
const SLOPE_EDGE_MIDDLE: Vec3 = .{ 2.0002, 4.5, 4 };
/// The hull's nudges in z of the tilted tests: the plate's edge from within the
/// intersection tolerance of the face's plane to past it.
const SLOPE_TILT_LIFTS = [_]f64{ 3e-5, 5e-5, 8e-5 };
/// The solids of the tests of a common block between two regions of both operands (the
/// nightly's find of 2026-11-21, by): a box whose top (z = 3.99995) and side (y = 3) meet
/// along the edge the result keeps, and the hull the fuzzer turned a quarter about y over
/// it, its top `TIE_DROPS` under 4 and its side in y = 3, its face x = 2.00005 cutting a
/// slab 2.5e-4 thick off the box's side x = 2.0003. Both tops and both sides are one plane
/// each (the tops 1.5e-4 apart at a tolerance of 2e-4), so the slab's top edge is a block
/// of an edge of each, with as many faces of each along it, and its corner at y = 3 a
/// triangle about the zone wide: 1.31e-7 on the box's line, 0.98e-7 on the hull's, against
/// 1.02e-7 for no sliver.
const TIE_BOX = [2]Vec3{ .{ 1, 1, 0.99995 }, .{ 2.0003, 3, 3.99995 } };
const TIE_HULL = [_]Vec3{ .{ 2.00005, 0, 0 }, .{ 4.00005, -1, 2 }, .{ 4.00005, 3, 4 }, .{ 3.00005, 3, 1 }, .{ 2.00005, 2, 4 }, .{ 3.00005, 1, 4 }, .{ 2.00005, 3, 4 } };
/// How far under 4 the hull's top is, and so how far under the box's (5e-5 less): the
/// find's, within the zone and the tolerance of the box's, and at its edge.
const TIE_DROPS = [_]f64{ 2e-4, 1e-4, 1.5e-4, 2.4e-4 };
/// The zones of the box and the hull: the find's, and the other way round.
const TIE_ZONES = [_][2]f64{ .{ 1e-4, 1e-5 }, .{ 1e-5, 1e-4 } };
/// The one zone of both operands in the tests of a tie at one zone (the edge matrix's
/// coarse pair), how far the box's top lies under the hull's drawn top, and how far apart
/// the two tops are, in intersection tolerances: under half of it, the matrix's failing
/// half and nine tenths, and past it.
const TIE_EQUAL_ZONE = 1e-4;
const TIE_EQUAL_UNDER = 5e-5;
const TIE_EQUAL_RISES = [_]f64{ 0.25, 0.5, 0.75, 0.9, 1.1 };
/// The solids of the tests of a chain of edges along two parallel lines (the first
/// ReleaseSafe session's find of 2026-11-22, cd, as the solids fuzzer drew them): a hull
/// whose face toward -x is crossed by a box's bottom (zone 1e-5) at z = 2 less the box's
/// nudge and by a plate's top (zone 1e-4, an intersection tolerance of 2e-4) at z =
/// 1.9999. The hull less the box, cut by the plate, keeps on that face a chain of four
/// vertices: two where the plate's top crosses its edges, two where the box's bottom
/// does, on two lines parallel within the face, 9e-5 apart in z.
const CHAIN_HULL = [_]Vec3{ .{ 1, 2, 2 }, .{ 1, 0, 4 }, .{ 2, 0, 0 }, .{ 1, 4, 0 }, .{ 2, 4, 0 }, .{ 4, 4, 2 } };
const CHAIN_HULL_MOVE: Vec3 = .{ -0.5, 0, 0 };
const CHAIN_HULL_NUDGE: Vec3 = .{ 0, -2e-3, 0 };
const CHAIN_BOX = [2]Vec3{ .{ 0.5, 0, 2 }, .{ 3.5, 1, 3 } };
const CHAIN_BOX_NUDGE: Vec3 = .{ 0, -1e-5, -1e-5 };
const CHAIN_PLATE = [2]Vec3{ .{ -48, -49, 0 }, .{ 52, 101, 2 } };
const CHAIN_PLATE_NUDGE: Vec3 = .{ 2e-4, 0, -1e-4 };
/// The box's nudges in z: the find's, its bottom 9e-5 over the plate's top, and its
/// neighbours from 1e-5 over to 1.5e-4 over, within the intersection tolerance.
const CHAIN_DROPS = [_]f64{ -1e-5, -9e-5, -5e-5, 0, 5e-5 };
/// How the three solids are moved together: in place, `SLIVER_TURNS`, and the fuzzer's
/// move of the find, a turn of 0.3 about x and a shift 2.3e3 out.
const CHAIN_MOVES = SLIVER_TURNS ++ [_]@TypeOf(SLIVER_TURNS[0]){.{ .axis = vec.X3, .angle = 0.3, .shift = .{ 1e3, -2e3, 500 } }};
/// The boxes of the tests of two faces in one plane a hair apart sharing a region (the
/// solids fuzzer's find ca, 2026-11-21): A's bottom in y = 0, x from 0 to 2, and B's in y =
/// `SHARED_GAPS` (within the intersection tolerance), x from 1 to `SHARED_B_ENDS`, the two
/// sharing x from 1 to 2. A's own region beside it is 1 long, B's 0.5, 1 or 1.5: a group
/// plane moving the operands' own fragments least is A's, a tie (the planes' fixed order)
/// or B's.
const SHARED_A = [2]Vec3{ .{ 0, 0, 0 }, .{ 2, 1, 1 } };
const SHARED_B_FROM: f64 = 1;
const SHARED_B_TOP: f64 = 1.5;
const SHARED_B_ENDS = [_]f64{ 2.5, 3, 3.5 };
const SHARED_GAPS = [_]f64{ 5e-6, 1e-5, 1.5e-5 };
/// The boxes of the tests of a common block between two regions of both operands, both
/// at one zone (find cq, 2026-11-22, the fuzzer's trimmed plate as the slab): the slab's
/// top, side and far end each in one plane with the box's, a hair apart, so the edge where
/// the slab's top meets its side is a block of an edge of each, with a region of both on
/// either side. The box's side `CORNER_SIDES` inside the slab's (at x = 2), its top
/// `CORNER_TOPS` under the slab's (at 2.000025).
const CORNER_SLAB = [2]Vec3{ .{ 1.998, 2.00002, 1.999965 }, .{ 2, 3.000005, 2.000025 } };
const CORNER_BOX = [2]Vec3{ .{ -1e-5, 1.00002, 1.00002 }, .{ 1.99999, 3.00002, 2.00002 } };
const CORNER_SIDES = [_]f64{ 5e-6, 1e-5, 1.5e-5 };
const CORNER_TOPS = [_]f64{ 5e-6, 1e-5, 1.5e-5 };
/// The least length of an edge `longLines` compares: the slab's edges along its length 1.
const CORNER_LONG: f64 = 0.5;
/// The hulls of the tests of a gap measured between two pieces in a face's plane (find co,
/// 2026-11-22), placed as the solids fuzzer placed them: the first turned a half turn
/// about x through the grid's middle (2, 2, 2), moved (0, -0.5, 0) and nudged
/// (`GAP_NUDGES_X`, 0, down `GAP_DROPS`), the second moved (0, 0, -1) and nudged (5e-6,
/// -1e-5, 0). A block of the second's face and a section of the first lie the drop apart
/// in that face's plane; the drops step by the coordinates' rounding (2^-51 at their size)
/// across D27's band above the intersection tolerance, the fuzzer's own at its edge.
const GAP_FIRST = [_]Vec3{ .{ 3, 1, 3 }, .{ 1, 3, 2 }, .{ 0, 4, 3 }, .{ 0, 3, 3 }, .{ 1, 4, 0 }, .{ 2, 4, 3 } };
const GAP_SECOND = [_]Vec3{ .{ 4, 3, 1 }, .{ 3, 4, 3 }, .{ 4, 1, 0 }, .{ 3, 1, 3 }, .{ 0, 1, 1 }, .{ 1, 1, 2 } };
const GAP_MIDDLE: Vec3 = .{ 2, 2, 2 };
const GAP_FIRST_MOVE: Vec3 = .{ 0, -0.5, 0 };
const GAP_SECOND_MOVE: Vec3 = .{ 0, 0, -1 };
const GAP_SECOND_NUDGE: Vec3 = .{ 5e-6, -1e-5, 0 };
const GAP_NUDGES_X = [_]f64{ 1e-5, 5e-6, 0 };
const GAP_DROPS = [_]f64{ 2.000000005684342e-5, 2e-5 + 8 * 0x1p-51, 2e-5 + 11 * 0x1p-51, 2e-5 + 12 * 0x1p-51, 2e-5 + 13 * 0x1p-51, 2e-5 + 14 * 0x1p-51, 2e-5 + 16 * 0x1p-51 };
/// The solids of the tests of a thin plate's corner where two solids of a result touch (the
/// ReleaseSafe session's find on a1444371, 2026-11-21, bz), as the solids fuzzer drew them:
/// a hull turned a quarter about y, a plate `CORNER_THICKNESSES` intersection tolerances
/// thick (the find's 2.5: 5e-5) about z = 2 from (1, 3) to (3, 4) in x and y, and a second
/// hull, its two faces through the plate's corner edge at x = 3, y = 3: one a vertical
/// plane holding the edge, the other at 24° to it, holding it by reach alone (the edge
/// rises 2.04e-5 off that plane along its 5e-5). The intersection of the first hull and
/// the plate joined with the second keeps the plate's corner and a wedge of the two hulls,
/// touching along the edge: its four uses, the sloped face's one of them across its plane.
const CORNER_HULL_A = [_]Vec3{ .{ 0, 2, 3 }, .{ 3, 4, 4 }, .{ 2, 2, 3 }, .{ 1, 4, 3 }, .{ 1, 0, 1 } };
const CORNER_HULL_A_NUDGE: Vec3 = .{ -1e-5, -1.9999999943156583e-5, 1e-5 };
const CORNER_PLATE = [2]Vec3{ .{ 1, 3, 2 }, .{ 3, 4, 2 } };
const CORNER_PLATE_NUDGE: Vec3 = .{ 0, -1e-5, 2e-5 };
const CORNER_HULL_B = [_]Vec3{ .{ 1, 2, 2 }, .{ 0, 1, 0 }, .{ 3, 3, 3 }, .{ 4, 4, 0 }, .{ 2, 2, 3 } };
const CORNER_HULL_B_NUDGE: Vec3 = .{ 0, -1e-5, 5e-6 };
/// The plate's thickness in intersection tolerances (the fuzzer's gaps past the minimum
/// feature size): the corner edge 4.2e-5 to 6e-5 long, the sloped face rising 1.7e-5 to
/// 2.45e-5 off it along it, held by its reach at the first two, past it at the third.
const CORNER_THICKNESSES = [_]f64{ 2.1, 2.5, 3 };
/// The second hull's lift in z: where its sloped edge crosses the plate's corner edge,
/// along it (the find's 5e-6).
const CORNER_LIFTS = [_]f64{ 0, 5e-6, 1e-5, 2e-5 };
/// The solids of the tests of an edge two faces hold across their planes, each its two
/// uses (the nightly's find on 1ade5090, 2026-11-21, ce), as the solids fuzzer drew them: a
/// plate (zone 1e-4) and a wall 3 intersection tolerances thick (a box less a cavity,
/// `FUZZ_WALL_*`) about x = 2 from (3, 0, 0) to (4, 2, 4), moved 1 in y, joined; and a hull
/// moved (0.5, -1, 0) and `SLIT_DROPS` down. A section line 4.9e-4 long crosses the wall's
/// side y = 1 at 8° to it, the side's two pieces either side of it, and lies in a hull's
/// face at 33° to it as a slit, both by reach: four uses, two planes across.
const SLIT_PLATE = [2]Vec3{ .{ -48, -98, 1 }, .{ 2, 102, 2 } };
const SLIT_PLATE_NUDGE: Vec3 = .{ -2e-4, 5e-5, 1e-4 };
const SLIT_WALL_AT: Vec3 = .{ 2, 4, 0 };
const SLIT_WALL = [2]Vec3{ .{ 3, 0, 0 }, .{ 4, 2, 4 } };
const SLIT_WALL_XSECTS: f64 = 3;
const SLIT_WALL_MOVE: Vec3 = .{ 0, 1, 0 };
const SLIT_WALL_NUDGE: Vec3 = .{ 0, 0, -5e-5 };
const SLIT_HULL = [_]Vec3{ .{ 1, 4, 2 }, .{ 2, 3, 4 }, .{ 0, 4, 4 }, .{ 3, 4, 2 }, .{ 0, 3, 0 }, .{ 0, 4, 3 }, .{ 3, 1, 2 } };
const SLIT_HULL_MOVE: Vec3 = .{ 0.5, -1, 0 };
/// How far the hull is moved down: the find's, and a quarter of the plate's tolerance
/// either side of it.
const SLIT_DROPS = [_]f64{ 1.999999999431566e-4, 1.5e-4, 2.5e-4 };
/// The solids fuzzer's wall (`GapShape.wall` in fuzz_test.zig): the box behind the gap
/// this deep, and its cavity inset this far from the box's other sides.
const FUZZ_WALL_DEPTH: f64 = 1.5;
const FUZZ_WALL_INSET: f64 = 0.25;
/// The solids of the tests of two faces taken for one plane whose boundaries pass each
/// other beyond the tolerance (the ReleaseSafe session on ff515852, dd, as the fuzzer drew
/// them): a hull with a face in y = 2, and a wall whose face beside its gap lies 1.8e-5 to
/// 2.0e-5 off it, turned `CROSS_WALL_TURNS` about `CROSS_WALL_AXIS`; the wall's edge from a
/// corner inside the hull's face runs out past the hull's edge 2.0e-5 from it.
const CROSS_HULL = [_]Vec3{ .{ 2, 2, 4 }, .{ 1, 2, 1 }, .{ 0, 2, 2 }, .{ 0, 0, 2 }, .{ 4, 2, 4 } };
const CROSS_HULL_NUDGE: Vec3 = .{ -2e-3, 0, 5e-6 };
const CROSS_WALL_AT: Vec3 = .{ 2, 2, 2 };
const CROSS_WALL_LO: Vec3 = .{ 3, 2, 1 };
const CROSS_WALL_HI: Vec3 = .{ 4, 4, 3 };
const CROSS_WALL_XSECTS: f64 = 2.1;
const CROSS_WALL_AXIS: Vec3 = .{ 1, 2, 3 };
/// The wall's turn: the find's, and a tenth and three times it.
const CROSS_WALL_TURNS = [_]f64{ 1e-6, 1e-7, 3e-6 };
/// The wall's nudge in y, which puts its face that far off the hull's: the find's 2e-5
/// (its corners 1.8e-5 to 2.0e-5 off after the turn), and a tenth of the tolerance either
/// side of it.
const CROSS_WALL_LIFTS = [_]f64{ 2e-5, 1.8e-5, 2.2e-5 };
const CROSS_WALL_NUDGE_X: f64 = -2e-3;
const CROSS_WALL_NUDGE_Z: f64 = -1.999999994315658e-5;
/// The solids of the tests of a section piece running across the line two faces meet
/// along (the nightly on ff515852, cz, and the ReleaseSafe session on ff515852, de, as the
/// fuzzer drew them). cz: (box ∪ wall − hull) ∪ hull, moved whole.
const ACROSS_BOX = [2]Vec3{ .{ 1, 2, 1 }, .{ 2, 4, 3 } };
const ACROSS_BOX_NUDGE: Vec3 = .{ -2e-5, 5e-6, -1.9999999943156583e-5 };
const ACROSS_WALL_AT: Vec3 = .{ 2, 3, 0 };
const ACROSS_WALL_LO: Vec3 = .{ 3, 1, 1 };
const ACROSS_WALL_HI: Vec3 = .{ 4, 2, 4 };
const ACROSS_WALL_XSECTS: f64 = 3;
const ACROSS_WALL_MOVE: Vec3 = .{ 0, 1, 0 };
const ACROSS_WALL_NUDGE: Vec3 = .{ 0, 0, -5e-6 };
const ACROSS_CUT = [_]Vec3{ .{ 4, 4, 2 }, .{ 2, 0, 4 }, .{ 4, 4, 4 }, .{ 4, 4, 2 }, .{ 0, 3, 0 }, .{ 0, 4, 3 }, .{ 4, 1, 2 } };
const ACROSS_CUT_NUDGE: Vec3 = .{ 5e-6, -2e-3, -1e-5 };
const ACROSS_JOIN = [_]Vec3{ .{ 0, 0, 4 }, .{ 1, 3, 1 }, .{ 0, 0, 0 }, .{ 4, 2, 4 }, .{ 0, 0, 2 } };
const ACROSS_JOIN_SCALE: Vec3 = .{ 1, 0.5, 0.5 };
const ACROSS_JOIN_NUDGE: Vec3 = .{ 5e-6, -1e-5, -2e-5 };
/// The chain moved whole: in place, the find's move, and two of `SLIVER_TURNS`' turns.
const ACROSS_WHOLE = [_]@TypeOf(SLIVER_TURNS[0]){
    .{ .axis = vec.Z3, .angle = 0, .shift = vec.ZERO3 },
    .{ .axis = vec.Z3, .angle = 0.3, .shift = .{ 1e5, -2e5, 3e5 } },
    .{ .axis = vec.Z3, .angle = 0.3, .shift = vec.ZERO3 },
    SLIVER_TURNS[1],
};
/// dl: (hull ∪ a plate with a gap) and a wall with a gap, as the solids fuzzer drew them:
/// a section segment's middle outside the hull's face and the tolerance to rounding from an
/// edge of the wall's.
const BESIDE_HULL = [_]Vec3{ .{ 1, 4, 4 }, .{ 3, 4, 1 }, .{ 2, 1, 2 }, .{ 2, 0, 1 }, .{ 0, 1, 4 }, .{ 4, 4, 1 } };
const BESIDE_HULL_TURN: f64 = 1e-6;
const BESIDE_HULL_MOVE: Vec3 = .{ -0.5, 0, 0 };
const BESIDE_HULL_NUDGE: Vec3 = .{ 0, -1e-5, -1e-5 };
const BESIDE_PLATE_AT: Vec3 = .{ 0, 2, 2 };
const BESIDE_GAP_LO: Vec3 = .{ 3, 2, 1 };
const BESIDE_GAP_HI: Vec3 = .{ 4, 4, 3 };
const BESIDE_GAP_XSECTS: f64 = 2.1;
const BESIDE_PLATE_TURN: f64 = 0.7853981633974483;
const BESIDE_PLATE_MOVE: Vec3 = .{ 0, 0, 1 };
const BESIDE_PLATE_NUDGE: Vec3 = .{ 2.0000000068616077e-5, -5e-6, 0 };
const BESIDE_WALL_AT: Vec3 = .{ 2, 2, 3 };
const BESIDE_WALL_NUDGE_XY = [2]f64{ 2e-3, -1e-5 };
/// The wall's nudge in z: the find's, the intersection tolerance and D27's band, and
/// steps of 2^-51 either side of it, across the band's edge.
const BESIDE_WALL_NUDGE_Z: f64 = 2.000000005684342e-5;
const BESIDE_STEP: f64 = 0x1p-51;
const BESIDE_STEPS = [_]f64{ 0, -3, -2, -1, 1, 2, 3 };
/// dk: (box − box) ∪ hull, as the solids fuzzer drew them: the block the difference leaves
/// touches the hull's face 2x + y = 6 along its edge x = 2, y = 2, through that face's
/// centroid. `TOUCH_LIFTS`: the hull's nudge in z (the find's first), the centroid along
/// the edge still.
const TOUCH_BOX = [2]Vec3{ .{ 1, 0, 1 }, .{ 2, 4, 3 } };
const TOUCH_BOX_NUDGE: Vec3 = .{ 0, -1e-5, -1e-5 };
const TOUCH_CUT = [2]Vec3{ .{ 1, 2, 0 }, .{ 2, 4, 3 } };
const TOUCH_CUT_NUDGE: Vec3 = .{ 5e-6, -2.000000005684342e-5, -2.000000005684342e-5 };
const TOUCH_HULL = [_]Vec3{ .{ 3, 3, 3 }, .{ 1, 4, 0 }, .{ 2, 2, 4 }, .{ 3, 0, 0 }, .{ 4, 0, 4 }, .{ 2, 4, 2 }, .{ 2, 2, 2 }, .{ 3, 1, 1 } };
const TOUCH_HULL_NUDGE_Y: f64 = -2.000000005684342e-5;
const TOUCH_LIFTS = [_]f64{ -2e-5, 0, 0.5, 1 };
/// dj: ((hull − wall) ∪ wall) and a box, as the solids fuzzer drew them: the hull's face
/// crosses the box's bottom and a wall's bottom 1.5e-5 under it.
const TRACE_HULL = [_]Vec3{ .{ 0, 4, 1 }, .{ 3, 0, 3 }, .{ 4, 0, 1 }, .{ 3, 3, 3 }, .{ 0, 4, 0 }, .{ 0, 1, 2 }, .{ 1, 3, 3 }, .{ 2, 1, 4 } };
const TRACE_HULL_AXIS: Vec3 = .{ 1, 2, 3 };
const TRACE_HULL_TURN: f64 = 0.014142253476507214;
const TRACE_HULL_SCALE: Vec3 = .{ 2, 1, 1 };
const TRACE_HULL_MOVE: Vec3 = .{ 0, 0, -0.5 };
const TRACE_HULL_NUDGE: Vec3 = .{ -5e-6, -2e-3, 0 };
const TRACE_CUT_AT: Vec3 = .{ 3, 4, 2 };
const TRACE_CUT_LO: Vec3 = .{ 0, 1, 1 };
const TRACE_CUT_HI: Vec3 = .{ 3, 2, 3 };
const TRACE_CUT_XSECTS: f64 = 2.5;
const TRACE_CUT_MOVE: Vec3 = .{ 0, -1, 0 };
const TRACE_CUT_NUDGE: Vec3 = .{ 1.9999999957367082e-5, 0, -2.000000004263292e-5 };
const TRACE_WALL_AT: Vec3 = .{ 3, 3, 3 };
const TRACE_WALL_LO: Vec3 = .{ 0, 1, 1 };
const TRACE_WALL_HI: Vec3 = .{ 3, 3, 4 };
const TRACE_WALL_XSECTS: f64 = 3;
const TRACE_WALL_MOVE: Vec3 = .{ 0.5, -1, 0 };
const TRACE_WALL_NUDGE: Vec3 = .{ 0, 0, -5e-6 };
const TRACE_BOX = [2]Vec3{ .{ 0, 1, 2 }, .{ 3, 4, 3 } };
const TRACE_BOX_TURN: f64 = 0.014142253477512098;
const TRACE_BOX_SCALE: Vec3 = .{ 1, 0.5, 0.5 };
const TRACE_BOX_MOVE: Vec3 = .{ -0.5, 0, 0 };
const TRACE_BOX_NUDGE: Vec3 = .{ 0, -2e-3, -5e-6 };
/// de: ((plate ∪ plate) − hull) ∩ a plate with a gap, the first plate and the last at a
/// zone of 1e-4.
const SPAN_PLATE = [2]Vec3{ .{ -48, -98, 0 }, .{ 102, 52, 2 } };
const SPAN_PLATE_ZONE: f64 = 1e-4;
const SPAN_PLATE_NUDGE: Vec3 = .{ -1.9999999855049283e-4, -1.9999999855049283e-4, 2e-4 };
const SPAN_STEP = [2]Vec3{ .{ 2, -98, 1 }, .{ 52, -48, 4 } };
const SPAN_STEP_SCALE: Vec3 = .{ 1, 1, 2 };
const SPAN_STEP_MOVE: Vec3 = .{ 0, -1, 0 };
const SPAN_STEP_NUDGE: Vec3 = .{ 0, 0, 1e-4 };
const SPAN_CUT = [_]Vec3{ .{ 3, 1, 0 }, .{ 4, 2, 0 }, .{ 0, 1, 4 }, .{ 2, 4, 0 }, .{ 4, 3, 4 }, .{ 2, 2, 0 }, .{ 4, 3, 1 }, .{ 1, 4, 3 } };
const SPAN_CUT_NUDGE: Vec3 = .{ -1e-4, -5e-5, 5e-5 };
const SPAN_GAP_AT: Vec3 = .{ 1, 1, 2 };
const SPAN_GAP_LO: Vec3 = .{ 0, 1, 1 };
const SPAN_GAP_HI: Vec3 = .{ 4, 3, 4 };
const SPAN_GAP_XSECTS: f64 = 2.1;
const SPAN_GAP_MOVE: Vec3 = .{ 1, 0, 0 };
/// The gap plate's nudge in y: the find's 5e-5, and none and twice it.
const SPAN_GAP_LIFTS = [_]f64{ 5e-5, 0, 1e-4 };
/// The solids of the tests of an edge lying in a face from its boundary to an apex inside
/// it (the cd fork's solids fuzz run, 2026-11-22, cg, as the fuzzer drew them): a
/// tetrahedron whose apex (3, 3.5, 2) lies on the hull's face in the plane x - z = 1, its
/// edge to (0, 4.5, -1) in that plane, its faces along that edge one above the plane and
/// one below it; and the hull, moved by `SPUR_HULL_NUDGE` with its edge x = 3, z = 2 moved
/// back by the inset in x and in z, so the apex lies on the face √2 times the inset from
/// that edge and the tetrahedron's edge crosses it there. The piece of the edge on the face
/// is a spur of its fragment, from the boundary to the apex.
const SPUR_APEX = [_]Vec3{ .{ 2, 4.5, -1 }, .{ 3, 3.5, 2 }, .{ 0, 4.5, -1 }, .{ 0, 2.5, 0 } };
const SPUR_HULL = [_]Vec3{ .{ 1, 2, 2 }, .{ 1, 0, 3 }, .{ 1, 1, 1 }, .{ 4, 4, 3 }, .{ 3, 0, 2 }, .{ 3, 2, 4 }, .{ 3, 4, 2 }, .{ 1, 1, 4 } };
const SPUR_HULL_NUDGE: Vec3 = .{ 0, 2e-3, 0 };
/// The hull's edge moved back in x and in z: the find's (the intersection tolerance and
/// D27's band at these coordinates), within the tolerance (the apex on the edge), and
/// past it to 2.5 times it.
const SPUR_INSETS = [_]f64{ 2.000000005684342e-5, 1.5e-5, 2.5e-5, 3e-5, 5e-5 };
/// The solids of the tests of a hull's edge across a plate's end (the ReleaseSafe session's
/// find on ff515852, df, as the solids fuzzer drew it): a plate from x = 0.5 to 3.5 and y
/// = 1.99998 to 3.99998, its bottom at z = 1.999975, `END_THICKNESSES` intersection
/// tolerances thick; and a hull whose edge from (3, 4, 1) to (4, 0, 3) crosses the plane x
/// = 3.5 at z = 2, inside the plate's thickness, its face toward (3, 1, 0) leaving the
/// plate's end 17.5° off it toward the plate's inside, moved `END_SHIFTS` in y so the edge
/// crosses the end that far past y = 2.
const END_PLATE_LO: Vec3 = .{ 0.5, 1.99998, 1.999975 };
const END_PLATE_HI_XY = [2]f64{ 3.5, 3.99998 };
const END_HULL = [_]Vec3{ .{ 1, 4, 4 }, .{ 0, 4, 1 }, .{ 4, 0, 3 }, .{ 3, 4, 1 }, .{ 3, 1, 0 } };
/// The plate's thickness in intersection tolerances: the find's 3, past the least feature
/// (2) by a quarter, and thicker.
const END_THICKNESSES = [_]f64{ 2.5, 3, 4, 6 };
/// How far past y = 2 the hull's edge crosses the plate's end: the find's (2e-3), nearer
/// the plate's corner and farther from it.
const END_SHIFTS = [_]f64{ 2e-3, 5e-4, 2e-2, 0.2 };
/// The solids of the tests of a face a hair off parallel to a box's side, the tolerance
/// outside it (the first ReleaseSafe session's find on a1444371, ci, as the solids fuzzer
/// drew it): `OFFSET_HULL_A`, scaled and moved, and `OFFSET_HULL_B`, turned a hair about
/// `OFFSET_AXIS` and moved, whose face in y = 4 is nudged `OFFSET_LIFTS` out past the
/// box's side y = 4; the box from x = 2.5 to 4.5, its bottom 5e-6 under z = 0.
const OFFSET_HULL_A = [_]Vec3{ .{ 3, 3, 3 }, .{ 2, 1, 1 }, .{ 1, 0, 3 }, .{ 0, 3, 3 }, .{ 2, 2, 1 }, .{ 1, 0, 0 }, .{ 4, 4, 1 }, .{ 4, 1, 3 } };
const OFFSET_HULL_A_SCALE: Vec3 = .{ 0.5, 2, 1 };
const OFFSET_HULL_A_MOVE: Vec3 = .{ -1, 0, 0 };
const OFFSET_HULL_A_NUDGE: Vec3 = .{ 0, 1e-5, 1e-5 };
const OFFSET_HULL_B = [_]Vec3{ .{ 1, 3, 0 }, .{ 4, 3, 1 }, .{ 0, 4, 0 }, .{ 2, 4, 3 }, .{ 1, 4, 4 }, .{ 4, 1, 0 }, .{ 4, 4, 0 } };
const OFFSET_AXIS: Vec3 = .{ 1, 2, 3 };
const OFFSET_HULL_B_MOVE: Vec3 = .{ 1, 0, 0 };
const OFFSET_HULL_B_DROP: f64 = -2e-5;
const OFFSET_BOX = [2]Vec3{ .{ 2.5, 2, 0 }, .{ 4.5, 4, 4 } };
const OFFSET_BOX_NUDGE: Vec3 = .{ 0, 0, -5e-6 };
/// `OFFSET_HULL_B`'s turns about `OFFSET_AXIS`, either way: the find's, and 100 times it.
const OFFSET_TURNS = [_]f64{ 1e-9, -1e-9, 1e-7, -1e-7 };
/// How far `OFFSET_HULL_B`'s face in y = 4 is nudged out past the box's side: the find's,
/// the tolerance, and a hair either way of it.
const OFFSET_LIFTS = [_]f64{ 2e-5, 1.9999e-5, 2.00002e-5, 2.0001e-5 };
/// The solids of the tests of a hull's fin cut a hair under its tip (the ReleaseSafe fuzz
/// on 25411cf5, cl, as the solids fuzzer drew it): (`FIN_HULL_A` ∪ `FIN_HULL_B`) less
/// `FIN_HULL_C`, turned a half turn about y, a fin of the first hull standing over
/// `FIN_HULL_D`'s top, nudged `FIN_NUDGE` and `FIN_DROPS` in z: the find's 5e-6, its fin's
/// tip 8.2e-5 over that top, and a quarter of the tolerance either way.
const FIN_HULL_A = [_]Vec3{ .{ 4, 1, 2 }, .{ 2, 4, 0 }, .{ 0, 0, 0 }, .{ 4, 1, 0 }, .{ 3, 0, 0 }, .{ 2, 1, 4 } };
const FIN_HULL_A_NUDGE: Vec3 = .{ 0, -2.000000005684342e-5, 1e-5 };
const FIN_HULL_B = [_]Vec3{ .{ 3, 4, 3 }, .{ 2, 2, 4 }, .{ 1, 4, 4 }, .{ 4, 4, 2 }, .{ 4, 0, 2 }, .{ 2, 1, 2 } };
const FIN_HULL_B_SCALE: Vec3 = .{ 0.5, 0.5, 2 };
const FIN_HULL_B_MOVE: Vec3 = .{ -0.5, 0, 0 };
const FIN_HULL_B_NUDGE: Vec3 = .{ 0, -2.000000011368684e-5, 0 };
const FIN_HULL_C = [_]Vec3{ .{ 3, 4, 3 }, .{ 2, 1, 0 }, .{ 1, 3, 0 }, .{ 3, 2, 0 }, .{ 2, 3, 0 }, .{ 1, 0, 3 }, .{ 4, 1, 4 } };
const FIN_HULL_C_MOVE: Vec3 = .{ 0, -0.5, 0 };
const FIN_HULL_C_NUDGE: Vec3 = .{ 1e-5, 0, 0 };
const FIN_HULL_D = [_]Vec3{ .{ 3, 3, 2 }, .{ 0, 0, 2 }, .{ 4, 3, 0 }, .{ 0, 0, 0 }, .{ 3, 1, 2 }, .{ 0, 3, 0 } };
const FIN_NUDGE: Vec3 = .{ 1e-5, 2e-3, 0 };
const FIN_DROPS = [_]f64{ 5e-6, 0, 2.5e-6, 7.5e-6, 1e-5 };
/// The plate of the tests of a solid touching a face along a line through a pocket's mouth
/// (find cp): its side x = 2 the face, the pocket a box through it, its mouth the square y
/// and z from 1 to 2 in that face.
const KEYHOLE_PLATE = [2]Vec3{ .{ 0, -1, 0 }, .{ 2, 4, 4 } };
const KEYHOLE_POCKET = [2]Vec3{ .{ 1, 1, 1 }, .{ 3, 2, 2 } };
/// The touching solid's edge in the face, from beyond the plate's top: through the mouth's
/// corner (2, 2, 2) and on into the face (a bridge to the mouth and a spur past it, the
/// find's), ending at the corner (the bridge alone), beside the mouth (a slit, no hole:
/// the spur the overlap rules took out already), and across the face to beyond its bottom
/// (the face's two sides of it).
const KEYHOLE_EDGES = [_][2]Vec3{
    .{ .{ 2, 0.5, 5 }, .{ 2, 2.5, 1 } },
    .{ .{ 2, 0.5, 5 }, .{ 2, 2, 2 } },
    .{ .{ 2, 1, 5 }, .{ 2, 3, 1 } },
    .{ .{ 2, 2.5, 5 }, .{ 2, 3.5, -1 } },
};
/// How far the touching solid's other two corners stand off the face, either side of the
/// edge's middle in y.
const KEYHOLE_STANDOFF: f64 = 1;
const KEYHOLE_SPREAD: f64 = 1;
/// The hull of the tests of a ridge standing a hair over a box's bottom by its side (the
/// locus_solids ReleaseSafe find cv, 2026-11-22): its ridge from (0, 0, 3) to (4, 3, 3), its
/// face (4, 4, 1), (4, 3, 3), (1, 0, 1) running from the ridge's end down and back across
/// the box's corner, and the box over it, its bottom z = 3 and its side x = 4 through the
/// ridge's end.
const PEAK_HULL = [_]Vec3{ .{ 4, 4, 1 }, .{ 1, 0, 1 }, .{ 4, 3, 3 }, .{ 0, 0, 3 }, .{ 3, 3, 1 } };
const PEAK_BOX = [2]Vec3{ .{ 1, 2, 3 }, .{ 4, 5, 4 } };
/// How far the ridge stands over the box's bottom: the find's 4e-5, and nearer and farther,
/// each past the intersection tolerance.
const PEAK_RISES = [_]f64{ 4e-5, 3e-5, 6e-5 };
/// How far the ridge's end is moved past the box's side, within the intersection tolerance
/// (on the side by the paves' decision) and so far past the zone that a point of the face
/// beside it lies outside the side by more than the zone: the find's (the tolerance and
/// D27's band), and nearer.
const PEAK_PASTS = [_]f64{ 2.000000005684342e-5, 1.9e-5, 1.75e-5 };
/// How far the hull is turned about `PEAK_TURN_AXIS` through the fuzzer's grid middle
/// before it is moved: the find's 1e-9 and more (unturned, the ridge's face meets the
/// box's corner square and its seams decide it clearly).
const PEAK_TURNS = [_]f64{ 1e-9, 1e-7, 1e-6 };
const PEAK_TURN_AXIS: Vec3 = .{ 1, 2, 3 };
/// The solids of the tests of a hull's corner within the tolerance of a plate's side (the
/// nightly's locus_solids find dm on 9c931fef, as the solids fuzzer drew it): a plate
/// `SIDE_CORNER_XSECTS` intersection tolerances thick about z = 2, from (1, 2) to (4, 4) in
/// x and y, nudged `SIDE_CORNER_PLATE_NUDGE`, and the hull of `SIDE_CORNER_HULL` nudged
/// `SIDE_CORNER_HULL_NUDGE`: its corner (1, 3, 2) 1.5e-5 off the plate's side x = 1 inside
/// the plate's thickness, its edge to (1, 1, 1) along the side's plane, and its three faces
/// about the corner rising from that plane at 24° and more, so that the pieces of two of
/// them in the plate lie within the tolerance of the side.
const SIDE_CORNER_HULL = [_]Vec3{ .{ 2, 1, 4 }, .{ 1, 3, 2 }, .{ 4, 3, 0 }, .{ 1, 1, 1 }, .{ 2, 4, 0 }, .{ 2, 1, 0 } };
const SIDE_CORNER_HULL_NUDGE: Vec3 = .{ -5e-6, 5e-6, 5e-6 };
const SIDE_CORNER_PLATE = [2]Vec3{ .{ 1, 2, 2 }, .{ 4, 4, 2 } };
const SIDE_CORNER_PLATE_NUDGE: Vec3 = .{ 1e-5, 5e-6, 1e-5 };
const SIDE_CORNER_XSECTS: f64 = 3;
/// How far the hull is moved in x beyond the find's nudge with the corner within the
/// tolerance of the side, off its plane: 1.5e-5 off it (the find's), 1e-5 and 1.8e-5.
const SIDE_CORNER_WITHIN = [_]f64{ 0, 5e-6, -3e-6 };
/// And with the corner in the side's plane, a hair past the tolerance (2.1e-5 off it) and
/// past it (2.5e-5).
const SIDE_CORNER_BESIDE = [_]f64{ 1.5e-5, -6e-6, -1e-5 };

/// The operands of the tests of a face's own pave block lying in another's face (the
/// nightly's locus_solids find dn, 2026-11-24, as the fuzzer drew it): a box, less a hull,
/// joined with a hull whose face at x = 4 rises above the box's top edge, then a hull whose
/// base edge runs along that edge 1.5e-5 off it across and along, its ends merged onto the
/// box's edge within their reach.
const OWN_BOX = [2]Vec3{ .{ 0, 1, 1 }, .{ 2, 4, 4 } };
const OWN_BOX_SCALE: Vec3 = .{ 2, 0.5, 0.5 };
const OWN_BOX_NUDGE: Vec3 = .{ 1e-5, 5e-6, -5e-6 };
const OWN_CUT = [_]Vec3{ .{ 3, 2, 3 }, .{ 4, 1, 2 }, .{ 1, 4, 3 }, .{ 1, 3, 3 }, .{ 1, 0, 0 } };
const OWN_CUT_TURN: f64 = 0.014142253478516982;
const OWN_CUT_SCALE: Vec3 = .{ 1, 0.5, 1 };
const OWN_CUT_MOVE: Vec3 = .{ 0.5, 1, 0 };
const OWN_CUT_NUDGE: Vec3 = .{ 0, 0, 1.999999993585303e-5 };
const OWN_JOIN = [_]Vec3{ .{ 4, 1, 4 }, .{ 4, 2, 0 }, .{ 3, 2, 4 }, .{ 2, 4, 3 }, .{ 4, 3, 0 }, .{ 2, 0, 0 } };
const OWN_JOIN_MOVE: Vec3 = .{ 0, 0, -1 };
const OWN_JOIN_NUDGE: Vec3 = .{ 2.000000005684342e-5, 2e-5, 0 };
const OWN_LAST = [_]Vec3{ .{ 0, 0, 2 }, .{ 3, 4, 2 }, .{ 4, 0, 2 }, .{ 3, 3, 3 }, .{ 0, 1, 2 }, .{ 4, 4, 2 } };
/// The last hull's nudges in the tests about that find: the fuzzer's, and its base edge
/// nearer the box's edge and farther, either side of the merged ends' reach.
const OWN_LAST_NUDGES = [_]Vec3{
    .{ 0, 0, -1.9999999943156583e-5 },
    .{ 0, 0, -1e-5 },
    .{ 0, 0, -1.5e-5 },
    .{ 0, 0, -2.5e-5 },
    .{ 5e-6, 0, -2e-5 },
    .{ -5e-6, 0, -2e-5 },
};

fn polyhedron(points: []const Vec3, triangles: []const [3]u32) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return primitives.polyhedron(testing.allocator, tol, points, triangles, &diag);
}

/// A tetrahedron on `apex` and three other corners, wound outward.
fn tetrahedron(apex: Vec3, p: Vec3, q: Vec3, r: Vec3) !Body {
    // Outward: the base seen from the apex runs clockwise
    const n = vec.cross(vec.sub(q, p), vec.sub(r, p));
    const flip = vec.dot(n, vec.sub(apex, p)) > 0;
    const base: [3]u32 = if (flip) .{ 1, 3, 2 } else .{ 1, 2, 3 };
    return polyhedron(&.{ apex, p, q, r }, &.{ base, .{ 0, base[1], base[0] }, .{ 0, base[2], base[1] }, .{ 0, base[0], base[2] } });
}

/// `op` of `a` and `b` refused as lying at the intersection tolerance to rounding.
fn expectAtTolerance(a: *const Body, b: *const Body, op: pipeline.Op) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    if (pipeline.boolean(testing.allocator, a, b, op, .{}, &diag, null)) |result| {
        var made = result;
        made.deinit();
        std.debug.print("boolean {s}: a result, where the tolerance to rounding was expected\n", .{@tagName(op)});
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(error.Degenerate, err);
        try testing.expectEqual(diagnostics.Code.at_tolerance, diag.first().?.code);
    }
}

fn warned(diag: *const Diagnostics, code: diagnostics.Code) usize {
    var n: usize = 0;
    for (diag.findings.items) |f| n += @intFromBool(f.severity == .warning and f.code == code);
    return n;
}

test "degeneracy: identical boxes" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    try expectShape(&u, 8, 6, 1);
    var d = try sound(&a, &b, .difference);
    defer d.deinit();
    try testing.expect(d.isEmpty());
    try expectIdentities(&a, &b);
}

test "degeneracy: a cube inside a cube, and a cube-shaped void filled" {
    var outer = try box(.{ 0, 0, 0 }, .{ 4, 4, 4 });
    defer outer.deinit();
    var inner = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer inner.deinit();
    var u = try sound(&outer, &inner, .@"union");
    defer u.deinit();
    try expectShape(&u, 64, 6, 1);
    var i = try sound(&outer, &inner, .intersection);
    defer i.deinit();
    try expectShape(&i, 8, 6, 1);
    var hollow = try sound(&outer, &inner, .difference);
    defer hollow.deinit();
    try testing.expectEqual([2]usize{ 1, 1 }, shellKinds(&hollow));
    var filled = try sound(&hollow, &inner, .@"union");
    defer filled.deinit();
    try expectShape(&filled, 64, 6, 1);
    var none = try sound(&hollow, &inner, .intersection);
    defer none.deinit();
    try testing.expect(none.isEmpty());
    try expectIdentities(&outer, &inner);
    try expectIdentities(&hollow, &inner);
}

test "degeneracy: faces touching with equal normals, a box in another's corner" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var b = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    try expectShape(&u, 8, 6, 1);
    var d = try sound(&a, &b, .difference);
    defer d.deinit();
    // Three faces notched, three whole, the notch's three
    try expectShape(&d, 7, 9, 1);
    try expectIdentities(&a, &b);
}

test "degeneracy: faces touching with opposite normals, whole and in part" {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var b = try box(.{ 1, 0, 0 }, .{ 2, 1, 1 });
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    try expectShape(&u, 2, 6, 1);
    try expectIdentities(&a, &b);
    // Coplanar overlap: a box stacked across another's top, the faces sharing a unit square
    var low = try box(.{ 0, 0, 0 }, .{ 2, 2, 1 });
    defer low.deinit();
    var high = try box(.{ 1, 1, 1 }, .{ 3, 3, 2 });
    defer high.deinit();
    var stacked = try sound(&low, &high, .@"union");
    defer stacked.deinit();
    try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&stacked));
    try testing.expectApproxEqAbs(@as(f64, 8), try volume(&stacked), CLOSE);
    var touch = try sound(&low, &high, .intersection);
    defer touch.deinit();
    try testing.expect(touch.isEmpty());
    try expectIdentities(&low, &high);
}

test "degeneracy: an edge lying on a face, inside it, and an edge on an edge" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    // A unit cube turned 45° about y, its lowest edge along y on the top face's middle
    var unit = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer unit.deinit();
    var leaning = try turned(&unit, .{ 0, 0, 0 }, vec.Y3, -std.math.pi / 4.0);
    defer leaning.deinit();
    var on_edge = try helpers.moved(&leaning, .{ 1, 0.5, 2 });
    defer on_edge.deinit();
    var u = try sound(&a, &on_edge, .@"union");
    defer u.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&u));
    try testing.expectApproxEqAbs(@as(f64, 9), try volume(&u), CLOSE);
    var d = try sound(&a, &on_edge, .difference);
    defer d.deinit();
    try testing.expectApproxEqAbs(@as(f64, 8), try volume(&d), CLOSE);
    try expectIdentities(&a, &on_edge);
    // Edge on edge, overlapping for half their length: two solids, a common block
    var b = try box(.{ 0, 0, 0 }, .{ 2, 1, 1 });
    defer b.deinit();
    var c = try box(.{ 1, 1, 1 }, .{ 3, 2, 2 });
    defer c.deinit();
    var pair = try sound(&b, &c, .@"union");
    defer pair.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&pair));
    try expectIdentities(&b, &c);
}

test "degeneracy: a vertex on a face, on an edge, on a vertex" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    // A tetrahedron's apex on the top face's middle, the rest above it
    var on_face = try tetrahedron(.{ 1, 1, 2 }, .{ 0.5, 0.5, 3 }, .{ 1.5, 0.5, 3 }, .{ 1, 1.5, 3 });
    defer on_face.deinit();
    var u = try sound(&a, &on_face, .@"union");
    defer u.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&u));
    try expectIdentities(&a, &on_face);
    // Its apex on the middle of the top front edge
    var on_edge = try tetrahedron(.{ 1, 0, 2 }, .{ 0.5, -0.5, 3 }, .{ 1.5, -0.5, 3 }, .{ 1, 0.5, 3 });
    defer on_edge.deinit();
    var v = try sound(&a, &on_edge, .@"union");
    defer v.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&v));
    try expectIdentities(&a, &on_edge);
    // Corner to corner
    var corner = try box(.{ 2, 2, 2 }, .{ 3, 3, 3 });
    defer corner.deinit();
    var w = try sound(&a, &corner, .@"union");
    defer w.deinit();
    try expectShape(&w, 9, 12, 2);
    try expectIdentities(&a, &corner);
}

test "degeneracy: a cut through three vertices exactly, and along two edges" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // x + y + z ≥ 2: the cube less the corner tetrahedron the plane cuts through three corners
    var through = try trim.trimByPlane(testing.allocator, &a, .{ 1, 1, 1 }, 2.0 / @sqrt(3.0), .{}, &diag, null);
    defer through.deinit();
    try testing.expectApproxEqAbs(@as(f64, 8 - 8.0 / 6.0), try volume(&through), 1e-9);
    try testing.expectEqual(@as(usize, 7), through.counts().faces);
    // x + y ≥ 2: along two vertical edges
    var along = try trim.trimByPlane(testing.allocator, &a, .{ 1, 1, 0 }, @sqrt(2.0), .{}, &diag, null);
    defer along.deinit();
    try testing.expectApproxEqAbs(@as(f64, 4), try volume(&along), 1e-9);
    try testing.expectEqual(@as(usize, 5), along.counts().faces);
    // The identity of a cut: its two sides make the whole
    for ([_]struct { Vec3, f64 }{ .{ .{ 1, 1, 1 }, 2.0 / @sqrt(3.0) }, .{ .{ 1, 1, 0 }, @sqrt(2.0) } }) |plane| {
        const sides = try trim.splitByPlane(testing.allocator, &a, plane[0], plane[1], .{}, &diag);
        var front = sides[0];
        defer front.deinit();
        var back = sides[1];
        defer back.deinit();
        try testing.expectApproxEqAbs(@as(f64, 8), try volume(&front) + try volume(&back), CLOSE);
    }
}

test "degeneracy: a knife edge, four faces at one line, two solids" {
    var plate = try box(.{ 0, 0, 0 }, .{ 2, 2, 1 });
    defer plate.deinit();
    var q1 = try box(.{ -1, -1, -1 }, .{ 1, 1, 2 });
    defer q1.deinit();
    var q3 = try box(.{ 1, 1, -1 }, .{ 3, 3, 2 });
    defer q3.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // The two other quarters of the plate are left, touching along x = y = 1
    var knife = try pipeline.chain(testing.allocator, &.{ &plate, &q1, &q3 }, .difference, .{}, &diag, null);
    defer knife.deinit();
    try expectShape(&knife, 2, 12, 2);
    try testing.expectEqual(@as(usize, 1), warned(&diag, .solids_touch));
    // The identities on each step of the chain
    try expectIdentities(&plate, &q1);
    var first = try sound(&plate, &q1, .difference);
    defer first.deinit();
    try expectIdentities(&first, &q3);
}

test "degeneracy: a mirrored copy united with its original, and a pocket flush with the top" {
    // A wedge with its square side on x = 0, mirrored across that plane: a whole prism
    const wedge_points = [_]Vec3{ .{ 0, 0, 0 }, .{ 0, 2, 0 }, .{ 0, 2, 2 }, .{ 0, 0, 2 }, .{ 1, 0, 0 }, .{ 1, 2, 0 } };
    const wedge_triangles = [_][3]u32{ .{ 0, 2, 1 }, .{ 0, 3, 2 }, .{ 0, 1, 5 }, .{ 0, 5, 4 }, .{ 0, 4, 3 }, .{ 1, 2, 5 }, .{ 2, 3, 4 }, .{ 2, 4, 5 } };
    var wedge = try polyhedron(&wedge_points, &wedge_triangles);
    defer wedge.deinit();
    var mirror = try helpers.mirrored(&wedge, vec.X3);
    defer mirror.deinit();
    var whole = try sound(&wedge, &mirror, .@"union");
    defer whole.deinit();
    try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&whole));
    try testing.expectApproxEqAbs(@as(f64, 4), try volume(&whole), CLOSE);
    // A pocket whose top is the top's plane: the top a face with a hole
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var pocket = try box(.{ 0.5, 0.5, 1 }, .{ 1.5, 1.5, 2 });
    defer pocket.deinit();
    var cut = try sound(&a, &pocket, .difference);
    defer cut.deinit();
    // Six faces, the top holed; the pocket's floor and four walls
    try expectShape(&cut, 7, 11, 1);
    try testing.expectEqual(@as(usize, 12), cut.counts().loops);
    try expectIdentities(&a, &pocket);
}

test "degeneracy: near-tangent gaps and overlaps of 1e-3 and 1e-6" {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    // Apart by 1e-3 (fifty intersection tolerances): two solids, the faces warned of
    var gap = try box(.{ 1 + 1e-3, 0, 0 }, .{ 2, 1, 1 });
    defer gap.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var apart = try pipeline.boolean(testing.allocator, &a, &gap, .@"union", .{}, &diag, null);
    defer apart.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&apart));
    try testing.expect(warned(&diag, .nearly_coplanar) >= 1);
    try expectIdentities(&a, &gap);
    // Overlapping by 1e-3: one solid, a slab that thin in common
    var lap = try box(.{ 1 - 1e-3, 0, 0 }, .{ 2, 1, 1 });
    defer lap.deinit();
    var slab = try sound(&a, &lap, .intersection);
    defer slab.deinit();
    try testing.expectApproxEqAbs(@as(f64, 1e-3), try volume(&slab), 1e-12);
    try expectIdentities(&a, &lap);
    // Apart and overlapping by 1e-6, within the zone: one solid, face to face; the vertices
    // moved to meet lay on the line the faces merged across, which simplification took
    // away with them, so the result is the exact box and says so
    for ([_]f64{ 1e-6, -1e-6 }) |by| {
        var near = try box(.{ 1 + by, 0, 0 }, .{ 2, 1, 1 });
        defer near.deinit();
        var r = pipeline.Report.init(testing.allocator);
        defer r.deinit();
        var joined = try helpers.reported(&a, &near, .@"union", .{}, &r);
        defer joined.deinit();
        try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&joined));
        try testing.expectEqual(@as(usize, 6), joined.counts().faces);
        try testing.expectApproxEqAbs(@as(f64, 2), try volume(&joined), 1e-5);
        try testing.expectEqual(pipeline.Report.Quality.exact, r.quality());
        try testing.expect(r.coincident);
        var thin = try sound(&a, &near, .intersection);
        defer thin.deinit();
        try testing.expect(thin.isEmpty());
    }
}

test "degeneracy: a knife-edge wedge cut into a box" {
    var a = try box(.{ 0, 0, 0 }, .{ 4, 4, 2 });
    defer a.deinit();
    // A wedge 1e-3 wide at its back, sharp along x = 1 inside the box, through its height
    const w: f64 = 1e-3;
    const points = [_]Vec3{ .{ 1, 2, -1 }, .{ 5, 2 - w / 2, -1 }, .{ 5, 2 + w / 2, -1 }, .{ 1, 2, 3 }, .{ 5, 2 - w / 2, 3 }, .{ 5, 2 + w / 2, 3 } };
    const triangles = [_][3]u32{ .{ 0, 2, 1 }, .{ 3, 4, 5 }, .{ 0, 1, 4 }, .{ 0, 4, 3 }, .{ 1, 2, 5 }, .{ 1, 5, 4 }, .{ 2, 0, 3 }, .{ 2, 3, 5 } };
    var wedge = try polyhedron(&points, &triangles);
    defer wedge.deinit();
    var slit = try sound(&a, &wedge, .difference);
    defer slit.deinit();
    // The wedge's part within the box: a triangle of base w·3/4 and height 3, 2 deep
    const inside = 0.5 * (w * 3.0 / 4.0) * 3.0 * 2.0;
    try testing.expectApproxEqAbs(@as(f64, 32 - inside), try volume(&slit), 1e-9);
    try expectIdentities(&a, &wedge);
}

/// A V-shaped prism along y from `lo` to `hi`: its cross-section the triangle (1, 0), (2, 2),
/// (0, 2) in x and z, its bottom edge on z = 0.
fn vGroove(lo: f64, hi: f64) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var triangle = try primitives.polygon(testing.allocator, tol, &.{ .{ 1, 0 }, .{ 2, 2 }, .{ 0, 2 } }, &diag);
    defer triangle.deinit();
    var along = try @import("../construct/sweep.zig").extrude(testing.allocator, &triangle, .{ 0, 0, hi - lo }, .{}, &diag);
    defer along.deinit();
    // A quarter turn about x takes y to z and z to −y: the prism from y = −(hi − lo) to 0
    var stood = try turned(&along, .{ 0, 0, 0 }, vec.X3, std.math.pi / 2.0);
    defer stood.deinit();
    return helpers.moved(&stood, .{ 0, hi, 0 });
}

test "degeneracy: a V groove pinching the bottom to a line splits; a pocket pinched to a face is refused by design" {
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 1 });
    defer a.deinit();
    // A V groove right across, its bottom edge on the bottom face: two solids touching along it
    var groove = try vGroove(-1, 3);
    defer groove.deinit();
    var split = try sound(&a, &groove, .difference);
    defer split.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&split));
    // Each half a quadrilateral prism: the square less the groove's triangle at height ≤ 1
    try testing.expectApproxEqAbs(@as(f64, 4 - 2 * 0.5 * 1 * 0.5 * 2), try volume(&split), 1e-9);
    try expectIdentities(&a, &groove);
    // The same groove stopped short of the far side: one solid touching itself along the
    // bottom's line, which one shell cannot hold
    var short = try vGroove(-1, 1);
    defer short.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, &a, &short, .difference, .{}, &diag, null));
    try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
}

test "degeneracy: walls 1e-4 apart joined stay two solids, warned of" {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var b = try box(.{ 1 + 1e-4, 0, 0 }, .{ 2, 1, 1 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var joined = try pipeline.boolean(testing.allocator, &a, &b, .@"union", .{}, &diag, null);
    defer joined.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&joined));
    try testing.expectApproxEqAbs(@as(f64, 2 - 1e-4), try volume(&joined), CLOSE);
    try testing.expect(warned(&diag, .nearly_coplanar) >= 1);
    try expectIdentities(&a, &b);
}

test "degeneracy: a box's face 1.5e-4 off a plate's side plane and 2 across it, turned 0.3 rad: the two meet nowhere, as in place" {
    // The 10K fuzz session on 2b26eef1 (the solids moved whole): at a tolerance of 2e-4 a
    // box's face y = 2.00015 lies within it of the plane of a plate's side y = 2, the box
    // 2 above the plate. Turned 0.3 rad about y, the plate's box in its trees grew over
    // the other's and faceFace took the two faces for one plane, sharing no vertex; the
    // box's face was given the plate's plane, moved 1.5e-4, and a hull's corner 1.5e-4
    // over it was on it in place and off it turned. Faces that share no merged vertex do
    // not meet: either way the operands meet nowhere and keep their planes
    const t = Tolerance.fromZone(1e-4);
    var plate = try helpers.boxAt(t, .{ -48, -48, 0 }, .{ 52, 2, 1 });
    defer plate.deinit();
    var block = try helpers.boxAt(t, .{ 1, 1, 3 }, .{ 4, 2.00015, 4 });
    defer block.deinit();
    for ([_]f64{ 0, 0.3 }) |angle| {
        var a = try turned(&plate, .{ 0, 0, 0 }, .{ 0, 1, 0 }, angle);
        defer a.deinit();
        var b = try turned(&block, .{ 0, 0, 0 }, .{ 0, 1, 0 }, angle);
        defer b.deinit();
        var report = pipeline.Report.init(testing.allocator);
        defer report.deinit();
        var joined = try helpers.soundReported(&a, &b, .@"union", &report);
        defer joined.deinit();
        try testing.expect(report.by_containment);
        // The rounding of the turned corners alone; the box's face moved would be 4.5e-4
        try testing.expect(report.shift < CLOSE);
        try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&joined));
    }
}

test "degeneracy: operands moved to (1000, -700, 300)" {
    const far: Vec3 = .{ 1000, -700, 300 };
    var a = try box(far, vec.add(far, .{ 2, 2, 2 }));
    defer a.deinit();
    var b = try box(vec.add(far, .{ 1, 1, 1 }), vec.add(far, .{ 3, 3, 3 }));
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    try testing.expectEqual(@as(usize, 12), u.counts().faces);
    try testing.expectApproxEqAbs(@as(f64, 15), try volume(&u), 1e-8);
    var i = try sound(&a, &b, .intersection);
    defer i.deinit();
    try testing.expectApproxEqAbs(@as(f64, 1), try volume(&i), 1e-8);
    try expectIdentities(&a, &b);
}

/// A regular prism of `n` sides of circumradius `r` about `(cx, cy)`, from z = 0 to `h`.
fn prism(n: usize, r: f64, cx: f64, cy: f64, h: f64) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = try testing.allocator.alloc(vec.Vec2, n);
    defer testing.allocator.free(points);
    for (points, 0..) |*p, k| {
        const t = 2 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
        p.* = .{ cx + r * @cos(t), cy + r * @sin(t) };
    }
    var sheet = try primitives.polygon(testing.allocator, tol, points, &diag);
    defer sheet.deinit();
    return @import("../construct/sweep.zig").extrude(testing.allocator, &sheet, .{ 0, 0, h }, .{}, &diag);
}

test "degeneracy: two 1000-sided prisms overlapping, and 64 pegs joined to a plate" {
    var p = try prism(1000, 10, 0, 0, 5);
    defer p.deinit();
    var q = try prism(1000, 10, 5, 0, 5);
    defer q.deinit();
    try expectIdentities(&p, &q);
    var u = try sound(&p, &q, .@"union");
    defer u.deinit();
    try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&u));
    // 64 pegs standing on a plate, apart from each other: one solid
    var plate = try box(.{ 0, 0, 0 }, .{ 16, 16, 1 });
    defer plate.deinit();
    var pegs: [64]Body = undefined;
    var made: usize = 0;
    defer for (pegs[0..made]) |*g| g.deinit();
    for (0..8) |i| for (0..8) |j| {
        const x: f64 = @floatFromInt(2 * i);
        const y: f64 = @floatFromInt(2 * j);
        pegs[made] = try box(.{ x + 0.5, y + 0.5, 1 }, .{ x + 1.5, y + 1.5, 3 });
        made += 1;
    };
    var operands: [65]*const Body = undefined;
    operands[0] = &plate;
    for (pegs[0..made], operands[1..]) |*g, *o| o.* = g;
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var studded = try pipeline.chain(testing.allocator, &operands, .@"union", .{}, &diag, null);
    defer studded.deinit();
    try expectShape(&studded, 256 + 64 * 2, 6 + 64 * 5, 1);
}

test "degeneracy: a cut whose corner touches the face it was cut from is pinched at a point, and a void touching it so, refused by design" {
    // The solids fuzzer's first find (2026-11-13): a tetrahedron through a box's bottom, its
    // apex on the box's side from within; the pocket the difference leaves, open at the
    // bottom, meets that side at one point no edge records, inside one solid
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    var through = try tetrahedron(.{ 2, 1, 1 }, .{ 0.5, 0.5, -1 }, .{ 0.5, 1.5, -1 }, .{ 1.5, 1, -1 });
    defer through.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, &a, &through, .difference, .{}, &diag, null));
    try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
    var u = try sound(&a, &through, .@"union");
    defer u.deinit();
    try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&u));
    var i = try sound(&a, &through, .intersection);
    defer i.deinit();
    try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&i));
    // Wholly inside, the cut is a void touching the side at its corner: shells of one solid
    // touching, refused by design as the pocket is (Leo, 2026-11-14: a void apart from its
    // outer shell, as STEP's brep_with_voids holds it); union and intersection are sound
    var inside = try tetrahedron(.{ 2, 1, 1 }, .{ 1, 0.5, 0.5 }, .{ 1, 1.5, 0.5 }, .{ 1, 1, 1.5 });
    defer inside.deinit();
    diag.clear();
    try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, &a, &inside, .difference, .{}, &diag, null));
    try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
    var whole = try sound(&a, &inside, .@"union");
    defer whole.deinit();
    try expectShape(&whole, 8, 6, 1);
    var held = try sound(&a, &inside, .intersection);
    defer held.deinit();
    try testing.expectApproxEqAbs(try volume(&inside), try volume(&held), CLOSE);
    // From outside, the corner on the face makes two solids touching at a point, which pass
    var outside = try tetrahedron(.{ 2, 1, 1 }, .{ 3, 0.5, 0.5 }, .{ 3, 1.5, 0.5 }, .{ 3, 1, 1.5 });
    defer outside.deinit();
    var both = try sound(&a, &outside, .@"union");
    defer both.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&both));
    var cut = try sound(&a, &outside, .difference);
    defer cut.deinit();
    try expectShape(&cut, 8, 6, 1);
    // The identities where every result is made: the corner from outside
    try expectIdentities(&a, &outside);
}

test "degeneracy: a sliver one intersection tolerance thick, crossed by a face, kept or collapsed" {
    // The solids fuzzer's second find (2026-11-13), reduced: a box overlapping another by
    // the intersection tolerance and standing out of its top, its sides crossing the top in
    // pieces that long. Just past the tolerance the sliver is kept: the paves put such a
    // piece's far end off the top's edge while its middle is within the zone of it, and the
    // paves decide (the piece is imprinted); a sample of the sliver's strip on the other's
    // face gives way to the next one. Just within it the faces lie in one plane and the
    // operands touch. Either way the identities hold to the slab the tolerance may count
    // either way (its thickness times the face it lies on) and what the results' faces
    // moved onto their coplanar groups' planes (the reports' shift, D28): just within, the
    // union's face above the top is the top's plane, the sliver's height under it.
    const xsect = tol.xsect;
    var a = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer a.deinit();
    for ([_]f64{ 1 + 1e-6, 1 - 1e-6 }) |by| {
        var b = try box(.{ 0.5, -1, 1 }, .{ 1.5, xsect * by, 3 });
        defer b.deinit();
        var reports: [3]pipeline.Report = .{ .init(testing.allocator), .init(testing.allocator), .init(testing.allocator) };
        defer for (&reports) |*r| r.deinit();
        var u = try helpers.soundReported(&a, &b, .@"union", &reports[0]);
        defer u.deinit();
        try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&u));
        var i = try helpers.soundReported(&a, &b, .intersection, &reports[1]);
        defer i.deinit();
        var d = try helpers.soundReported(&a, &b, .difference, &reports[2]);
        defer d.deinit();
        const slab = xsect * 1 * 1;
        const vi = try volume(&i);
        if (by > 1) try testing.expectApproxEqAbs(slab * by, vi, 1e-12) else try testing.expect(i.isEmpty());
        const va = try volume(&a);
        const vb = try volume(&b);
        try testing.expectApproxEqAbs(va + vb, try volume(&u) + vi, slab + reports[0].shift + reports[1].shift);
        try testing.expectApproxEqAbs(va - vi, try volume(&d), slab + reports[1].shift + reports[2].shift);
    }
}

test "degeneracy: a cut parallel to an edge just past the intersection tolerance leaves end faces narrower than the zone, refused by design; farther, made" {
    // The 10K fuzz session's find (2026-11-14), reduced: a plane 2.4e-5 from a box's edge,
    // past the intersection tolerance so the paves keep the edge off it, its edge's side
    // kept, a prism whose ends are right triangles the zone in inradius. The paves decide
    // distances and keep everything past the tolerance distinct; how narrow a face may be
    // is the checker's sliver rule, which a cut a distance d from an edge of dihedral
    // angle θ meets with end faces of inradius d·sin(θ/2)/(1 + sin(θ/2)): 0.41·d at a right
    // angle, under the zone until d is 1.2 tolerances. A result the model cannot hold is
    // refused, as the builder refuses such a body, by the checker's own finding.
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    // (x − z)/√2 ≥ 1/√2 − d: the part within d of the edge x = 1, z = 0
    const normal: Vec3 = .{ 1, 0, -1 };
    const edge = 1.0 / @sqrt(2.0);
    {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        try testing.expectError(error.Degenerate, trim.trimByPlane(testing.allocator, &a, normal, edge - 1.1 * tol.xsect, .{}, &diag, null));
        errdefer std.debug.print("{f}\n", .{diag});
        try testing.expectEqual(diagnostics.Code.sliver_face, diag.first().?.code);
        try testing.expectEqual(diagnostics.EntityKind.face, diag.first().?.entity.kind);
    }
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const d = 1.5 * tol.xsect;
    var kept = try trim.trimByPlane(testing.allocator, &a, normal, edge - d, .{}, &diag, null);
    defer kept.deinit();
    var report = try check.run(testing.allocator, &kept, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    // A right triangle d from its hypotenuse is d² in area, the prism 1 long
    try testing.expectApproxEqRel(d * d, try volume(&kept), 1e-6);
    try testing.expectEqual(@as(usize, 5), kept.counts().faces);
}

test "degeneracy: a hull through a cavity and its wall 1.5 tolerances thick (once pieces of one face in different shells): the wall below the minimum feature size, refused" {
    // The 10K fuzz session's second find (2026-11-14), the chain's last step: the box cuts
    // a face of the hull into a piece inside the cavity and one outside the box with a
    // notch where the box is, both in the face's plane, in different shells. The overlap
    // rules' sample of the inner piece lies in the notch, in the outer piece's plane but
    // off it; the outer piece's solid angle summed by a fan from one corner, whose
    // triangles overlap outside a face that is not convex, cancelled only by the signs of
    // the rounding of each one's height, and the shell wound 1 there: "shell 0 lies in
    // material". The booleans were right; their results are sound, the identities hold.
    const coarse = Tolerance.fromZone(1e-4);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const corners = [_]Vec3{ .{ 1.999995, 2.5, 2e-5 }, .{ -5e-6, 1, 4.00002 }, .{ 3.999995, 1.5, 4.00002 }, .{ 1.999995, 2.5, 2.00002 } };
    var h = try @import("../construct/hull.zig").hull(testing.allocator, coarse, &corners, &diag);
    defer h.deinit();
    const half = 1.5 * coarse.xsect / 2;
    var outer = try helpers.boxAt(coarse, .{ 0.23, 1, 1 }, .{ 1.98 + half, 4, 3 });
    defer outer.deinit();
    var cavity = try helpers.boxAt(coarse, .{ 0.48, 1.25, 1.25 }, .{ 1.98 - half, 3.75, 2.75 });
    defer cavity.deinit();
    var wall = try sound(&outer, &cavity, .difference);
    defer wall.deinit();
    // Since the operand precondition (2026-11-15, Leo: one refusal before the paves in
    // place of those added find by find) the wall is below the boolean's minimum feature
    // size: refused whatever reaches it, every operation either way round.
    try expectBelowFeatureSize(&h, &wall);
}

test "degeneracy: a hull through a wall 1.25 tolerances thick into its cavity (once its section met the cavity's side by a gap): the wall below the minimum feature size, refused" {
    // The 10K fuzz session's third run (2026-11-14, locus_solids), reduced: a hull's face
    // crosses the wall's two sides, its section along the outer one from a corner merged
    // onto the wall's edge (a gap of 9.7e-6) to where a hull edge enters, which lies over
    // the cavity's side 2.5e-5 off. The overlap rules took that section as lying in the
    // cavity's plane by its reach (the tolerance and its ends' larger gap, 2.97e-5) and
    // both its ends as on it, so the union's outer shell touched its own void there,
    // "pinched"; the paves had kept that end apart by its own reach, 2e-5. An edge lying
    // in a plane meets it at those of its ends within their own reach.
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const corners = [_]Vec3{ .{ 1, 4, 2 }, .{ 3, 2, 1 }, .{ 1, 3, 1 }, .{ 4, 0, 2 }, .{ 4, 4, 2 }, .{ 0, 2, 1 }, .{ 3, 4, 1 } };
    var points: [corners.len]Vec3 = undefined;
    for (corners, &points) |c, *p| p.* = vec.add(c, .{ 5e-6, 0.5, -2e-5 });
    var h = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer h.deinit();
    const half = 1.25 * tol.xsect / 2;
    var outer = try box(.{ -1.25, 2.99998, -2e-5 }, .{ 0.5 + half, 3.99998, 1.99998 });
    defer outer.deinit();
    var cavity = try box(.{ -1, 3.24998, 0.24998 }, .{ 0.5 - half, 3.74998, 1.74998 });
    defer cavity.deinit();
    var wall = try sound(&outer, &cavity, .difference);
    defer wall.deinit();
    // Since the operand precondition (2026-11-15, Leo: one refusal before the paves in
    // place of those added find by find) the wall is below the boolean's minimum feature
    // size: refused whatever reaches it, every operation either way round.
    try expectBelowFeatureSize(&h, &wall);
}

test "degeneracy: a plate 1.9 tolerances thick with a hull's edge on its bottom (once the plane chosen for two bottoms): the plate below the minimum feature size, refused" {
    // The 10K fuzz session's fourth run (2026-11-14, locus), reduced: a plate 1.9
    // tolerances thick with a hull's edge 1.4e-5 over its bottom, lying on it, and a second
    // plate whose bottom is 1e-5 under the first's. The paves found the bottoms in one
    // plane; with the second plate first, the group took its plane, which held the first
    // bottom's corners but not the hull's edge on it (2.4e-5 off, past the tolerance the
    // checker holds an edge to): the union failed the checker, the operands swapped. The
    // plane chosen holds every piece's line too: the first bottom's, either way round.
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const half = 1.9 * tol.xsect / 2;
    var lower = try box(.{ 2, 1.00002, 3 - half + 1e-5 }, .{ 4, 4.00002, 3 + half + 1e-5 });
    defer lower.deinit();
    const corners = [_]Vec3{ .{ 0, 2, 3 }, .{ 1, 0, 4 }, .{ 4, 4, 3 }, .{ 4, 0, 0 }, .{ 0, 3, 2 }, .{ 1, 0, 2 }, .{ 0, 2, 2 } };
    var points: [corners.len]Vec3 = undefined;
    for (corners, &points) |c, *p| p.* = vec.add(c, .{ 1, 5e-6, 5e-6 });
    var h = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer h.deinit();
    // Since the operand precondition (2026-11-15) a plate 1.9 tolerances thick is below
    // the boolean's minimum feature size: the chain stops at its first step
    try expectBelowFeatureSize(&lower, &h);
}

test "degeneracy: a strip of a face under the other's face rising at 26.6°, no sample clear of it, takes its side from the faces at its section" {
    // The 10K fuzz session's fourth run (2026-11-14, locus_solids), reduced: a hull's
    // ridge lies in a box's side 2.5e-5 above the side's bottom edge, its far face rising
    // from it at 26.6° to the side. The strip of the side under the ridge is inside the
    // hull, but no point of it is farther than 1.1e-5 from the hull's face, so every sample
    // lay within the zone of its boundary (`unclassified`). A fragment bordering a piece of
    // the other's boundary takes its side from the faces there (OCCT's IsInternalFace; Leo,
    // 2026-11-14): under the ridge, behind both the hull's faces, it is inside.
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var a = try box(.{ 1.998, 3, 2.999995 }, .{ 3.998, 4, 3.999995 });
    defer a.deinit();
    var b = try @import("../construct/hull.zig").hull(testing.allocator, tol, &.{ .{ 1.99999, 3, 0.00002 }, .{ 3.99999, 0, 3.00002 }, .{ -0.00001, 0, 3.00002 }, .{ -0.00001, 4, 1.00002 }, .{ 3.99999, 3, 3.00002 }, .{ 0.99999, 3, 3.00002 } }, &diag);
    defer b.deinit();
    try expectProbe(&a, &b);
}

test "degeneracy: a tetrahedron's tip through a box's top by 2.45e-5, its section's every sample within the zone of it, takes its side from the faces at its sections" {
    // The section of a regular tetrahedron's tip 2.45e-5 through the top is an equilateral
    // triangle 3e-5 a side (past the intersection tolerance) and 8.7e-6 in inradius, so no
    // sample of it, nor of the tip's faces under the top, is farther than the zone from the
    // other operand; neither has a twin. Each takes its side from the faces about its
    // pieces (OCCT's IsInternalFace; Leo, 2026-11-14): the top's triangle behind the tip's
    // three faces, inside; the tip's faces under the top, inside. Made, or refused for the
    // slivers left, never unclassified.
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    const depth = 2.45e-5;
    // A regular tetrahedron of height 1 standing on its tip: its base's circumradius √2/2
    const r = @sqrt(2.0) / 2.0;
    var corners: [4]Vec3 = undefined;
    corners[0] = .{ 0.5, 0.5, 1 - depth };
    for (0..3) |k| {
        const angle = std.math.pi / 2.0 + @as(f64, @floatFromInt(k)) * 2.0 * std.math.pi / 3.0;
        corners[k + 1] = .{ 0.5 + r * @cos(angle), 0.5 + r * @sin(angle), 2 - depth };
    }
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var tip = try @import("../construct/hull.zig").hull(testing.allocator, tol, &corners, &diag);
    defer tip.deinit();
    try expectProbe(&a, &tip);
}

test "degeneracy: a face in one plane with a wall's side 1.25 tolerances off its cavity (once the plane chosen): the wall below the minimum feature size, refused" {
    // The 10K fuzz session's sixth run (2026-11-15, locus_solids), reduced: a block in a
    // wall's material above its cavity, its side 7.5e-6 inside the wall's outer side, one
    // plane with it. The group took the first operand's plane, the block's, and moved the
    // wall's whole side 7.5e-6 in, 1.75e-5 from the cavity's side it was 2.5e-5 from: the
    // union's void touched its outer shell (the overlap rules: pinched). The plane chosen
    // keeps every face it moves off its own operand's features: the wall's here.
    const xsect = tol.xsect;
    var outer = try box(.{ 0.25, 0, 0 }, .{ 2 + 0.625 * xsect, 4, 2 });
    defer outer.deinit();
    var cavity = try box(.{ 0.5, 0.25, 0.25 }, .{ 2 - 0.625 * xsect, 3.75, 1.75 });
    defer cavity.deinit();
    var wall = try sound(&outer, &cavity, .difference);
    defer wall.deinit();
    var block = try box(.{ 1.9, 0.5, 1.8 }, .{ 2 + 0.25 * xsect, 1, 2 });
    defer block.deinit();
    // Since the operand precondition (2026-11-15) the wall is below the boolean's minimum
    // feature size, refused before a plane is chosen
    try expectBelowFeatureSize(&block, &wall);
}

test "degeneracy: two walls' sides in one plane, each 1.25 tolerances off its cavity: each wall below the minimum feature size, refused" {
    // Each wall's side is 2.5e-5 from its own cavity's side and 3.75e-6 past the plane
    // between them, over a strip where the walls meet; either side's plane takes the other
    // within 1.75e-5 of its cavity, so no plane of the group holds both apart
    const xsect = tol.xsect;
    const half = 0.1875 * xsect;
    var outer_a = try box(.{ 0, 0, 0 }, .{ 2 + half, 4, 2 });
    defer outer_a.deinit();
    var cavity_a = try box(.{ 0.25, 0.25, 0.25 }, .{ 2 + half - 1.25 * xsect, 3.75, 1.75 });
    defer cavity_a.deinit();
    var a = try sound(&outer_a, &cavity_a, .difference);
    defer a.deinit();
    var outer_b = try box(.{ 2 - half, 0, 1.8 }, .{ 4, 4, 4 });
    defer outer_b.deinit();
    var cavity_b = try box(.{ 2 - half + 1.25 * xsect, 0.25, 2.05 }, .{ 3.75, 3.75, 3.75 });
    defer cavity_b.deinit();
    var b = try sound(&outer_b, &cavity_b, .difference);
    defer b.deinit();
    // Refused by the provenance's plane choice until the operand precondition
    // (2026-11-15), which refuses either wall before the paves
    try expectBelowFeatureSize(&a, &b);
}

test "degeneracy: a hull's edge within the tolerance of a plate's two front edges 2.5e-5 apart: the plate below the minimum feature size, refused" {
    // The nightly solids fuzzer (2026-11-14, locus_solids), reduced: a plate 1.25
    // tolerances thick, a hull's edge rising at 45° across its front 1.9e-5 from the top
    // edge and 1.8e-6 from the bottom one. Its crossing with the top edge welded to the
    // bottom one's vertex, 1.8e-5 along it, and the top edge's piece ended at that vertex
    // 2.56e-5 off its line (the checker: a vertex off its curve's end). A crossing welds to
    // a vertex only within its reach of both edges; beyond it, the features are closer
    // than the minimum feature size, refused either way round.
    var plate = try box(.{ -0.5, 1, -7.5e-6 }, .{ 1.5, 2, 1.75e-5 });
    defer plate.deinit();
    const corners = [_]Vec3{ .{ 1, 1, 2 }, .{ 4, 4, 1 }, .{ 1, 4, 0 }, .{ 0, 3, 3 }, .{ 0, 0, 0 } };
    var points: [corners.len]Vec3 = undefined;
    for (corners, &points) |c, *p| p.* = vec.add(c, .{ -5e-6, 1e-5, -1 });
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var hull = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer hull.deinit();
    // Refused at the weld (66cb4442) until the operand precondition (2026-11-15), which
    // refuses the plate, 2.5e-5 thick, before the paves
    try expectBelowFeatureSize(&plate, &hull);
}

test "degeneracy: a flat tetrahedron's face 3.8e-5 rad off a plate 1.25 tolerances thick, within the tolerance of its top and bottom at once: both below the minimum feature size, refused" {
    // The nightly solids fuzzer (2026-11-14, locus), reduced: a tetrahedron 1.9 tolerances
    // thick across a plate 1.25 thick, one top face rising 3.8e-5 rad from the plate's top
    // and within the tolerance of its top and its bottom at once over x 2.04–2.43. Their
    // sections, through merged vertices, lay at the band's edge, the face's piece over the
    // plate was classified against them (an edge with three faces), and with the plate
    // first the records made the union pinched and the intersection a sliver where the
    // tetrahedron first made both sound. No decision of the tolerance is consistent: the
    // plate's sides are closer than twice the tolerance where they do not meet, and the
    // face reaches both (Leo, 2026-11-15). Refused, every operation either way round. A
    // post crossing the plate steeply reaches both sides too, along its sections, which
    // lie 2.5e-5 apart where the paves put them: made and sound.
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var tet = try @import("../construct/hull.zig").hull(testing.allocator, tol, &.{ .{ 2, 3.99999, -9e-6 }, .{ 4, 3.99999, -9e-6 }, .{ 3, 2.99999, 2.9e-5 }, .{ 3, 4.99999, 2.9e-5 } }, &diag);
    defer tet.deinit();
    var plate = try box(.{ 1, 3, -1.25e-5 }, .{ 3, 4, 1.25e-5 });
    defer plate.deinit();
    // Refused as a face sandwiched between two (d1743fcd), and a post through the plate
    // made, until the operand precondition (2026-11-15): the plate, 2.5e-5 thick, and
    // the tetrahedron, its edges 3.8e-5 apart, are below the boolean's minimum feature
    // size, refused whatever reaches them
    try expectBelowFeatureSize(&tet, &plate);
    var post = try box(.{ 1.5, 3.2, -1 }, .{ 2.5, 3.8, 1 });
    defer post.deinit();
    try expectBelowFeatureSize(&post, &plate);
}

test "degeneracy: a hull's edge ending 3.1e-5 over a slot's bottom, its line 2.4e-5 (the plate below the minimum feature size, refused), and two hulls' difference: made and sound" {
    // The nightly solids fuzzer (2026-11-15, locus_solids and locus), reduced: a hull's
    // edge crosses a plate 1.9 tolerances thick at its front, 1.4e-5 under its top front
    // edge, where the paves merged their crossing with a gap of 6.8e-6. The overlap rules
    // took the edge's end as on the slot's bottom by its curve's end, 2.4e-5 off, and the
    // reach of the vertex (the tolerance and its gap): the vertex itself is 3.1e-5 off, and
    // the hull's top "touched" the slot's bottom, pinched. An end is on a plane by its
    // vertex's own reach, as the paves put a vertex on a face; so too two hulls' (an
    // intersection's leftover touching its own face).
    const Hull = struct {
        fn of(corners: []const Vec3, shift: Vec3) !Body {
            var points: [8]Vec3 = undefined;
            for (corners, 0..) |c, i| points[i] = vec.add(c, shift);
            var diag = Diagnostics.init(testing.allocator);
            defer diag.deinit();
            return @import("../construct/hull.zig").hull(testing.allocator, tol, points[0..corners.len], &diag);
        }
    };
    var wedge = try Hull.of(&.{ .{ 2, 4, 2.5 }, .{ 2, 2, 0.5 }, .{ 4, 2, 2.5 }, .{ 2, 0, 1.5 } }, .{ -2e-5, -2e-5, 0 });
    defer wedge.deinit();
    var plate = try box(.{ 0.999995, 2.00002, 2 - 1.4e-5 }, .{ 3.999995, 3.00002, 2 + 2.4e-5 });
    defer plate.deinit();
    // The plate, 3.8e-5 thick, is below the boolean's minimum feature size since the
    // operand precondition (2026-11-15): refused; the two hulls are made
    try expectBelowFeatureSize(&wedge, &plate);
    var first = try Hull.of(&.{ .{ 3, 0, 2 }, .{ 1, 2, 0 }, .{ 3, 4, 4 }, .{ 4, 4, 3 } }, .{ 2e-5, -2e-5, 2e-5 });
    defer first.deinit();
    var second = try Hull.of(&.{ .{ 4, 3, 1 }, .{ 4, 4, 0 }, .{ 0, 4, 4 }, .{ 1, 2, 3 }, .{ 2, 2, 2 }, .{ 4, 3, 0 }, .{ 3, 3, 2 }, .{ 2, 2, 0 } }, .{ -2e-5, -5e-6, 1e-5 });
    defer second.deinit();
    try expectIdentities(&first, &second);
    try expectIdentities(&second, &first);
}

test "degeneracy: a hull's ridge through a flat tetrahedron 1.5 tolerances thick (once a needle the overlap rules misjudged): the tetrahedron below the minimum feature size, refused" {
    // The nightly solids fuzzer (2026-11-15, locus_solids), reduced: a hull's top edge,
    // turned 0.014 rad, runs through a tetrahedron 1.5 tolerances thick, merged with its
    // upper faces with a gap of 7.4e-6; the hull's two faces there cut its lower edge
    // 4.4e-5 apart. The intersection is a needle 1.5 long and 2.8e-5 thick, each vertex
    // beyond the tolerance of every face it is not on. The overlap rules took an edge of
    // one face to lie in the other's plane by the edge's reach at both ends, the larger
    // end gap's: its end with none, 2.6e-5 off, lay in it, the two faces in one plane
    // (`faces_intersect`). An end is on a plane by its vertex's own reach.
    const Hull = struct {
        fn of(corners: []const Vec3, angle: f64, shift: Vec3) !Body {
            var points: [6]Vec3 = undefined;
            for (corners, 0..) |c, i| points[i] = vec.add(.{ @cos(angle) * c[0] - @sin(angle) * c[1], @sin(angle) * c[0] + @cos(angle) * c[1], c[2] }, shift);
            var diag = Diagnostics.init(testing.allocator);
            defer diag.deinit();
            return @import("../construct/hull.zig").hull(testing.allocator, tol, points[0..corners.len], &diag);
        }
    };
    var ridge = try Hull.of(&.{ .{ 3, 4, 4 }, .{ 1, 0, 4 }, .{ 3, 4, 2 }, .{ 0, 3, 1 }, .{ 0, 3, 2 }, .{ 3, 4, 1 } }, 0.014, .{ 1, 2e-5, 2e-5 });
    defer ridge.deinit();
    var flat = try Hull.of(&.{ .{ 2, 2, 4 - 1.5e-5 }, .{ 4, 2, 4 - 1.5e-5 }, .{ 3, 1, 4 + 1.5e-5 }, .{ 3, 3, 4 + 1.5e-5 } }, 0, .{ 0, -2e-5, 0 });
    defer flat.deinit();
    // The tetrahedron, its edges 3e-5 apart, is below the boolean's minimum feature size
    // since the operand precondition (2026-11-15): refused. 86b72d89's rule (an edge in a
    // plane by its ends' own reach) stays in the overlap rules, which check any body
    try expectBelowFeatureSize(&ridge, &flat);
}

test "degeneracy: a plate's top 1.8e-4 over a notch's ceiling, at a tolerance of 2e-4: a section and the notch's edge on one line stay two where joined they leave the plate's top, either way round" {
    // The 10K session (2026-11-15, locus_solids), reduced: a box less another leaves a
    // notch whose ceiling, z = 4.00002, is 1.8e-4 under a plate's top at a zone of 1e-4,
    // one plane. On the box's side the plate's top leaves a section whose line runs through
    // its merged vertices, from the plate's top down to the notch's corner; simplify joined
    // the notch's edge onto that line, its far end within the tolerance of the line, and
    // the joined edge ended 3.6e-4 under the plate's top (`edge_off_surface`, the plate
    // first). A join keeps an edge on its faces as the checker does
    var a = try box(.{ 0, 2e-5, 3.5 }, .{ 2, 3.00002, 4.5 });
    defer a.deinit();
    var b = try box(.{ 1.00002, 1.00002, 2e-5 }, .{ 4.00002, 4.00002, 4.00002 });
    defer b.deinit();
    var notched = try sound(&a, &b, .difference);
    defer notched.deinit();
    var plate = try helpers.boxAt(Tolerance.fromZone(1e-4), .{ -97.98, -48, 2.0002 }, .{ 102.02, 52, 4.0002 });
    defer plate.deinit();
    try helpers.expectIdentitiesAtTolerance(&plate, &notched);
    try helpers.expectIdentitiesAtTolerance(&notched, &plate);
}

test "degeneracy: a union's top moved 7e-5 onto a box's plane, a hull's top 1.8e-4 from that plane and 2.5e-4 from its edges: refused" {
    // The nightly (2026-11-15, locus), reduced: a box's top 7e-5 over a plate's, at the
    // plate's tolerance of 2e-4, one plane: the union's top takes the box's, the larger
    // (D28: the plane moving the faces least), its edges on the plate's lines below. A hull's top over it is within the tolerance of the
    // plane and beyond it of the top's edge inside the hull's top: the faces were taken as
    // one plane, the edge imprinted on the hull's top, which the paves had kept off it
    // (`imprint_unmatched`). No decision of the tolerance is consistent: refused, every
    // operation either way round.
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var small = try helpers.boxAt(Tolerance.fromZone(1e-5), .{ -49.50002, -48.00002, 2.00002 }, .{ 0.99998, 51.99998, 4.00002 });
    defer small.deinit();
    var plate = try helpers.boxAt(Tolerance.fromZone(1e-4), .{ -7.9998, -2.9999, 0.99995 }, .{ 2.0002, 12.0001, 3.99995 });
    defer plate.deinit();
    var joined = try pipeline.boolean(testing.allocator, &small, &plate, .@"union", .{}, &diag, null);
    defer joined.deinit();
    const corners = [_]Vec3{ .{ 3, 0, 4 }, .{ 1, 4, 2 }, .{ 4, 2, 4 }, .{ 4, 1, 3 }, .{ 4, 0, 2 }, .{ 1, 2, 4 } };
    var points: [corners.len]Vec3 = undefined;
    for (corners, &points) |c, *q| q.* = vec.add(c, .{ 0.5, 5e-5, 2e-4 });
    var hull = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer hull.deinit();
    for ([2][2]*const Body{ .{ &joined, &hull }, .{ &hull, &joined } }) |operands| {
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            var refusal = Diagnostics.init(testing.allocator);
            defer refusal.deinit();
            if (pipeline.boolean(testing.allocator, operands[0], operands[1], op, .{}, &refusal, null)) |made| {
                var result = made;
                result.deinit();
                return error.TestExpectedError;
            } else |e| {
                errdefer std.debug.print("{s}: {s}, {f}\n", .{ @tagName(op), @errorName(e), refusal });
                try testing.expectEqual(error.Degenerate, e);
                try testing.expectEqual(diagnostics.Code.below_feature_size, refusal.first().?.code);
                try testing.expect(std.mem.indexOf(u8, refusal.first().?.label, "its boundary inside that face beyond reach of its plane") != null);
            }
        }
    }
}

test "degeneracy: an edge lying across two coplanar faces of the other, touching them" {
    // The solids fuzzer's third find (2026-11-13): a box's edge lies in the plane of two
    // triangles of a hull (x + y = 3.5), across their shared diagonal, from one triangle's
    // edge to inside the other; merged, the hull's face holds the contact as a chain of
    // slits from its boundary, which simplification once took for a bridge and removed
    var a = try box(.{ 0.5, 0, 1 }, .{ 1.5, 2, 3 });
    defer a.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 1, 3.5, 1 }, .{ 4, -0.5, 4 }, .{ 0, 3.5, 2 }, .{ 1, 2.5, 2 }, .{ 1, 2.5, 4 } };
    var b = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&u));
    try expectIdentities(&a, &b);
}

test "degeneracy: an edge passing a box's edge within the tolerance and crossing its face at a shallow angle" {
    // The solids fuzzer's fifth find (2026-11-13), reduced: a hull's edge, direction
    // (1, 3, 3), passes 1.9e-5 from the box's edge at x = 0.5, y = 2 (within the
    // intersection tolerance, so edge–edge makes a vertex there) and crosses the box's face
    // x = 0.5 at 13° 5.7e-5 away; the box's edge crosses the hull's face 3x − z = 6e-5 as
    // near. Two more vertices there made the two faces meet along a bent chain both kept,
    // a fold the overlap rules refuse. An edge meets a plane once: the crossings are the
    // vertex the edges already have on the faces. The exact intersection's top is an edge
    // 6e-5 long that is now that vertex, 5.4e-5 above it: its volume, and the identities,
    // hold to that displacement times the result's area, well within the fuzzer's slab.
    // The hull as the fuzzer moved it, by the intersection tolerance exactly, puts an end of
    // its edge that far from the box's face to rounding; its other end lies on that face's
    // plane, which settles that the edge does not cross it, so the end at the tolerance
    // decides nothing: made and sound either way round (refused at_tolerance until the
    // paves asked both ends first, step 1 of closing M4); moved by 1.95e-5 the crossings
    // are as they were (moved by 1.9e-5, nothing folds even without the rule)
    var a = try box(.{ 0, 1, 1 }, .{ 0.5, 2, 3 });
    defer a.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 4, 3, 4 }, .{ 4, 4, 4 }, .{ 1, 4, 3 }, .{ 0, 1, 0 }, .{ 3, 3, 4 }, .{ 0, 4, 0 } };
    var b0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer b0.deinit();
    var at = try helpers.moved(&b0, .{ 2e-5, -0.5, 0 });
    defer at.deinit();
    for ([2][2]*const Body{ .{ &at, &a }, .{ &a, &at } }) |operands| {
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            var made = try sound(operands[0], operands[1], op);
            made.deinit();
        }
    }
    try helpers.expectIdentitiesAtTolerance(&at, &a);
    var b = try helpers.moved(&b0, .{ 1.95e-5, -0.5, 0 });
    defer b.deinit();
    var u = try sound(&b, &a, .@"union");
    defer u.deinit();
    var i = try sound(&b, &a, .intersection);
    defer i.deinit();
    var d = try sound(&b, &a, .difference);
    defer d.deinit();
    // The exact intersection, from its cross-sections in z (2026-11-13)
    const exact = 0.01666325428074834;
    const measured = try @import("../measure/mass.zig").mass(&i, .{}, &diag);
    const apex = 6e-5 * measured.area;
    const vi = measured.volume;
    try testing.expectApproxEqAbs(exact, vi, apex);
    try testing.expectEqual(@as(usize, 5), i.counts().faces);
    const va = try volume(&a);
    const vb = try volume(&b);
    try testing.expectApproxEqAbs(va + vb, try volume(&u) + vi, 2 * apex);
    try testing.expectApproxEqAbs(vb - vi, try volume(&d), 2 * apex);
}

test "degeneracy: vertices merged past the zone are refused, the vertex named" {
    // The solids fuzzer's sixth find (2026-11-13): a merged vertex's ball is the result's
    // vertex's gap, which the zone bounds; the gap a chain's earlier boolean recorded plus
    // half the distance to the other operand's vertex (or two vertices exactly the
    // intersection tolerance apart, the centre's rounding past the zone) made a result its
    // own last check refused. The merge refuses it, naming the vertex, at vertex–vertex
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var b = try box(.{ 1 + 1e-5, 1, 1 }, .{ 2, 2, 2 });
    defer b.deinit();
    var corner: ?usize = null;
    for (a.vertices.items, 0..) |v, i| {
        if (!v.tombstone and vec.distance(a.point(VertexIndex.of(i)), .{ 1, 1, 1 }) == 0) corner = i;
    }
    for ([_]f64{ 0.8e-5, 0.4e-5 }) |recorded| {
        a.vertices.items[corner.?].gap = recorded;
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        var r = pipeline.Report.init(testing.allocator);
        defer r.deinit();
        if (pipeline.boolean(testing.allocator, &a, &b, .@"union", .{}, &diag, &r)) |result| {
            var kept = result;
            kept.deinit();
            try testing.expect(recorded + 0.5e-5 <= tol.zone);
        } else |err| {
            const f = diag.first().?;
            if (recorded + 0.5e-5 <= tol.zone) {
                // Within the zone: whatever else the touching corners are, not this
                try testing.expect(f.code != .gap_too_large);
                continue;
            }
            try testing.expectEqual(error.Degenerate, err);
            try testing.expectEqual(diagnostics.Code.gap_too_large, f.code);
            try testing.expectEqual(diagnostics.EntityKind.vertex, f.entity.kind);
            try testing.expectEqual(@as(u32, @intCast(corner.?)), f.entity.index);
            try testing.expectApproxEqAbs(1.3e-5, f.measured, 1e-12);
            try testing.expectEqual(@as(?pipeline.Stage, .vertex_vertex), r.failed_in);
        }
    }
}

/// Whether some face of `body` has a loop of one vertex.
fn hasPointLoop(body: *const Body) bool {
    for (body.loops.items) |l| if (!l.tombstone and l.first == .none) return true;
    return false;
}

/// The containment table and the general path give the same body for `a` and `b` apart.
fn expectTableAgrees(a: *const Body, b: *const Body) !void {
    for ([_]pipeline.Op{ .@"union", .difference, .intersection }) |op| {
        var fast = pipeline.Report.init(testing.allocator);
        defer fast.deinit();
        var by_table = try helpers.reported(a, b, op, .{}, &fast);
        defer by_table.deinit();
        var slow = pipeline.Report.init(testing.allocator);
        defer slow.deinit();
        var by_path = try helpers.reported(a, b, op, .{ .fast_paths = false }, &slow);
        defer by_path.deinit();
        try testing.expect(fast.by_containment);
        try testing.expectEqual(by_path.counts(), by_table.counts());
        try testing.expectApproxEqAbs(try volume(&by_path), try volume(&by_table), CLOSE);
    }
}

test "degeneracy: a hole that was a lone slit leaves no point in the face; a point in a face is no fragment" {
    // The solids fuzzer's seventh find (2026-11-13): two boxes joined with a face in one
    // plane (y = 3), the first's corner edges lying in the second's face; merged, a hole of
    // the face was a lone slit, its spur's far vertex went and its near one was left a loop
    // of one vertex (the pass's edge counts, stale once a bridge had gone, said something
    // else used it). The next boolean, with a box apart, went by the containment table,
    // which sewed that loop as an empty one: an edge with three uses
    var a = try box(.{ 0.5, 0, 1 }, .{ 3.5, 3, 2 });
    defer a.deinit();
    var c = try box(.{ 3, 2, -0.5 }, .{ 5, 3, 3.5 });
    defer c.deinit();
    var joined = try sound(&a, &c, .@"union");
    defer joined.deinit();
    try testing.expect(!hasPointLoop(&joined));
    try expectIdentities(&a, &c);
    var above = try box(.{ 1.5, 1, 4 }, .{ 2.5, 2, 5 });
    defer above.deinit();
    try expectTableAgrees(&joined, &above);
    // A point in a face (a valid body: `mvh`) bounds nothing, on either path
    var dotted = try box(.{ 0, 0, 0 }, .{ 2, 2, 2 });
    defer dotted.deinit();
    const top = helpers.facing(&dotted, .{ 0, 0, 1 });
    const centre = try dotted.geometry.addPoint(testing.allocator, .{ 1, 1, 2 });
    _ = try @import("../topology/euler.zig").mvh(&dotted, @import("../topology/types.zig").FaceIndex.of(top), centre);
    try testing.expect(hasPointLoop(&dotted));
    var away = try box(.{ 5, 0, 0 }, .{ 6, 1, 1 });
    defer away.deinit();
    try expectTableAgrees(&dotted, &away);
}

test "degeneracy: a corner touching a triangular face at its centroid" {
    // The nightly solids fuzzer's find (2026-11-13), reduced: the box's corner (1.5, 3, 3)
    // touches the hull's face (0.5, 3, 2), (3.5, 5, 3), (0.5, 1, 4) from outside at the
    // triangle's centroid, the only point classification sampled the face at: on the
    // box's boundary, the face was unclassified. A triangle now offers three samples
    // besides its centroid, the next tried
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 0.5, 5, 4 }, .{ 0.5, 1, 4 }, .{ 3.5, 5, 3 }, .{ 0.5, 3, 2 }, .{ 0.5, 5, 2 } };
    var a = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer a.deinit();
    var b = try box(.{ 1.5, 1, 2 }, .{ 3.5, 3, 3 });
    defer b.deinit();
    var u = try sound(&a, &b, .@"union");
    defer u.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&u));
    var i = try sound(&a, &b, .intersection);
    defer i.deinit();
    try testing.expect(i.isEmpty());
    try expectIdentities(&a, &b);
}

test "degeneracy: a hull's edge across a box's floor, passing its corner within the tolerance: the corner is where it meets the corner's edge" {
    // The nightly solids fuzzer's find (2026-11-13, run 43411851511), reduced: a hull moved
    // by the zone touches the box from below along its edge (2.00001, 5, 2)–(4.00001, 1, 2),
    // which crosses the floor from its y = 5 edge to its x = 3 edge at (3, 3.00002, 2),
    // the intersection tolerance and a rounding from the corner (3, 3, 2). The overlap rules
    // took the floor's piece by that crossing and the side x = 3 to meet from (3, 5, 2) to
    // the corner: the gap's middle is within the zone of the piece, its end is not, and the
    // end was taken all the same. A piece of two faces' meet ends at crossings in both
    // (`planar_faces.meet`, on those two faces as they came). The boolean refused the input
    // for a while, the crossing lying the tolerance from the corner to rounding; but the
    // corner is 8.9e-6 from the hull's edge, on it (vertex–edge), and two straight edges
    // meet once (2026-11-16): the corner is where the hull's edge meets the side's, and the
    // crossing is never asked again. Made and sound either way round
    var b = try box(.{ 1, 3, 2 }, .{ 3, 5, 4 });
    defer b.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 1, 1, 0 }, .{ 0, 3, 0 }, .{ 2, 2, 1 }, .{ 2, 3, 0 }, .{ 4, 0, 2 }, .{ 0, 2, 0 }, .{ 1, 0, 1 }, .{ 2, 4, 2 } };
    var c0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer c0.deinit();
    var c = try helpers.moved(&c0, .{ 1e-5, 1, 0 });
    defer c.deinit();
    try expectIdentities(&b, &c);
    try expectIdentities(&c, &b);
    // The floor's piece, a triangle (with an apex below it), against the box's side x = 3:
    // its crossing the tolerance and a rounding from the corner, which the rules reading
    // the pair now refuse (`at_tolerance`, Option A, D27), as the boolean would
    var floor = try tetrahedron(.{ 2.6, 4.3, 1 }, .{ 2.00001, 5, 2 }, .{ 3, 5, 2 }, .{ 3, 3.0000200000000006, 2 });
    defer floor.deinit();
    const planar_faces = @import("../intersect/planar_faces.zig");
    const top = types.FaceIndex.of(helpers.facing(&floor, .{ 0, 0, 1 }));
    const side = types.FaceIndex.of(helpers.facing(&b, .{ 1, 0, 0 }));
    var pieces: std.ArrayList(planar_faces.Piece) = .empty;
    defer pieces.deinit(testing.allocator);
    var rules = Diagnostics.init(testing.allocator);
    defer rules.deinit();
    try testing.expectError(error.Degenerate, planar_faces.meet(testing.allocator, &floor, top, &b, side, tol, &pieces, &rules));
    try testing.expectEqual(diagnostics.Code.at_tolerance, rules.first().?.code);
}

test "degeneracy: a hull's vertex the zone from a box's edge, a hull's edge from it crossing that edge again 4.1e-5 on: they meet once, at the vertex" {
    // The nightly solids fuzzer's find (2026-11-14, run 43515591144): a hull moved by the
    // zone in y has its vertex (2.5, 4.00001, 1) the zone from the box's edge x = 2.5,
    // y = 4, and a hull edge from it crosses that edge 4.1e-5 along: both points within the
    // intersection tolerance of both edges, the edges shared the piece between them, 14
    // degrees off each, and the faces about it were ordered by noise (an edge of four
    // coedges that did not pair). The second crossing then left the intersection a vertex
    // within the tolerance of two of its faces that meet nowhere near it, and the next
    // union was refused by the minimum feature size. Two straight edges meet once
    // (2026-11-16): the vertex, on the box's edge, is where the hull's edge meets it, no
    // second vertex is made, and both booleans are made and sound either way round
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 2, 2, 3 }, .{ 4, 3, 4 }, .{ 2, 3, 3 }, .{ 1, 0, 3 }, .{ 1, 1, 2 }, .{ 4, 4, 0 }, .{ 3, 2, 3 }, .{ 4, 1, 4 } };
    var h0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer h0.deinit();
    const place = mat.Affine.translate(.{ 0.5, 1e-5, 1 }).compose(&mat.Affine.scaleBy(.{ 0.5, 1, 1 }));
    var h = try @import("../construct/transform.zig").transform(testing.allocator, &h0, &place, .{}, &diag);
    defer h.deinit();
    var slab = try box(.{ 1, 3, 1 }, .{ 5, 7, 3 });
    defer slab.deinit();
    var piece = try sound(&h, &slab, .intersection);
    defer piece.deinit();
    var post = try box(.{ 2.5, 0, -1 }, .{ 3.5, 4, 3 });
    defer post.deinit();
    try expectIdentities(&piece, &post);
    try expectIdentities(&post, &piece);
}

test "degeneracy: a vertex the intersection tolerance off a face, its edge leaving it at a shallow angle" {
    // The nightly solids fuzzer's find (2026-11-13, run 43413453969), as it came: a hull
    // moved by the intersection tolerance cut from a turned box leaves vertices on the
    // plane x = 1.00002; a box with a face on x = 1 united with it takes them for points of
    // that face (vertex–face: within the tolerance), and an edge leaving one of them at 5°
    // crosses x = 1 exactly 2e-4 further, inside the face, where the boolean made no edge.
    // The overlap rules took that exact crossing for a point of both faces off one's
    // boundary; they now take a crossing as the boolean does, an end within the tolerance
    // and its gap being the edge's crossing. Moved by the tolerance exactly, as the fuzzer
    // moved it, the hull lies that far from the box to rounding: the boolean refuses
    // (`at_tolerance`); moved by 1.9e-5 the vertices are on the face and the edge crosses
    // as it did
    var a0 = try box(.{ 1, 1, 2 }, .{ 2, 3, 4 });
    defer a0.deinit();
    var a = try turned(&a0, .{ 2, 2, 2 }, .{ 1, 2, 3 }, std.math.pi / 4.0);
    defer a.deinit();
    var a_moved = try helpers.moved(&a, .{ -1, 0, -0.5 });
    defer a_moved.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 0, 4, 1 }, .{ 3, 1, 2 }, .{ 1, 1, 0 }, .{ 1, 2, 0 }, .{ 1, 1, 4 }, .{ 2, 1, 2 }, .{ 1, 0, 3 } };
    var b0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer b0.deinit();
    var c = try box(.{ 1, 0.5, 3 }, .{ 4, 1.5, 4 });
    defer c.deinit();
    var at = try helpers.moved(&b0, .{ 2e-5, 1, 0 });
    defer at.deinit();
    var cut_at = try sound(&a_moved, &at, .difference);
    defer cut_at.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| try expectAtTolerance(&cut_at, &c, op);
    var b = try helpers.moved(&b0, .{ 1.9e-5, 1, 0 });
    defer b.deinit();
    var cut = try sound(&a_moved, &b, .difference);
    defer cut.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
        var r = try sound(&cut, &c, op);
        r.deinit();
    }
}

test "degeneracy: operands the intersection tolerance apart to rounding are refused, a hair either side decided" {
    // The nightly solids fuzzer's find (2026-11-13, run 43417538617): a hull moved by the
    // intersection tolerance exactly put its face 2.0000000000131e-5 from a box's, a
    // rounding past the tolerance, while its vertices' heights over the box's plane came out
    // a rounding inside it; the paves took the faces apart and the vertices on, a sliver
    // the tolerance wide was left that no sample could classify, and the shell did not
    // close. A distance within rounding of the tolerance is refused (`at_tolerance`), a
    // stage of the paves named; a hair either side is decided
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var at = try box(.{ 1 + tol.xsect, 0, 0 }, .{ 2, 1, 1 });
    defer at.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| try expectAtTolerance(&a, &at, op);
    // Within it: the faces touch, one solid; beyond it: two, a warned sliver of air between
    var touching = try box(.{ 1 + 0.95 * tol.xsect, 0, 0 }, .{ 2, 1, 1 });
    defer touching.deinit();
    var joined = try sound(&a, &touching, .@"union");
    defer joined.deinit();
    try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&joined));
    var apart = try box(.{ 1 + 1.05 * tol.xsect, 0, 0 }, .{ 2, 1, 1 });
    defer apart.deinit();
    var both = try sound(&a, &apart, .@"union");
    defer both.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&both));
    // The find as it came
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 3, 3, 4 }, .{ 0, 1, 2 }, .{ 3, 1, 3 }, .{ 3, 1, 1 }, .{ 2, 2, 3 }, .{ 1, 4, 0 } };
    var h0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer h0.deinit();
    var h = try helpers.moved(&h0, .{ 2e-5, 0, 0 });
    defer h.deinit();
    var c = try box(.{ 1, 1, 2 }, .{ 3, 3, 4 });
    defer c.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| try expectAtTolerance(&h, &c, op);
}

test "degeneracy: a vertex the tolerance off an edge in its end's strip, not its end, is refused" {
    // A tetrahedron's apex 1.5e-5 up a box's edge from its end and 1.5e-5 off it (the
    // intersection tolerance 2e-5): within the tolerance of the edge, where its end's ball
    // keeps it from being split, and 2.1e-5 from the end, too far to be it. The paves
    // skipped it; the faces about the edge met it where the edge had no vertex, a
    // fragment's loop split where the interferences found no point (IntersectionFailed).
    // Too near the end to split at, too far to merge: refused (OCCT validates its pave
    // blocks after splitting)
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer a.deinit();
    var b = try tetrahedron(.{ -1.5e-5, 0, 1.5e-5 }, .{ -1, -1, 0.5 }, .{ -1, 0.5, -1 }, .{ 0.5, -1, -1 });
    defer b.deinit();
    for ([_]pipeline.Op{ .@"union", .difference }) |op| {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        try testing.expectError(error.TooSmallEdge, pipeline.boolean(testing.allocator, &a, &b, op, .{}, &diag, null));
        try testing.expectEqual(diagnostics.Code.edge_too_short, diag.first().?.code);
    }
}

test "degeneracy: a vertex on an edge at its end's strip to rounding is refused, wherever the pair is placed" {
    // A tetrahedron's apex the intersection tolerance up another's edge from its end (the
    // end's gap none, so at the bound of its strip) and 1.5e-5 off it. In the strip it is
    // too near the end to split the edge at (refused, as above); beyond it a pave. The
    // bound was compared raw, so which the apex was hung on the rounding a placement
    // moved: at the bound to rounding it is refused (D27), as every distance the paves
    // decide is (the 10K session on 6007ab01, 2026-11-18: a hull's corner 1e-17 from the
    // bound of a box edge's strip). The edge's bottom face is tilted, so the apex is
    // clear of its plane (a box's would be the tolerance away from it, at the tolerance
    // there too), and the apex's edges leave away from the edge's end
    var a0 = try tetrahedron(.{ 0, 0, 1 }, .{ 0, 0, 0 }, .{ 1, 0, 0.5 }, .{ 0, 1, 0.5 });
    defer a0.deinit();
    var b0 = try tetrahedron(.{ -1.5e-5, 0, 2e-5 }, .{ -1, -1, 0.5 }, .{ -1, 0.5, 1 }, .{ -0.5, -1, 1 });
    defer b0.deinit();
    for (0..16) |k| {
        const x: f64 = @floatFromInt(k);
        const by: Vec3 = .{ 0.37 * x, -1.13 * x, 2.71 * x };
        var a = try helpers.moved(&a0, by);
        defer a.deinit();
        var b = try helpers.moved(&b0, by);
        defer b.deinit();
        for ([_]pipeline.Op{ .@"union", .difference }) |op| try expectAtTolerance(&a, &b, op);
    }
}

test "degeneracy: two edges at a shallow angle, one's end on the other, meet once: no second crossing where they run within the tolerance" {
    // The solids fuzzer's find (2026-11-16, 10K session on cb4fcdbb), at one tolerance: a
    // box turned 0.007 rad about its front-right corner, that corner 3e-6 inside a plate's
    // front face and its bottom on the plate's bottom. The corner is on the plate's
    // front-bottom edge (vertex–edge), and the box's front-bottom edge, leaving it at 0.007
    // rad, stays within the tolerance of the plate's for 3e-3; edge–edge crossed the two
    // again 4.3e-4 on. At the bottom the front faces met there, at the top at the corner's
    // edge: the difference's two front faces passed through each other (faces_intersect)
    const angle = 0.007;
    var plate = try box(.{ -1, 1, 0 }, .{ 3, 3, 1 });
    defer plate.deinit();
    var b0 = try box(.{ 0, 1, 0 }, .{ 2, 2, 0.5 });
    defer b0.deinit();
    var b1 = try turned(&b0, .{ 2, 1, 0 }, .{ 0, 0, 1 }, angle);
    defer b1.deinit();
    var b = try helpers.moved(&b1, .{ 0, 3e-6, 0 });
    defer b.deinit();
    try expectIdentities(&b, &plate);
    try expectIdentities(&plate, &b);
}

test "degeneracy: a chain of edges on two lines 8.7e-5 apart is joined whole, either way round" {
    // The nightly solids fuzzer's find (2026-11-16, run 43773180777), as it came: a box
    // united with a turned hull, the hull's face crossing the box's top, then cut by a
    // plate (zone 1e-4) whose bottom lies 3e-5 under that top. The hull's face crosses the
    // two planes along two lines 8.7e-5 apart, within the intersection tolerance (2e-4),
    // and the result's edge along it is a chain of four vertices, two on each line.
    // Simplification joined vertex by vertex in their numbering: one way round each join
    // measured the next against the line the last left, and the second vertex stayed (8
    // vertices against 7). The chain is decided whole, by the lines its edges have
    const coarse = Tolerance.fromZone(1e-4);
    const Affine = mat.Affine;
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var b0 = try helpers.boxAt(tol, .{ 2, 3, 2 }, .{ 4, 4, 3 });
    defer b0.deinit();
    var b = try helpers.moved(&b0, .{ 5e-6, 2e-5, -2e-5 });
    defer b.deinit();
    const points = [_]Vec3{ .{ 4, 3, 2 }, .{ 4, 1, 3 }, .{ 0, 2, 2 }, .{ 0, 0, 2 }, .{ 4, 1, 1 }, .{ 1, 2, 3 }, .{ 1, 3, 0 }, .{ 4, 4, 0 } };
    var h0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer h0.deinit();
    // The generator's placement, composed as it composes it
    var place = Affine.translate(vec.ZERO3);
    place = Affine.rotateAbout(@splat(2), vec.normalized(.{ 1, 2, 3 }).?, std.math.pi).compose(&place);
    place = Affine.scaleBy(.{ 2, 2, 1 }).compose(&place);
    place = Affine.translate(vec.ZERO3).compose(&place);
    place = Affine.translate(.{ 0, 1.999999989037341e-5, -1.999999989037341e-5 }).compose(&place);
    var h = try @import("../construct/transform.zig").transform(testing.allocator, &h0, &place, .{}, &diag);
    defer h.deinit();
    var joined = try sound(&b, &h, .@"union");
    defer joined.deinit();
    var p0 = try helpers.boxAt(coarse, .{ -48, -48, 3 }, .{ 52, 102, 4 });
    defer p0.deinit();
    var plate = try helpers.moved(&p0, .{ 2e-2, 2e-4, -5e-5 });
    defer plate.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection }) |op| {
        var forward = try sound(&joined, &plate, op);
        defer forward.deinit();
        var swapped = try sound(&plate, &joined, op);
        defer swapped.deinit();
        try testing.expectEqual(forward.counts(), swapped.counts());
    }
    // The plate's bottom moves onto the box's top, 3e-5 over the plate: the identities to
    // the report's shift (the plate less the rest is refused, `pinched`, as it was before
    // chains were joined whole: the result would touch itself inside one solid)
    try helpers.expectIdentitiesAtTolerance(&joined, &plate);
}

test "degeneracy: a plate's top and a box's 1.9e-4 apart, both planes holding the two at a tolerance of 2e-4, give one plane either way round" {
    // The nightly solids fuzzer's find (2026-11-16, run 43831843168), as it came: a turned
    // hull united with a box, then joined with a plate (zone 1e-4) whose top lies 1.9e-4
    // over the box's top. The paves find the two tops in one plane, and either top's
    // plane holds both within the intersection tolerance. The group took its first
    // operand's first face's plane, so A ∪ B lay in the box's top and B ∪ A in the
    // plate's, where the hull's section across the box's top edge is two edges, not one
    // line (22 vertices against 23). The group takes the plane nearest its points
    const coarse = Tolerance.fromZone(1e-4);
    const Affine = mat.Affine;
    const middle: Vec3 = @splat(2);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 3, 4, 0 }, .{ 3, 0, 3 }, .{ 3, 3, 3 }, .{ 1, 1, 4 }, .{ 2, 0, 4 }, .{ 0, 4, 3 } };
    var h0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer h0.deinit();
    // The generator's placements, composed as it composes them
    var place = Affine.rotateAbout(middle, .{ 1, 0, 0 }, std.math.pi / 2.0).compose(&Affine.translate(vec.ZERO3));
    place = Affine.translate(.{ -2e-5, -5e-6, -2e-3 }).compose(&Affine.translate(vec.ZERO3).compose(&place));
    var h = try @import("../construct/transform.zig").transform(testing.allocator, &h0, &place, .{}, &diag);
    defer h.deinit();
    var b0 = try helpers.boxAt(tol, .{ 0, 3, 1 }, .{ 4, 4, 3 });
    defer b0.deinit();
    var b = try helpers.moved(&b0, .{ 5e-6, 2e-3, 1e-5 });
    defer b.deinit();
    var joined = try sound(&h, &b, .@"union");
    defer joined.deinit();
    var p0 = try helpers.boxAt(coarse, .{ -48, -48, 0 }, .{ 52, 102, 3 });
    defer p0.deinit();
    var turn = Affine.rotateAbout(middle, .{ 0, 0, 1 }, 1e-6).compose(&Affine.translate(vec.ZERO3));
    turn = Affine.translate(.{ 1.9999999855049212e-4, -1.9999999855049212e-4, 1.9999999855049212e-4 }).compose(&Affine.translate(vec.ZERO3).compose(&turn));
    var plate = try @import("../construct/transform.zig").transform(testing.allocator, &p0, &turn, .{}, &diag);
    defer plate.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection }) |op| {
        var forward = try sound(&joined, &plate, op);
        defer forward.deinit();
        var swapped = try sound(&plate, &joined, op);
        defer swapped.deinit();
        try testing.expectEqual(forward.counts(), swapped.counts());
    }
}

test "degeneracy: an edge on a face by its ends' reach and off it by its line is refused, never laid in the face" {
    // The 10K session's find on 7a1bfb5e (2026-11-16, the solids target), as it came: a
    // hull cut by a scaled box leaves corners with gaps of 5.3e-6 on its face x = 0.99998,
    // 2.1e-5 from a box's face x = 1.000005 (within the tolerance and their gaps), the
    // edge between them on its line 2.5e-5 from it. The section of the cut's floor with
    // the box's face took that edge for itself, and the union laid it in the box's face as
    // a slit, 2.5e-5 off the face's surface (`edge_off_surface`). An existing edge stands
    // for a section only where its line lies on the other face as the checker holds it
    const Affine = mat.Affine;
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 0, 1, 0 }, .{ 4, 2, 4 }, .{ 3, 2, 1 }, .{ 0, 0, 2 }, .{ 2, 0, 4 }, .{ 2, 1, 0 }, .{ 2, 0, 4 }, .{ 4, 1, 1 } };
    var h0 = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer h0.deinit();
    var h = try helpers.moved(&h0, .{ -5e-6, 2e-5, -5e-6 });
    defer h.deinit();
    // The generator's placement of the scaled box, composed as it composes it
    var c0 = try helpers.boxAt(tol, .{ 0, 0, 2 }, .{ 2, 2, 3 });
    defer c0.deinit();
    var place = Affine.translate(vec.ZERO3);
    place = Affine.scaleBy(.{ 0.5, 1, 0.5 }).compose(&place);
    place = Affine.translate(vec.ZERO3).compose(&place);
    place = Affine.translate(.{ -1.9999999971578292e-5, 2.000000002842171e-5, -5e-6 }).compose(&place);
    var c = try @import("../construct/transform.zig").transform(testing.allocator, &c0, &place, .{}, &diag);
    defer c.deinit();
    var cut = try sound(&h, &c, .intersection);
    defer cut.deinit();
    var b0 = try box(.{ 1, 0, 0 }, .{ 2, 4, 4 });
    defer b0.deinit();
    var b = try helpers.moved(&b0, .{ 5e-6, -1e-5, -2e-5 });
    defer b.deinit();
    try expectRefused(&cut, &b, .below_feature_size);
    try expectRefused(&b, &cut, .below_feature_size);
}

test "degeneracy: two faces a hair off parallel, within the tolerance of each other at three corners of where they meet and past it at the fourth, are one plane's or refused" {
    // The 10K session's find on e252409f (2026-11-16, both targets), at one tolerance: a
    // box's bottom tilted 4.7e-6 over a plate's top, 5e-6 above it at its corner inside the
    // plate, 1.5e-5 where the plate's sides cross it and 2.5e-5 at the plate's corner
    // inside it (the tolerance, 2e-5). Neither face lies in the other's plane by all its
    // corners, so the pair was taken to meet along their planes' line, and the three merged
    // vertices on both were ordered by the noise of the normals' cross product; the plate's
    // top kept the box's imprint, the box's bottom not the plate's, and the union kept both
    // where they meet, one on the other (`faces_intersect`). Merged vertices on both faces
    // off one line put them in one plane, where its rules decide them: the plate's corner
    // inside the box's bottom past the tolerance of its plane is refused
    var plate = try box(.{ 0, 0, -1 }, .{ 4, 4, 0 });
    defer plate.deinit();
    var b0 = try box(.{ 1, 1, 0 }, .{ 5, 5, 1 });
    defer b0.deinit();
    var b1 = try turned(&b0, .{ 1, 1, 0 }, .{ 1, -1, 0 }, 1e-5 / 3.0 * @sqrt(2.0));
    defer b1.deinit();
    var b = try helpers.moved(&b1, .{ 0, 0, 5e-6 });
    defer b.deinit();
    try expectRefused(&plate, &b, .below_feature_size);
    try expectRefused(&b, &plate, .below_feature_size);
}

test "degeneracy: faces at right angles sharing merged vertices, one off the others' line within its reach, cross along their line" {
    // The 10K session's find on 415e356d (2026-11-16, solids): a plate's top and a box's
    // side at right angles shared four merged vertices, one of them 1.8e-4 below the
    // others' line (the tolerance, 2e-4). Measured from the line through it, the others
    // were off one line, so the pair was taken for one plane, and a fragment of the plate's
    // top inside the box's side found no twin (`imprint_unmatched`). Here a prism's front,
    // notched down to 0.9 tolerances below the plate's top edge: the notch's apex, the first
    // of the three merged vertices on both faces, is the noisy one. Planes at an angle meet
    // along their own line, whatever the vertices on both
    var solid = try helpers.notchedPrism(tol, 1 - 0.9 * tol.xsect);
    defer solid.deinit();
    var plate = try box(.{ 0, 0, 0.5 }, .{ 10, 5, 1 });
    defer plate.deinit();
    try expectAllSound(&solid, &plate);
}

test "degeneracy: a notch's apex on a face turned 0.3 rad from it, 3 tolerances off where they cross, touches it there" {
    // The edge-case matrix (2026-11-16): a plate against a notched front, turned 0.3 rad
    // about its top edge, the notch's apex 3 tolerances under that edge and within the
    // tolerance of the plate's front, as are the notch's sides down to it: the two fronts
    // touch along the edge and down and up the notch's sides. The overlap rules joined
    // those pieces into one run, judged as one straight segment whose middle, over the
    // notch, is in neither face (`faces_intersect`); each piece is judged by itself, as
    // the paves cut them
    var solid = try helpers.notchedPrism(tol, 1 - 3 * tol.xsect);
    defer solid.deinit();
    var upright = try box(.{ 0, 0, 0.5 }, .{ 10, 5, 1 });
    defer upright.deinit();
    var plate = try turned(&upright, .{ 0, 0, 1 }, vec.X3, 0.3);
    defer plate.deinit();
    try expectAllSound(&solid, &plate);
}

test "degeneracy: a plate's front inside a notch 1.25 tolerances deep under its edge is outside the notched solid, the union's sliver refused" {
    // The edge-case matrix (2026-11-16): a plate's front in one plane with a notched
    // front, the notch's apex 1.25 tolerances under the plate's top edge: the plate's
    // front inside the notch is a triangle 2.5e-5 a side, every point within the tolerance
    // of the notch's sides, so no ray decides it, and its seams along the notch's edges
    // were read as undecided (the notched front in its plane). Beyond the edge from that
    // front, the notch's side alone bounds the material: outside it. The intersection and
    // the difference are made; the union keeps the triangle, a sliver, refused
    var solid = try helpers.notchedPrism(tol, 1 - 1.25 * tol.xsect);
    defer solid.deinit();
    var plate = try box(.{ 0, 0, 0.5 }, .{ 10, 5, 1 });
    defer plate.deinit();
    for ([2][2]*const Body{ .{ &solid, &plate }, .{ &plate, &solid } }) |operands| {
        for ([_]pipeline.Op{ .intersection, .difference }) |op| {
            var made = try sound(operands[0], operands[1], op);
            made.deinit();
        }
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, operands[0], operands[1], .@"union", .{}, &diag, null));
        try testing.expectEqual(diagnostics.Code.sliver_face, diag.first().?.code);
    }
}

test "degeneracy: a corner put on an edge between gapped ends, off the edge's line past the tolerance, carries the gap it needs" {
    // The 10K session's find on 06478dc2 (2026-11-16, solids), reduced: a box at a zone of
    // 1e-4 whose top's corners at y = 2.5 lie their gap of 1e-4 under its plane (what a
    // chain's merges leave), and a tetrahedron's apex 1e-4 off the box's side, 1.9e-4 under
    // its top edge at y = 2: 1.49e-4 from the segment between the edge's ends, on it by the
    // tolerance (2e-4), and 2.15e-4 from the edge's line, which the union's edge keeps (in
    // the find 1.68e-4 and 2.06e-4). The apex had no gap and the checker refused the union
    // (`vertex_off_curve`); its gap now covers the distance
    var block = try helpers.boxAt(Tolerance.fromZone(1e-4), .{ 3, 0, 2 }, .{ 4, 2.5, 3 });
    defer block.deinit();
    for (block.vertices.items) |*v| {
        const p = &block.geometry.points.items[@backingInt(v.point)];
        if (p[1] != 2.5 or p[2] != 3) continue;
        p[2] -= 1e-4;
        v.gap = 1e-4;
    }
    var report = try check.run(testing.allocator, &block, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.ok());
    var t = try tetrahedron(.{ 3 - 1e-4, 2, 3 - 1.9e-4 }, .{ 2, 4, 0 }, .{ 1, 2, 4 }, .{ 2, 0, 2 });
    defer t.deinit();
    try expectAllSound(&block, &t);
}

test "degeneracy: a hull's ridge through a thin plate, from the plate's side at 26.6°, joins them through the slit's mouth, no pinch" {
    // The 10K session's find on b1053969 (2026-11-16, solids), its operands as the chain
    // left them: a hull whose left face lies within the tolerance of a plate's left side,
    // its ridge in the plate's top, the plate 3 tolerances thick. The union's underside
    // has a slit where the hull passes through it, whose mouth on the side is 9e-5 long,
    // its sides at 26.6° to the side's edge, the mouth's middle 2.01e-5 from them. The
    // overlap rules placed that middle with the mouth's ends' gaps (2.5e-6), on the slit's
    // side within reach, and inside the joined left face: the faces "touched", a pinch. A
    // gap's middle is no vertex and is placed with no gap, as the paves place it. The
    // plate less the hull is refused by design (the ridge leaves it pinched at a corner)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 0.499995, 1.9999799999999432, 4.00001 }, .{ 1.999995, 2.999979999999943, 1e-05 }, .{ 0.499995, 3.999979999999943, 1e-05 }, .{ 0.499995, -2.000000005684342e-05, 2.00001 }, .{ 0.999995, 2.999979999999943, 4.00001 } };
    var ridge = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer ridge.deinit();
    var plate = try box(.{ 0.5, 0.5, 3.9999500000000636 }, .{ 4.5, 3.5, 4.000010000000064 });
    defer plate.deinit();
    for ([2][2]*const Body{ .{ &ridge, &plate }, .{ &plate, &ridge } }) |operands| {
        var joined = try sound(operands[0], operands[1], .@"union");
        joined.deinit();
    }
    try expectProbe(&ridge, &plate);
}

test "degeneracy: a ridge under a flat tetrahedron's corner, where its top and bottom are within the tolerance, cuts off a band thinner than it: refused" {
    // The 10K session's find on b1053969 (2026-11-16, locus), its operands as the chain
    // left them: a hull whose horizontal ridge passes 1.3e-5 under the front corner of a
    // tetrahedron 2.1 tolerances thick at its middle, where its top and bottom are within
    // the tolerance of each other. The union imprinted the ridge and cut off the corner's
    // triangle of the bottom, 0.3 across, which lay wholly within the tolerance of the top
    // over it; the overlap rules found the result's faces on each other. A kept piece of a
    // face lying on another kept face of its operand facing apart is refused (Leo: the
    // fragment rule), either way round
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const ridge_points = [_]Vec3{ .{ 1.3381837175357336, 0.7471433042130544, -2e-05 }, .{ -0.503713391573891, 3.317632564928533, 3.99998 }, .{ 2.953336489125606, 2.2935202066613396, 0.99998 }, .{ 2.2935202066613396, 1.0426635108743938, 2.99998 }, .{ 1.7024797933386606, 2.953336489125606, 3.99998 }, .{ 2.589040413322679, 0.08732702174878793, 0.99998 } };
    const flat_points = [_]Vec3{ .{ -0.999995, 4, 3.999959000000071 }, .{ 1.000005, 4, 3.999959000000071 }, .{ 5e-06, 3, 4.000001000000071 }, .{ 5e-06, 5, 4.000001000000071 } };
    const hull = @import("../construct/hull.zig");
    var ridge = try hull.hull(testing.allocator, tol, &ridge_points, &diag);
    defer ridge.deinit();
    var flat = try hull.hull(testing.allocator, tol, &flat_points, &diag);
    defer flat.deinit();
    for ([2][2]*const Body{ .{ &ridge, &flat }, .{ &flat, &ridge } }) |operands| {
        var refused = Diagnostics.init(testing.allocator);
        defer refused.deinit();
        try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, operands[0], operands[1], .@"union", .{}, &refused, null));
        try testing.expectEqual(diagnostics.Code.below_feature_size, refused.first().?.code);
    }
    try expectProbe(&ridge, &flat);
}

test "degeneracy: a hull's edge across a thin plate's side at 15.5°, within the tolerance of it over the crossing, reads no side there" {
    // The 10K session's find on 2b26eef1 (2026-11-16, locus), its operands as the chain
    // left them: a plate 2.1 tolerances thick whose side a hull's edge crosses at 15.5°,
    // within the tolerance of the side over the whole crossing, 6.6e-5 long, and of both
    // its long edges. The paves put that piece of the edge on the side, splitting it; the
    // side's piece inside the hull read its seam from the edge's wedge as if the edge ran
    // in its plane, 2.2° off the hull's face there: outside, against the plate's top beside
    // it, inside, and the two clear seams of one component were refused. An edge across a
    // fragment's plane bounds no region of it (its faces cut the plane along their own
    // lines): its wedge reads no side, and the side's pieces take their component's and a
    // ray's (Leo, 2026-11-17)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 9.999999717180685e-10, 0.4999999989999999, -1 }, .{ 1.0000000009999999, 0.4999999999999998, 3 }, .{ -1.000000001, 2.499999998, 1 }, .{ 0.9999999989999999, 2.5, 3 }, .{ 2.000000002, -0.49999999900000014, 1 }, .{ 1.999999943436137e-09, -0.5000000010000002, 1 }, .{ 0.9999999989999999, 2.5, 1 }, .{ 1.999999998, 3.500000001, -1 } };
    var hull = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer hull.deinit();
    var plate = try box(.{ -0.002, 1.0000049999999994, -2.1000000000270802e-05 }, .{ 0.998, 3.0000049999999994, 2.0999999999826713e-05 });
    defer plate.deinit();
    try expectAllSound(&hull, &plate);
}

test "degeneracy: a hull's edge across a box's side at 28°, laid in it as a slit by its ends' reach, pairs by the planes that hold it" {
    // The 10K session's find on 600148f2 (2026-11-17, locus), its operands as the chain
    // left them: a hull's corner 1e-5 inside a box's side, its edge leaving at 28° to the
    // side's plane and crossing the box's edge 2.5e-5 on, both ends within reach of the
    // side, that piece of the edge laid in the side as a slit. The union's edge there has
    // four uses, the hull's two faces and the slit's two sides; read about the hull's edge,
    // the side's material took in a hull's face and the four did not pair
    // (`edge_coedge_count`; on 415e356d the side was left unclassified). A wedge is read
    // only about an edge in its face's plane: the side, holding the edge by reach alone,
    // pairs its own two uses, the hull's faces theirs, two solids touching along the slit
    // (Leo, 2026-11-17, as for a fragment's wedge)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const points = [_]Vec3{ .{ 0.9999900004999999, 7.9999800000001136, 6.000019999999999 }, .{ 0.49998999949999995, 7.9999800000001136, 2.000020002 }, .{ 0.9999900009999999, 5.9999800000001136, 8.00002 }, .{ 0.4999900004999999, 1.9999800000001138, 6.000020001999999 }, .{ -1.0000500000082742e-05, 1.9999800000001138, 2.000020004 }, .{ 1.4999899989999999, 3.9999800000001136, 1.9997999999886874e-05 } };
    var hull = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer hull.deinit();
    var side = try box(.{ -1, -1.9999999957367437e-05, 1.999995 }, .{ 0, 2.9999800000000425, 2.999995 });
    defer side.deinit();
    try expectAllSound(&hull, &side);
    var u = try sound(&hull, &side, .@"union");
    defer u.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&u));
}

test "degeneracy: a tetrahedron's tip 2.1e-4 over a box's top at a tolerance of 1e-4, its edges' crossings merged into one vertex, pinches the difference's pocket at a point" {
    // The 10K session's find on 600148f2 (2026-11-17, locus_solids), reduced to its box
    // and tetrahedron: in through the box's front, its tip past the top by just over the
    // intersection tolerance (2e-4), its three edges crossing the top within it of each
    // other, one merged vertex, the top given no section. The difference's pocket meets the
    // top at that point, inside one solid, as a tetrahedron's corner on it would: a pinch
    // (refused by design), which assembly took only for an operand's own vertex there,
    // and the overlap rules found in the result
    var a = try helpers.boxAt(Tolerance.fromZone(1e-4), .{ -0.0001, 1.9999, 0.9998 }, .{ 3.9999, 3.9999, 1.99979 });
    defer a.deinit();
    var through = try tetrahedron(.{ 5e-5, 3, 2 }, .{ 4.00005, 0, -1 }, .{ 2.00005, 0, 0 }, .{ 2.00005, 0, -1 });
    defer through.deinit();
    try expectPinched(&a, &through);
    for ([_]pipeline.Op{ .@"union", .intersection }) |op| {
        var made = try sound(&a, &through, op);
        made.deinit();
    }
}

test "degeneracy: a pyramid's bottom 0.4° off a box's top, its corner past the tolerance over it but its plane within the zone of it, is classified by that corner" {
    // The 10K session's find on c3a83ee8 (2026-11-17, locus_solids), reduced: a face
    // whose corner lay its zone off its plane (a merged vertex of an earlier boolean),
    // crossing a box's face at 0.4°, within the angular tolerance. The piece the box's face
    // cut off at the corner lies within the zone of that face all over (the corner 2.1e-5
    // over it, past the intersection tolerance, its plane 1.2e-5 there), so every sample
    // of it was on the box's boundary, its section read nothing at that angle, and it was
    // left unclassified. The paves put the corner on nothing of the box: a ray from it
    // decides the piece
    const p = 1.2e-5;
    const d = 0.9e-5;
    const z = struct {
        // The bottom's plane, through its three corners at x = 2 and 4
        fn at(x: f64) f64 {
            return 1 + p - 0.007 * x;
        }
    };
    const points = [_]Vec3{ .{ 0, 0, z.at(0) + d }, .{ 2, -1, z.at(2) }, .{ 2, 1, z.at(2) }, .{ 4, 0, z.at(4) }, .{ 2, 0, 3 } };
    // The bottom's far triangle first, its plane the record the near one shares
    var pyramid = try polyhedron(&points, &.{ .{ 1, 2, 3 }, .{ 0, 2, 1 }, .{ 4, 0, 1 }, .{ 4, 1, 3 }, .{ 4, 3, 2 }, .{ 4, 2, 0 } });
    defer pyramid.deinit();
    var b = try box(.{ -5, -5, 1 }, .{ 5, 5, 8 });
    defer b.deinit();
    try expectAllSound(&pyramid, &b);
}

test "degeneracy: a plate less a plate nudged against it is an L-shaped wall 2.5e-4 and 4e-4 thick under a top within the tolerance of the other's, sound" {
    // The 10K session's find on c3a83ee8 (2026-11-17, locus), as the fuzzer drew it: two
    // plates 100 by 150 at a zone of 1e-4, each nudged, their tops 1e-4 apart (in one
    // plane), the difference a wall along two sides. The wall's top, an L across the whole
    // plate, has corners up to 1e-4 apart in height; the checker's own fans from the middle
    // of its UV box swept 7500 of area whose heights did not cancel and measured the shell
    // -0.376, inside out. The one measure (`integrals.shellSense`) takes the plane's region
    // and the ribbons down to it
    const at = Tolerance.fromZone(1e-4);
    const na: Vec3 = .{ -5e-5, 1.9999999855049283e-4, -1.9999999855049283e-4 };
    const nb: Vec3 = .{ 2.000000014495072e-4, -1.9999999855049283e-4, -1e-4 };
    var a = try helpers.boxAt(at, vec.add(.{ 2, -48, 2 }, na), vec.add(.{ 102, 102, 4 }, na));
    defer a.deinit();
    var b = try helpers.boxAt(at, vec.add(.{ 2, -48, 1 }, nb), vec.add(.{ 102, 102, 4 }, nb));
    defer b.deinit();
    for ([2][2]*const Body{ .{ &a, &b }, .{ &b, &a } }) |operands| {
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            var made = try sound(operands[0], operands[1], op);
            made.deinit();
        }
    }
    // The tops, 1e-4 apart, are one plane: the identities hold to what that moved
    try helpers.expectIdentitiesAtTolerance(&a, &b);
}

test "degeneracy: a box's top lying in a long plate's bottom, the plate's far end its reach off the top's plane to rounding, is made either way round" {
    // The 10K session's find on 0fce3ff4 (2026-11-18, locus), its mechanism: faces sharing
    // merged vertices are coplanar when either lies in the other's plane. The box's top
    // lies in the plate's plane outright (its far corners 2e-7 off it); the plate's bottom
    // rises to the intersection tolerance exactly at its far end, at its reach of the
    // top's plane to rounding. Asked the box's top first, coplanar; asked the plate's
    // first, refused (at_tolerance): made one way round and refused the other. Both asked,
    // then decided (`canonical.either`): coplanar either way
    const xs = tol.xsect;
    var a = try box(.{ 0, 0, -1 }, .{ 1, 1, 0 });
    defer a.deinit();
    const points = [_]Vec3{ .{ 0, 0, 0 }, .{ 100, 0, xs }, .{ 100, 1, xs }, .{ 0, 1, 0 }, .{ 0, 0, 1 }, .{ 100, 0, 1 }, .{ 100, 1, 1 }, .{ 0, 1, 1 } };
    var plate = try polyhedron(&points, &.{ .{ 0, 3, 2 }, .{ 0, 2, 1 }, .{ 4, 5, 6 }, .{ 4, 6, 7 }, .{ 0, 1, 5 }, .{ 0, 5, 4 }, .{ 3, 7, 6 }, .{ 3, 6, 2 }, .{ 0, 4, 7 }, .{ 0, 7, 3 }, .{ 1, 2, 6 }, .{ 1, 6, 5 } });
    defer plate.deinit();
    for ([2][2]*const Body{ .{ &a, &plate }, .{ &plate, &a } }) |operands| {
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            var made = try sound(operands[0], operands[1], op);
            made.deinit();
        }
    }
    // The faces are one plane, the plate's bottom moved onto it by up to 2e-7
    try helpers.expectIdentitiesAtTolerance(&a, &plate);
}

test "degeneracy: a box's bottom the intersection tolerance over another's top, beside it, is made, not refused by the nearly-coplanar warning" {
    // The same find's second refusal: the paves' warning of faces parallel a hair apart
    // (`nearly_coplanar`) settled its "in the plane" at the tolerance to rounding as a
    // refusal. A warning decides nothing and refuses nothing (`incidence.holds`)
    var a = try box(.{ 0, 0, -1 }, .{ 1, 1, 0 });
    defer a.deinit();
    var b = try box(.{ 1 + 5e-4, 0, tol.xsect }, .{ 2, 1, 1 });
    defer b.deinit();
    try expectAllSound(&a, &b);
}

/// Each operation of `a` and `b`, either way round, made and sound; the identities.
fn expectAllSound(a: *const Body, b: *const Body) !void {
    for ([2][2]*const Body{ .{ a, b }, .{ b, a } }) |operands| {
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            var made = try sound(operands[0], operands[1], op);
            made.deinit();
        }
    }
    try expectIdentities(a, b);
}

test "degeneracy: an edge passing another within the tolerance in its end's strip, the end not on it, is refused either way round" {
    // The locus fuzzer's find (2026-11-16, 10K session on cb4fcdbb), at one tolerance: a
    // tetrahedron's corner in a plate's top, 2.2e-5 from its edge (beyond the tolerance,
    // 2e-5: not on it), its edge leaving down past the plate's edge 9.8e-6 away, 1.97e-5
    // from the corner, in the corner's strip. Edge–edge skipped the crossing as the
    // corner's; edge–face then crossed the plate's edge with the tetrahedron's face from
    // whichever operand came first, outside the strip one way round (made) and inside it
    // the other (refused). Too near the corner to split at, too far to be it: refused
    // either way round, as `endStrip` refuses a vertex there
    const h: Vec3 = .{ 2.2e-5, 0, 1 };
    var plate = try box(.{ 0, -5, -1 }, .{ 10, 5, 1 });
    defer plate.deinit();
    var t = try tetrahedron(h, vec.add(h, .{ -2, 0, -1 }), vec.add(h, .{ 1, 3, -1 }), vec.add(h, .{ -2, 2, 3 }));
    defer t.deinit();
    for ([2][2]*const Body{ .{ &t, &plate }, .{ &plate, &t } }) |operands| {
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            var diag = Diagnostics.init(testing.allocator);
            defer diag.deinit();
            try testing.expectError(error.TooSmallEdge, pipeline.boolean(testing.allocator, operands[0], operands[1], op, .{}, &diag, null));
            try testing.expectEqual(diagnostics.Code.edge_too_short, diag.first().?.code);
        }
    }
}

/// Each operation of `a` and `b`, either way round, refused before the paves: one of them
/// has two features that do not meet nearer than twice the intersection tolerance and
/// their gaps (`pipeline.featureSize`, the minimum feature size).
fn expectBelowFeatureSize(a: *const Body, b: *const Body) !void {
    for ([2][2]*const Body{ .{ a, b }, .{ b, a } }) |operands| {
        try expectRefused(operands[0], operands[1], .below_feature_size);
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, operands[0], operands[1], .@"union", .{}, &diag, null));
        try testing.expect(std.mem.indexOf(u8, diag.first().?.label, "two features of") != null);
    }
}

/// Each operation of `a` and `b` refused with `code`.
fn expectRefused(a: *const Body, b: *const Body, code: diagnostics.Code) !void {
    for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        if (pipeline.boolean(testing.allocator, a, b, op, .{}, &diag, null)) |result| {
            var made = result;
            made.deinit();
            std.debug.print("{s} was not refused\n", .{@tagName(op)});
            return error.TestExpectedError;
        } else |_| {}
        errdefer std.debug.print("{s}: {f}\n", .{ @tagName(op), diag });
        try testing.expectEqual(code, diag.first().?.code);
    }
}

test "degeneracy: a face through a plate 1.5 tolerances thick, past it all round, is refused: the plate's top and bottom both lie in its plane" {
    // research/consistent-tolerances.md's first probe (2026-11-14): the box's top at the
    // plate's mid-height is within the intersection tolerance of the plate's top and bottom
    // (and its sides, 3e-5 tall, lay in its plane by their corners' heights); no merged
    // vertex is within reach of two of the plate's faces (the box's corners are outside it),
    // so the minimum feature size never saw the pair, and the imprint reached its guard
    // (`imprint_unmatched`). The top and bottom in the box's plane, not in one: refused
    var plate = try box(.{ 0, 0, 0 }, .{ 10, 10, 1.5 * tol.xsect });
    defer plate.deinit();
    var b = try box(.{ -5, -5, -5 }, .{ 15, 15, 0.75 * tol.xsect });
    defer b.deinit();
    try expectRefused(&plate, &b, .below_feature_size);
}

test "degeneracy: a face inside a wall 1.5 tolerances thick is refused: the wall's two faces both lie in its plane, not in one" {
    // The second probe: a cavity's face 3e-5 behind the outer face x = 10, and a box whose
    // face lies between the two, in the plane of each (within the tolerance) but of
    // neither's; the imprints disagreed (`imprint_unmatched`)
    var outer = try box(.{ 0, 0, 0 }, .{ 10, 10, 10 });
    defer outer.deinit();
    var cavity = try box(.{ 5, 1, 1 }, .{ 10 - 1.5 * tol.xsect, 9, 9 });
    defer cavity.deinit();
    var walled = try sound(&outer, &cavity, .difference);
    defer walled.deinit();
    var b = try box(.{ 10 - 0.75 * tol.xsect, 0.5, 0.5 }, .{ 20, 9.5, 9.5 });
    defer b.deinit();
    try expectRefused(&walled, &b, .below_feature_size);
}

test "degeneracy: a face between a flat tetrahedron's opposite edges is refused: both edges lie in its plane, crossing there" {
    // The third probe: a valid tetrahedron whose opposite edges are 1.5e-5 apart (every
    // pair of its faces shares an edge, so the overlap rules see only boundary contacts),
    // and a box whose top lies between them; both edges are imprinted on the box's top and
    // cross in its plane where no merged vertex is (`imprint_unmatched`)
    const h = 0.75 * tol.xsect;
    var tetra = try tetrahedron(.{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, h }, .{ 0, 1, h });
    defer tetra.deinit();
    var b = try box(.{ -20, -20, -5 }, .{ 20, 20, h / 2 });
    defer b.deinit();
    try expectRefused(&tetra, &b, .below_feature_size);
}

test "degeneracy: an edge between corners with gaps, crossed by an edge of a face its face lies in by those gaps, meets it or is refused, never put beside it" {
    // The 10K session's find (2026-11-16, locus), reduced: a box at a zone of 1e-4 whose
    // bottom's front corners lie 3.5e-5 under its plane with that gap and the edge between
    // them on a line 7e-5 under it (as a chain's merges leave them), and a box whose bottom is 1.8e-4 over that plane, its side crossing the
    // front edge. The bottoms are one plane by the corners' reach (2.15e-4 within 2.35e-4);
    // edge–edge measured the crossing edges' 2.15e-4 against the tolerance alone (2e-4),
    // apart, and the crossing went on the box's front face beside the edge: the bottom's
    // overlay cut a piece where the paves put no point (`imprint_unmatched`). Two edges
    // meet within the tolerance and both edges' gaps; here the crossing would need a
    // vertex past the zone from both: refused, every operation either way round
    const coarse = Tolerance.fromZone(1e-4);
    var a = try helpers.boxAt(coarse, .{ 1.5, 1.00005, 2e-5 }, .{ 3.5, 2.002, 3.00002 });
    defer a.deinit();
    for (a.vertices.items) |*v| {
        const p = &a.geometry.points.items[@backingInt(v.point)];
        if (p[1] != 1.00005 or p[2] != 2e-5) continue;
        p[2] -= 3.5e-5;
        v.gap = 3.5e-5;
    }
    // The front bottom edge's own line 7e-5 under the plane, its corners within their gap
    for (a.edges.items) |e| {
        const p0 = a.point(e.start);
        const p1 = a.point(e.end);
        if (e.curve.kind != .line or p0[1] != 1.00005 or p1[1] != 1.00005 or p0[2] > 0 or p1[2] > 0) continue;
        a.geometry.lines.items[e.curve.index].o[2] = -5e-5;
    }
    var report = try check.run(testing.allocator, &a, .global);
    defer report.deinit(testing.allocator);
    try testing.expect(report.first() == null);
    var b = try helpers.boxAt(coarse, .{ 0.2499, 0.9998, 2e-4 }, .{ 2.0002, 2.9998, 2.0002 });
    defer b.deinit();
    try expectRefused(&a, &b, .gap_too_large);
    try expectRefused(&b, &a, .gap_too_large);
}

test "degeneracy: a face along a flat tetrahedron's knife edges, past its thick middle, is refused: within the tolerance of two of its faces at once" {
    // The 10K session's find (2026-11-16, locus_solids), as the edge-case matrix draws it:
    // a tetrahedron 2.1 tolerances thick (past the minimum feature size, its opposite
    // edges 4.2e-5 apart), its faces meeting at about 4e-5 rad, and a box's top through its
    // middle covering it only past a diagonal, away from the thick middle. There the top
    // is within the zone of the tetrahedron's upper and lower faces at once, which meet at
    // a knife edge, and a piece of it inside the tetrahedron had no sample off its
    // boundary (`unclassified`). The two faces facing apart within the tolerance of one
    // point of a face parallel to them bound a feature thinner than twice it there,
    // whether they meet or not: refused, every operation either way round
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const half = 2.1e-5;
    const points = [_]Vec3{ .{ 1, 2, -half }, .{ 3, 2, -half }, .{ 2, 1, half }, .{ 2, 3, half } };
    var knife = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer knife.deinit();
    var b0 = try box(.{ 2.4, -2, -1 }, .{ 6, 6, 0 });
    defer b0.deinit();
    var top = try turned(&b0, .{ 2.4, 2, 0 }, .{ 0, 0, 1 }, 0.6);
    defer top.deinit();
    try expectRefused(&knife, &top, .below_feature_size);
    try expectRefused(&top, &knife, .below_feature_size);
}

test "degeneracy: a hull's edge through a flat tetrahedron's knife, within the tolerance of its top and bottom 0.23 from the knife edge, is refused" {
    // The 10K session's find on a5301ce8 (2026-11-18, locus_solids), its operands as the
    // chain left them: a tetrahedron 2.1 tolerances thick at its middle, its faces meeting
    // at 6e-5 rad, and a hull whose bottom edge runs through it 2e-6 to 7.5e-6 off its
    // bottom, its faces crossing the top steeply. No merged vertex lies within reach of
    // both the top and the bottom, but the edge between two does, from the knife edge to
    // 0.23 from it; the union kept the notch in the hull's face between the edge and its
    // section with the top as narrow as the tetrahedron there, touching the bottom
    // (`pinched` by the overlap rules). A pave block within reach of two faces facing
    // apart at an angle within the angular tolerance, away from where they meet, is below
    // the minimum feature size, as a merged vertex there is: refused, every operation
    // either way round
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const flat_points = [_]Vec3{ .{ -2.000000005684342e-5, 3.000005, 0.9999990000000568 }, .{ 1.9999799999999432, 3.000005, 0.9999990000000568 }, .{ 0.9999799999999431, 2.000005, 1.0000410000000568 }, .{ 0.9999799999999431, 4.000005, 1.0000410000000568 } };
    const hull_points = [_]Vec3{ .{ 1.5, 2.999995, 4.000005 }, .{ 3.5, 2.999995, 4.000005 }, .{ 0.5, 3.999995, 1.000005 }, .{ 1.5, -0.000005, 2.000005 }, .{ 2.5, 0.999995, 1.000005 }, .{ 0.5, 1.999995, 3.000005 } };
    const hull = @import("../construct/hull.zig");
    var flat = try hull.hull(testing.allocator, tol, &flat_points, &diag);
    defer flat.deinit();
    var steep = try hull.hull(testing.allocator, tol, &hull_points, &diag);
    defer steep.deinit();
    try expectRefused(&flat, &steep, .below_feature_size);
    try expectRefused(&steep, &flat, .below_feature_size);
}

test "degeneracy: a flat tetrahedron 1.5 tolerances thick, its face 3e-4 rad off a plate's top: below the minimum feature size, refused" {
    // The gap draws' first find (2026-11-14), at a zone of 1e-4: the tetrahedron's upper
    // edge 5e-5 over the plate's top and its lower 2.5e-4 under it, so its upper faces
    // cross the top at 3e-4 rad 1/6 from the edge; the paves take the edge's ends for where
    // they meet (an edge meets a plane once), and the faces lie under the top within the
    // zone of it but toward their lower corner, where neither centroid reached
    // (`unclassified`). The tetrahedron is all but inside the plate: the intersection is it,
    // the union the plate
    const t = Tolerance.fromZone(1e-4);
    const top = 3 + 5e-5;
    var plate = try helpers.boxAt(t, .{ -10, -10, 5e-5 }, .{ 10, 10, top });
    defer plate.deinit();
    const half = 0.75 * t.xsect;
    // The upper edge 5e-5 over the top, the lower 2.5e-4 under it
    const mid = top + 5e-5 - half;
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var tetra = try @import("../construct/hull.zig").hull(testing.allocator, t, &.{ .{ -1, 2, mid - half }, .{ 1, 2, mid - half }, .{ 0, 1, mid + half }, .{ 0, 3, mid + half } }, &diag);
    defer tetra.deinit();
    // Classified by a point clear of the plate until the operand precondition
    // (2026-11-15): the tetrahedron, 1.5 tolerances thick, is below the boolean's minimum
    // feature size, refused
    try expectBelowFeatureSize(&plate, &tetra);
}

test "degeneracy: a plane between a flat tetrahedron's edges 3e-5 apart: below the minimum feature size, the split refused" {
    // The gap draws' second find (2026-11-14): a tetrahedron whose opposite edges are 1.5
    // intersection tolerances apart, cut by the plane x = z between them at 45°; the cut's
    // section on the plane is a triangle 2 long and 4.2e-5 across, its centroid a third of
    // the way across, the zone from the upper face, and no candidate clear of the
    // tetrahedron but its incenter (`unclassified`)
    const h = 0.75 * tol.xsect;
    var flat = try tetrahedron(.{ -1, 0, -h }, .{ 1, 0, -h }, .{ 0, -1, h }, .{ 0, 1, h });
    defer flat.deinit();
    var tetra = try helpers.moved(&flat, .{ -2e-5, -2e-5, -5e-6 });
    defer tetra.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // Split and classified at the section's incenter until the operand precondition
    // (2026-11-15): the tetrahedron, its edges 3e-5 apart, is below the minimum feature
    // size of the boolean a split is, refused
    try testing.expectError(error.Degenerate, trim.splitByPlane(testing.allocator, &tetra, .{ 1, 0, -1 }, 0, .{}, &diag));
    try testing.expectEqual(diagnostics.Code.below_feature_size, diag.first().?.code);
}

test "degeneracy: a void touching its outer shell along a line, at a point, or another void at a corner is refused by design; a solid in a cavity touching it is two solids" {
    // research/manifold-parity.md (2026-11-14): shells of one solid touch nowhere (a void
    // apart from its outer shell and every other void, ISO 10303-42), solids may touch.
    // A diamond prism's edge on a cube's face, cut out: it was one shell through a two-edge
    // loop of zero width on that face (genus 0, OpenCascade's InvalidImbricationOfWires)
    var cube = try box(.{ 0, 0, 0 }, .{ 4, 4, 4 });
    defer cube.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var outline = try primitives.polygon(testing.allocator, tol, &.{ .{ 2, 0 }, .{ 3, 1 }, .{ 2, 2 }, .{ 1, 1 } }, &diag);
    defer outline.deinit();
    var diamond0 = try @import("../construct/sweep.zig").extrude(testing.allocator, &outline, .{ 0, 0, 2 }, .{}, &diag);
    defer diamond0.deinit();
    var diamond = try helpers.moved(&diamond0, .{ 0, 0, 1 });
    defer diamond.deinit();
    try expectPinched(&cube, &diamond);
    // A tetrahedron's one corner on the cube's bottom (it passed by the void's vertex order)
    var tet = try tetrahedron(.{ 2, 2, 0 }, .{ 3, 1.5, 2 }, .{ 1, 1.5, 2 }, .{ 2, 3, 2 });
    defer tet.deinit();
    try expectPinched(&cube, &tet);
    // Two voids touching corner to corner
    var big = try box(.{ 0, 0, 0 }, .{ 6, 6, 6 });
    defer big.deinit();
    var first = try box(.{ 1, 1, 1 }, .{ 3, 3, 3 });
    defer first.deinit();
    var hollow = try sound(&big, &first, .difference);
    defer hollow.deinit();
    var second = try box(.{ 3, 3, 3 }, .{ 5, 5, 5 });
    defer second.deinit();
    try expectPinched(&hollow, &second);
    // An octahedron in a hollow cube's cavity, its corners on the floor and the roof: a
    // solid touching the cavity of another, two solids, which pass
    var cavity = try box(.{ 1, 1, 1 }, .{ 5, 5, 5 });
    defer cavity.deinit();
    var shell = try sound(&big, &cavity, .difference);
    defer shell.deinit();
    var octa = try @import("../construct/hull.zig").hull(testing.allocator, tol, &.{ .{ 3, 3, 1 }, .{ 3, 3, 5 }, .{ 3, 1.5, 3 }, .{ 3, 4.5, 3 }, .{ 1.5, 3, 3 }, .{ 4.5, 3, 3 } }, &diag);
    defer octa.deinit();
    var both = try sound(&shell, &octa, .@"union");
    defer both.deinit();
    try testing.expectEqual([2]usize{ 2, 1 }, shellKinds(&both));
    try testing.expectApproxEqAbs(216 - 64 + try volume(&octa), try volume(&both), CLOSE);
    const parts = try @import("../construct/decompose.zig").decompose(testing.allocator, &both, .{}, &diag);
    defer {
        for (parts) |*part| part.deinit();
        testing.allocator.free(parts);
    }
    try testing.expectEqual(@as(usize, 2), parts.len);
}

/// The difference of `a` and `b` refused by design (`pinched`).
fn expectPinched(a: *const Body, b: *const Body) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    if (pipeline.boolean(testing.allocator, a, b, .difference, .{}, &diag, null)) |result| {
        var made = result;
        made.deinit();
        return error.TestExpectedError;
    } else |e| {
        errdefer std.debug.print("{f}\n", .{diag});
        try testing.expectEqual(error.Degenerate, e);
    }
    try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
    try testing.expectEqual(diagnostics.EntityKind.shell, diag.first().?.entity.kind);
}

test "degeneracy: a corner 2.3e-5 under one with a gap of 6.4e-6 merges with it by both reaches, a ball past the zone, refused" {
    // research/consistent-tolerances.md's gapped corner: two boxes 9e-6 apart at an edge,
    // united, leave its ends merged with a gap of 6.36e-6; a box whose top corner lies
    // 2.3e-5 under one is within the tolerance and that gap of it, as vertex–edge and
    // vertex–face reach, but vertex–vertex reached the tolerance alone, left the two apart,
    // and an edge of one was found ending at the other: refused as an edge 0 long of 3.
    // Merged, their ball's radius is past the zone (`gap_too_large`), naming the vertex
    var p = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    defer p.deinit();
    var q = try box(.{ 1.000009, 1.000009, 0 }, .{ 2, 2, 1 });
    defer q.deinit();
    var u = try sound(&p, &q, .@"union");
    defer u.deinit();
    var g: Vec3 = undefined;
    var gap: f64 = 0;
    for (u.vertices.items, 0..) |v, i| if (!v.tombstone and v.gap > gap and u.point(VertexIndex.of(i))[2] == 0) {
        gap = v.gap;
        g = u.point(VertexIndex.of(i));
    };
    try testing.expectApproxEqAbs(@as(f64, 6.36e-6), gap, 1e-8);
    var r = try box(.{ g[0] - 3, g[1] - 3, -3 }, .{ g[0], g[1], -2.3e-5 });
    defer r.deinit();
    try expectRefused(&u, &r, .gap_too_large);
}

fn areaOf(body: *const Body) !f64 {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return (try mass.mass(body, .{}, &diag)).area;
}

/// The unit box and a box `lo`–`hi` turned `angle` about the z axis through `pivot`.
fn unitAndTurned(lo: Vec3, hi: Vec3, pivot: Vec3, angle: f64) ![2]Body {
    var a = try box(.{ 0, 0, 0 }, .{ 1, 1, 1 });
    errdefer a.deinit();
    var b = try box(lo, hi);
    defer b.deinit();
    return .{ a, try turned(&b, pivot, vec.Z3, angle) };
}

test "degeneracy: OCCT's H9, a hole through the box touching its side along a line, refused pinched; the rest made" {
    // After OCCT `tests/boolean/bop*_simple/H9`: its coordinates and areas; volumes and
    // counts worked out here. A square ½ on a side turned 30° about (¼,¼), corners (¼,¼),
    // (¼ + √3/4, ½), (√3/4, ½ + √3/4) and (0, ¼ + √3/4), the last on the side x = 0 to the
    // turn's rounding. The difference is the box with a square hole through it whose edge
    // lies on the side: one shell touching itself along a line, which OCCT keeps (area
    // 7.5) and Locus refuses by design. The intersection is the turned box (2 · ¼ + 2 ·
    // 1, ¼), the union the box, the swapped difference empty
    var pair = try unitAndTurned(.{ 0.25, 0.25, 0 }, .{ 0.75, 0.75, 1 }, .{ 0.25, 0.25, 0 }, std.math.degreesToRadians(30.0));
    defer for (&pair) |*body| body.deinit();
    try expectPinched(&pair[0], &pair[1]);
    var i = try sound(&pair[0], &pair[1], .intersection);
    defer i.deinit();
    try expectShape(&i, 0.25, 6, 1);
    try testing.expectApproxEqAbs(@as(f64, 2.5), try areaOf(&i), CLOSE);
    var u = try sound(&pair[0], &pair[1], .@"union");
    defer u.deinit();
    try expectShape(&u, 1, 6, 1);
    try testing.expectEqual(@as(usize, 8), u.counts().vertices);
    var s = try sound(&pair[1], &pair[0], .difference);
    defer s.deinit();
    try testing.expect(s.isEmpty());
}

test "degeneracy: H9's void, the turned box inside the box but for its edge on the side, refused pinched" {
    // research/occt-tests.md (O5): H9's turned box cut to z from ¼ to ¾, so the difference
    // is a void whose edge (0, ¼ + √3/4) lies on the side x = 0 along a segment: a void
    // touching its outer shell along a line, which no STEP solid holds (P1, Leo's
    // decision); OCCT has no such case of its own. The intersection is the turned box
    var pair = try unitAndTurned(.{ 0.25, 0.25, 0.25 }, .{ 0.75, 0.75, 0.75 }, .{ 0.25, 0.25, 0 }, std.math.degreesToRadians(30.0));
    defer for (&pair) |*body| body.deinit();
    try expectPinched(&pair[0], &pair[1]);
    var i = try sound(&pair[0], &pair[1], .intersection);
    defer i.deinit();
    try expectShape(&i, 0.125, 6, 1);
}

test "degeneracy: OCCT's N3, a box under the box, its top's corner on the box's bottom edge: the bottom's one loop through that corner twice" {
    // After OCCT `tests/boolean/bop*_simple/N3`: its coordinates and areas; volumes and
    // counts worked out here. H9's turned square under the box (z from −1 to 0), its top
    // inside the box's bottom but for its corner (0, ¼ + √3/4, 0) on the bottom's edge.
    // The union is one solid whose bottom face is the square less the turned one: a hole
    // touching the outer boundary at that corner, one loop passing it twice (a hole loop
    // of its own sharing the corner would leave V − E + F − (L − F) one short of 2). The
    // box's 8 corners and the turned box's 8, one of them splitting the box's edge: V 16,
    // E 12 + 1 + 12, F 6 + 5, a loop each (16 − 25 + 11 = 2); area 6 + 5/2 − 2 · ¼, volume
    // 1¼. Nothing in common; each difference its first operand
    var pair = try unitAndTurned(.{ 0.25, 0.25, -1 }, .{ 0.75, 0.75, 0 }, .{ 0.25, 0.25, 0 }, std.math.degreesToRadians(30.0));
    defer for (&pair) |*body| body.deinit();
    var u = try sound(&pair[0], &pair[1], .@"union");
    defer u.deinit();
    try expectShape(&u, 1.25, 11, 1);
    try testing.expectApproxEqAbs(@as(f64, 8), try areaOf(&u), CLOSE);
    const counts = u.counts();
    try testing.expectEqual(@as(usize, 16), counts.vertices);
    try testing.expectEqual(@as(usize, 25), counts.edges);
    try testing.expectEqual(@as(usize, 11), counts.loops);
    // The corner on the edge, and the one loop that passes it twice
    const corner: Vec3 = .{ 0, 0.25 + @sqrt(3.0) / 4.0, 0 };
    var at: ?VertexIndex = null;
    for (u.vertices.items, 0..) |v, k| if (!v.tombstone and vec.length(vec.sub(u.point(VertexIndex.of(k)), corner)) < 1e-9) {
        at = VertexIndex.of(k);
    };
    var twice: usize = 0;
    for (u.loops.items, 0..) |l, k| {
        if (l.tombstone or l.first == .none) continue;
        var passes: usize = 0;
        var coedges = @import("../topology/traverse.zig").Coedges.init(&u, types.LoopIndex.of(k));
        while (try coedges.next()) |c| passes += @intFromBool(u.coedgeStart(c) == at.?);
        if (passes == 2) twice += 1 else try testing.expect(passes < 2);
    }
    try testing.expectEqual(@as(usize, 1), twice);
    // Touching face to face, nothing inside the other: the contacts are the turned box's
    // four top corners, the one on the edge among them
    var r = pipeline.Report.init(testing.allocator);
    defer r.deinit();
    var again = try helpers.reported(&pair[0], &pair[1], .@"union", .{}, &r);
    again.deinit();
    try testing.expectEqual(@as(usize, 4), r.contacts.items.len);
    var at_corner: usize = 0;
    for (r.contacts.items) |p| {
        try testing.expectApproxEqAbs(@as(f64, 0), p[2], 1e-12);
        at_corner += @intFromBool(vec.length(vec.sub(p, corner)) < 1e-9);
    }
    try testing.expectEqual(@as(usize, 1), at_corner);
    var i = try sound(&pair[0], &pair[1], .intersection);
    defer i.deinit();
    try testing.expect(i.isEmpty());
    var d = try sound(&pair[0], &pair[1], .difference);
    defer d.deinit();
    try expectShape(&d, 1, 6, 1);
    var s = try sound(&pair[1], &pair[0], .difference);
    defer s.deinit();
    try expectShape(&s, 0.25, 6, 1);
    try expectIdentities(&pair[0], &pair[1]);
}

test "degeneracy: OCCT's F5, G2 and G8, what a turned box inside the box leaves: rings of solids touching along edges" {
    // After OCCT `tests/boolean/bop*_simple/F5`, `G2` and `G8`: their coordinates and
    // areas; volumes and counts worked out here. Each difference is the box less a prism
    // whose corners lie on its sides, so its solids are prisms touching along the vertical
    // edges at those corners: one warning per edge, each solid's volume and faces. F5: the
    // diamond on the edge midpoints leaves four triangles of legs ½, a ring (⅛ each). G2:
    // corners (¼,0), (1,⅜) and (0,½) on the sides leave the triangles (0,0) (¼,0) (0,½)
    // and (¼,0) (1,0) (1,⅜) and the pentagon (0,½) (¾,⅞) (1,⅜) (1,1) (0,1), a ring of three
    // (1/16, 9/64, 21/64). G8: corners (0,¼) and (√3/4,0) leave the triangle they make with
    // the origin and the rest of the box, a heptagon, touching at both (√3/32, ¾ − √3/32)
    const Ring = struct { name: []const u8, lo: Vec3, size: Vec3, turn: f64, touching: usize, volumes: []const f64, faces: []const usize };
    const sqrt3: f64 = @sqrt(3.0);
    const rings = [_]Ring{
        .{ .name = "F5", .lo = .{ 0, 0.5, 0 }, .size = .{ std.math.sqrt2 / 2.0, std.math.sqrt2 / 2.0, 1 }, .turn = std.math.degreesToRadians(-45.0), .touching = 4, .volumes = &.{ 0.125, 0.125, 0.125, 0.125 }, .faces = &.{ 5, 5, 5, 5 } },
        .{ .name = "G2", .lo = .{ 0.25, 0, 0 }, .size = .{ 3 * @sqrt(5.0) / 8.0, @sqrt(5.0) / 4.0, 1 }, .turn = std.math.atan2(@as(f64, 1), 2), .touching = 3, .volumes = &.{ 1.0 / 16.0, 9.0 / 64.0, 21.0 / 64.0 }, .faces = &.{ 5, 5, 7 } },
        .{ .name = "G8", .lo = .{ 0, 0.25, 0 }, .size = .{ 0.5, 0.5, 1 }, .turn = std.math.degreesToRadians(-30.0), .touching = 2, .volumes = &.{ sqrt3 / 32, 0.75 - sqrt3 / 32 }, .faces = &.{ 5, 9 } },
    };
    for (rings) |ring| {
        errdefer std.debug.print("{s}\n", .{ring.name});
        var pair = try unitAndTurned(ring.lo, vec.add(ring.lo, ring.size), ring.lo, ring.turn);
        defer for (&pair) |*body| body.deinit();
        var d = try sound(&pair[0], &pair[1], .difference);
        defer d.deinit();
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        var again = try pipeline.boolean(testing.allocator, &pair[0], &pair[1], .difference, .{}, &diag, null);
        again.deinit();
        try testing.expectEqual(ring.touching, warned(&diag, .solids_touch));
        const parts = try decompose.decompose(testing.allocator, &d, .{}, &diag);
        defer {
            for (parts) |*part| part.deinit();
            testing.allocator.free(parts);
        }
        try testing.expectEqual(ring.volumes.len, parts.len);
        // Smallest first, as the rows list them
        var order: [4]usize = .{ 0, 1, 2, 3 };
        var volumes: [4]f64 = undefined;
        for (parts, 0..) |*part, k| volumes[k] = try volume(part);
        std.mem.sort(usize, order[0..parts.len], volumes[0..parts.len], struct {
            fn lessThan(v: []const f64, x: usize, y: usize) bool {
                return v[x] < v[y];
            }
        }.lessThan);
        for (order[0..parts.len], ring.volumes, ring.faces) |k, want_volume, want_faces| {
            try testing.expectApproxEqAbs(want_volume, volumes[k], CLOSE);
            try testing.expectEqual(want_faces, parts[k].counts().faces);
        }
    }
}

test "degeneracy: OCCT's Q9, a turned box's edge lying in the other's top as it crosses it: one edge there in every result" {
    // After OCCT `tests/boolean/bop*_simple/Q9`: its coordinates and areas; volumes and
    // counts worked out here (corpus_test.zig's `TURNED` has them). The turned box's edge
    // from (1,1,3) to (2,1,3) lies in the big box's top: imprinted from both operands' faces
    // and the section, it must be one edge of each result, not two, nor split
    var a = try box(.{ 0, 0, 0 }, .{ 3, 3, 3 });
    defer a.deinit();
    var b0 = try box(.{ 1, 1, 3 }, .{ 2, 2, 4 });
    defer b0.deinit();
    var b = try turned(&b0, .{ 1, 1, 3 }, vec.X3, std.math.degreesToRadians(-30.0));
    defer b.deinit();
    const Pair = struct { first: *const Body, second: *const Body, op: pipeline.Op };
    for ([_]Pair{ .{ .first = &a, .second = &b, .op = .intersection }, .{ .first = &a, .second = &b, .op = .difference }, .{ .first = &a, .second = &b, .op = .@"union" }, .{ .first = &b, .second = &a, .op = .difference } }) |p| {
        errdefer std.debug.print("{s}{s}\n", .{ @tagName(p.op), if (p.first == &b) ", swapped" else "" });
        var r = try sound(p.first, p.second, p.op);
        defer r.deinit();
        var on: usize = 0;
        var length: f64 = 0;
        for (r.edges.items) |e| {
            if (e.flags.tombstone) continue;
            const s = r.point(e.start);
            const t = r.point(e.end);
            const along = @abs(s[1] - 1) < 1e-9 and @abs(s[2] - 3) < 1e-9 and @abs(t[1] - 1) < 1e-9 and @abs(t[2] - 3) < 1e-9;
            if (!along) continue;
            on += 1;
            length += @abs(t[0] - s[0]);
        }
        try testing.expectEqual(@as(usize, 1), on);
        try testing.expectApproxEqAbs(@as(f64, 1), length, CLOSE);
    }
}

test "degeneracy: OCCT's bug25354_33 and _34, a turned box touching a box at one point: a corner on an edge, two edges crossing" {
    // After OCCT `tests/bugs/modalg_5/bug25354_33` and `_34`: their coordinates and their
    // section's one vertex; measures and counts worked out here. A cube of 10 under and in
    // front of the cube of 10 at the origin, turned −45° about the z axis through
    // (5,0,0): its top (in the other's bottom's plane) a diamond whose corner (5,0,0) lies
    // on the other's edge y = z = 0. _34 raises it by 6 and turns it 45° about the x axis
    // through (5,0,0) too: its vertical edge through that point now crosses the other's
    // edge there, both at an inner point. Either way they touch at that point alone: the
    // union two cubes (12 faces, 1200, 2000), nothing in common, the difference the first,
    // and the report's one contact the point
    var a = try box(.{ 0, 0, 0 }, .{ 10, 10, 10 });
    defer a.deinit();
    for ([_]bool{ false, true }) |skew| {
        errdefer std.debug.print("{s}\n", .{if (skew) "bug25354_34" else "bug25354_33"});
        var b0 = try box(.{ 5, -10, if (skew) -4 else -10 }, .{ 15, 0, if (skew) 6 else 0 });
        defer b0.deinit();
        var b1 = try turned(&b0, .{ 5, 0, 0 }, vec.Z3, std.math.degreesToRadians(-45.0));
        defer b1.deinit();
        var b = if (skew) try turned(&b1, .{ 5, 0, 0 }, vec.X3, std.math.degreesToRadians(45.0)) else try b1.clone(testing.allocator);
        defer b.deinit();
        var u = try sound(&a, &b, .@"union");
        defer u.deinit();
        try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&u));
        try testing.expectEqual(@as(usize, 12), u.counts().faces);
        try testing.expectApproxEqAbs(@as(f64, 2000), try volume(&u), CLOSE);
        try testing.expectApproxEqAbs(@as(f64, 1200), try areaOf(&u), CLOSE);
        var i = try sound(&a, &b, .intersection);
        defer i.deinit();
        try testing.expect(i.isEmpty());
        var d = try sound(&a, &b, .difference);
        defer d.deinit();
        try expectShape(&d, 1000, 6, 1);
        try testing.expectEqual(@as(usize, 8), d.counts().vertices);
        for ([_]pipeline.Op{ .@"union", .difference }) |op| {
            var r = pipeline.Report.init(testing.allocator);
            defer r.deinit();
            var again = try helpers.reported(&a, &b, op, .{}, &r);
            again.deinit();
            try testing.expectEqual(@as(usize, 1), r.contacts.items.len);
            try testing.expect(vec.length(vec.sub(r.contacts.items[0], .{ 5, 0, 0 })) < 1e-9);
        }
        try expectIdentities(&a, &b);
    }
}

/// A probe's operation (research/occt-tests.md §4 a): a result `sound` passes, or null,
/// refused with a code of `pipeline.REFUSALS` (`refused`), never a guard's. `shift` gets
/// the result's reported shift.
fn madeOrRefused(a: *const Body, b: *const Body, op: pipeline.Op, refused: *?diagnostics.Code, shift: *f64) !?Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var report = pipeline.Report.init(testing.allocator);
    defer report.deinit();
    refused.* = null;
    shift.* = 0;
    if (pipeline.boolean(testing.allocator, a, b, op, .{}, &diag, &report)) |result| {
        var made = result;
        made.deinit();
        shift.* = report.shift;
        return try sound(a, b, op);
    } else |e| {
        errdefer std.debug.print("{s}: {s}, {f}\n", .{ @tagName(op), @errorName(e), diag });
        const code = diag.first().?.code;
        try testing.expect(std.mem.indexOfScalar(diagnostics.Code, &pipeline.REFUSALS, code) != null);
        refused.* = code;
        return null;
    }
}

/// The probes' oracle, weaker by design than the corpus's: each operation of `a` and `b`,
/// and of `b` and `a`, made and sound or refused by type; the volume identities among
/// those made, to the slab the tolerance may count either way (its thickness over both
/// operands' faces) and the results' reported shifts; the union and the intersection the
/// same either way round, both made (their solids alike, their volumes within that slab)
/// or both refused with one code.
fn expectProbe(a: *const Body, b: *const Body) !void {
    const ops = [_]pipeline.Op{ .@"union", .intersection, .difference };
    var results: [2][3]?Body = @splat(@splat(null));
    defer for (&results) |*row| for (row) |*r| if (r.*) |*body| body.deinit();
    var codes: [2][3]?diagnostics.Code = undefined;
    var shifts: [2][3]f64 = undefined;
    var volumes: [2][3]f64 = @splat(@splat(0));
    for ([2][2]*const Body{ .{ a, b }, .{ b, a } }, 0..) |operands, k| {
        errdefer std.debug.print("{s} first\n", .{if (k == 0) "a" else "b"});
        for (ops, 0..) |op, j| {
            results[k][j] = try madeOrRefused(operands[0], operands[1], op, &codes[k][j], &shifts[k][j]);
            if (results[k][j]) |*r| volumes[k][j] = try volume(r);
        }
    }
    const slab = tol.xsect * (try areaOf(a) + try areaOf(b));
    const operand_volumes = [2]f64{ try volume(a), try volume(b) };
    for (0..2) |k| {
        errdefer std.debug.print("{s} first\n", .{if (k == 0) "a" else "b"});
        const made = [3]bool{ results[k][0] != null, results[k][1] != null, results[k][2] != null };
        if (made[0] and made[1]) try testing.expectApproxEqAbs(operand_volumes[0] + operand_volumes[1], volumes[k][0] + volumes[k][1], slab + shifts[k][0] + shifts[k][1]);
        if (made[1] and made[2]) try testing.expectApproxEqAbs(operand_volumes[k] - volumes[k][1], volumes[k][2], slab + shifts[k][1] + shifts[k][2]);
    }
    for (0..2) |j| {
        errdefer std.debug.print("{s} either way round: {any} and {any}\n", .{ @tagName(ops[j]), codes[0][j], codes[1][j] });
        try testing.expectEqual(codes[0][j], codes[1][j]);
        if (results[0][j]) |*r| {
            try testing.expectEqual(shellKinds(r), shellKinds(&results[1][j].?));
            try testing.expectApproxEqAbs(volumes[0][j], volumes[1][j], slab + shifts[0][j] + shifts[1][j]);
        }
    }
}

test "degeneracy: OCCT's D4 and C6 scaled until the neck and the spike are 2, 1 and ½ intersection tolerances: made and sound, or refused by type" {
    // research/occt-tests.md §2 C: one geometry at several scales, the feature the
    // tolerance has to decide on shrinking past it: D4's neck between the bar's end and
    // the box's corner, C6's spike past the box's side
    for ([_][]const f64{ &D4_SCALES, &C6_SCALES }, [_]f64{ 0.5, 0.25 }) |scales, width| {
        for (scales) |s| {
            errdefer std.debug.print("{s} at scale {d}\n", .{ if (width == 0.5) "D4" else "C6", s });
            var a = try box(.{ 0, 0, 0 }, .{ s, s, s });
            defer a.deinit();
            var b0 = try box(.{ 0, 0, 0 }, .{ s * BAR_LENGTH, s * width, s });
            defer b0.deinit();
            var b = try turned(&b0, .{ 0, 0, 0 }, vec.Z3, BAR_TURN);
            defer b.deinit();
            try expectProbe(&a, &b);
        }
    }
}

test "degeneracy: OCCT's H7 thinned to 5, 3 and 1.5 intersection tolerances, the twin path on a sliver: made and sound, or refused alike either way round" {
    // research/occt-tests.md §4 a (research-review item 2's open question): H7's bar,
    // whose top and bottom lie in the box's, as thin as a few tolerances, so its common
    // part with the box is a strip of coincident faces that thin
    for (H7_WIDTHS) |n| {
        errdefer std.debug.print("{d} intersection tolerances wide\n", .{n});
        var pair = try unitAndTurned(.{ 0, 0.25, 0 }, .{ n * tol.xsect, 0.75, 1 }, .{ 0, 0.25, 0 }, std.math.degreesToRadians(240.0));
        defer for (&pair) |*body| body.deinit();
        try expectProbe(&pair[0], &pair[1]);
    }
}

test "degeneracy: OCCT's spec case, a box 1e-6 and 1e-4 taller and deeper than the one it is joined to, united either way round" {
    // After OCCT's `dox/specification/boolean_operations` §11a.1.1, case 2: a cube of 10
    // and the next box along x, 10 + δ high and deep. Within the zone (δ = 1e-6) the tops
    // and backs are one plane each (D28: the plane moving the faces least, here the two
    // alike to rounding and taken by the planes' fixed order, z = 10 and y = 10), so either
    // union is the same box, 6 faces, 20 · 10², to its reported shift;
    // at five intersection tolerances (δ = 1e-4) the steps stay, both unions the same nine
    // faces (the ends, bottom and front whole, two tops, two backs, the second's L-shaped
    // strip at x = 10 left uncovered), 1000 + 10 · (10 + δ)²
    for (OVERSIZES) |over| {
        errdefer std.debug.print("{e} over\n", .{over});
        var a = try box(.{ 0, 0, 0 }, .{ 10, 10, 10 });
        defer a.deinit();
        var b = try box(.{ 10, 0, 0 }, .{ 20, 10 + over, 10 + over });
        defer b.deinit();
        try expectProbe(&a, &b);
        const within = over < tol.zone;
        for ([_]bool{ false, true }) |swapped| {
            errdefer std.debug.print("{s}\n", .{if (swapped) "b ∪ a" else "a ∪ b"});
            var r = pipeline.Report.init(testing.allocator);
            defer r.deinit();
            var u = try helpers.reported(if (swapped) &b else &a, if (swapped) &a else &b, .@"union", .{}, &r);
            defer u.deinit();
            try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&u));
            try testing.expectEqual(@as(usize, if (within) 6 else 9), u.counts().faces);
            const side = if (within) 10 else 10 + over;
            const want = if (within) 20 * side * side else 1000 + 10 * side * side;
            if (within) try testing.expect(r.shift > 0);
            try testing.expectApproxEqAbs(want, try volume(&u), r.shift + CLOSE);
        }
    }
}

test "degeneracy: OCCT's bug33361, four hexahedra whose corners miss by 1e-4, joined one by one: made and sound, or refused by type" {
    // Dirty input (research/occt-tests.md, O6; OCCT checks the shape only): each
    // hexahedron as the hull of its corners, the fold of OCCT's fuses, each step by the
    // probes' oracle; a step refused ends the fold
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var solids: [4]Body = undefined;
    var built: usize = 0;
    defer for (solids[0..built]) |*s| s.deinit();
    for (&BUG33361, &solids) |*corners, *s| {
        s.* = try @import("../construct/hull.zig").hull(testing.allocator, tol, corners, &diag);
        built += 1;
    }
    var current = try solids[0].clone(testing.allocator);
    defer current.deinit();
    for (solids[1..], 1..) |*next, k| {
        errdefer std.debug.print("step {d}\n", .{k});
        try expectProbe(&current, next);
        var refused: ?diagnostics.Code = null;
        var shift: f64 = 0;
        const made = try madeOrRefused(&current, next, .@"union", &refused, &shift) orelse break;
        current.deinit();
        current = made;
    }
}

test "degeneracy: a box's top bent 1.5e-5 off a line at its middle corner, a plate hinged on it, meet along that line either way round" {
    // Step 1 of closing M4 (order symmetry): two faces parallel within the angle sharing
    // three merged vertices meet along their line when every vertex lies within its reach
    // of it. The line ran from the first merged vertex, the first operand's: from the bent
    // corner the far corner was 3e-5 off it (beyond reach: one plane, then refused
    // below_feature_size), between the corners the bent one was 1.5e-5 off (a line, made).
    // The line through the two farthest apart is the vertices' own
    const d = 1.5e-5;
    const slope = 0.005;
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // The pentagon from the bent corner, so that the box numbers it first
    var outline = try primitives.polygon(testing.allocator, tol, &.{ .{ 5, d }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 0, 0 } }, &diag);
    defer outline.deinit();
    var raised = try @import("../construct/sweep.zig").extrude(testing.allocator, &outline, .{ 0, 0, 1 }, .{}, &diag);
    defer raised.deinit();
    var a = try helpers.moved(&raised, .{ 0, 0, -1 });
    defer a.deinit();
    // The plate's bottom rises from the box's front edge at the slope, its front leaning out
    // (upright, it would hold both of the box's front walls in its plane)
    const corners = [_]Vec3{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 10 * slope }, .{ 0, 10, 10 * slope }, .{ 0, -1, 1 }, .{ 10, -1, 1 }, .{ 10, 10, 1 }, .{ 0, 10, 1 } };
    var b = try @import("../construct/hull.zig").hull(testing.allocator, tol, &corners, &diag);
    defer b.deinit();
    try expectAllSound(&a, &b);
}

test "degeneracy: a box over the notch of an L-shaped top, its bottom the intersection tolerance over the top's plane, is apart from it, not refused" {
    // Step 1 of closing M4 (order symmetry): "on a face" is on its plane and not outside
    // it. Vertex–face, edge–face's paves and the feature-size rule asked the plane first
    // and refused a vertex at its reach of it to rounding, though the vertex lay over the
    // notch, outside the face, where its height decides nothing (`pave.placeOnFace`)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var outline = try primitives.polygon(testing.allocator, tol, &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 0.5 }, .{ 0.5, 0.5 }, .{ 0.5, 1 }, .{ 0, 1 } }, &diag);
    defer outline.deinit();
    var raised = try @import("../construct/sweep.zig").extrude(testing.allocator, &outline, .{ 0, 0, 1 }, .{}, &diag);
    defer raised.deinit();
    var l = try helpers.moved(&raised, .{ 0, 0, -1 });
    defer l.deinit();
    var b = try box(.{ 0.6, 0.6, tol.xsect }, .{ 0.9, 0.9, 1 });
    defer b.deinit();
    try expectAllSound(&l, &b);
}

test "degeneracy: a plate's edge within reach of a slab's corner in their shared plane, past it across, is refused, not welded on by the imprint" {
    // The nightly's find (2026-11-18, run 44376458944), reduced: an L-shaped slab's top
    // and a plate's bottom 1.97e-4 to 1.99e-4 above it (the plate turned 3e-7 rad about y),
    // at a tolerance of 2e-4: one plane. The plate's back edge runs 3e-5 inside the slab's
    // notch edge in that plane, within the tolerance of the notch's outer corner across
    // (a pave) and 2.0036e-4 from its inner corner (none). In the slab's plane that corner
    // is 3e-5 from the plate's edge, and the imprint's overlay welded it onto the edge's
    // block, a cut the paves did not make (`imprint_unmatched`). Within the tolerance is
    // not transitive across the dropped height: refused (`below_feature_size`), as placed
    // and turned
    const zone_4 = Tolerance.fromZone(1e-4);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var outline = try primitives.polygon(testing.allocator, zone_4, &.{ .{ 0, 0 }, .{ 6, 0 }, .{ 6, 2 }, .{ 3, 2 }, .{ 3, 4 }, .{ 0, 4 } }, &diag);
    defer outline.deinit();
    var raised = try @import("../construct/sweep.zig").extrude(testing.allocator, &outline, .{ 0, 0, 1 }, .{}, &diag);
    defer raised.deinit();
    var slab = try helpers.moved(&raised, .{ 0, 0, -1 });
    defer slab.deinit();
    const h0 = 1.99e-4;
    var flat_plate = try helpers.fuzzPlaced(zone_4, .{ 8, 5 - 3e-5, 1 }, .{ -1, -3, h0 }, vec.Z3, 0, .{ 0, 0, 0 }, .{ 0, 0, 0 });
    defer flat_plate.deinit();
    var plate = try turned(&flat_plate, .{ 0, 0, h0 }, vec.Y3, 3e-7);
    defer plate.deinit();
    for ([_]f64{ 0, 0.3, 1.1 }) |angle| {
        var a = try turned(&slab, .{ 1, 2, 3 }, .{ 1, 2, 3 }, angle);
        defer a.deinit();
        var b = try turned(&plate, .{ 1, 2, 3 }, .{ 1, 2, 3 }, angle);
        defer b.deinit();
        for ([_]pipeline.Op{ .@"union", .difference }) |op| for ([_]bool{ false, true }) |swap| {
            var refusal = Diagnostics.init(testing.allocator);
            defer refusal.deinit();
            errdefer std.debug.print("turned {d}, {s}, swapped {}\n", .{ angle, @tagName(op), swap });
            const result = if (swap) pipeline.boolean(testing.allocator, &b, &a, op, .{}, &refusal, null) else pipeline.boolean(testing.allocator, &a, &b, op, .{}, &refusal, null);
            if (result) |made| {
                var body = made;
                body.deinit();
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.Degenerate, err);
                try testing.expectEqual(diagnostics.Code.below_feature_size, refusal.first().?.code);
            }
        };
    }
}

test "degeneracy: a face through the line two solids of the other operand touch along takes its side from both solids' wedges there" {
    // The nightly's find (2026-11-18, run 44393151795), reduced: two boxes touching along
    // x = y = 1, one body, and a turned box whose face lies in the plane x = y through that
    // line, cut by it into a piece in each box. The other operand has an edge of each box
    // over the line (the warning `touching_along_line`), and the seams read the first:
    // one piece left that box's wedge, outside, while its sections had it inside the
    // other box (`unclassified`). The operand's material about the line is both boxes'
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var left = try box(.{ 0, 0, 0 }, .{ 1, 1, 2 });
    defer left.deinit();
    var right = try box(.{ 1, 1, 0 }, .{ 2, 2, 2 });
    defer right.deinit();
    var pair = try pipeline.boolean(testing.allocator, &left, &right, .@"union", .{}, &diag, null);
    defer pair.deinit();
    try testing.expectEqual(@as(usize, 2), pair.counts().shells);
    var flat_cutter = try box(.{ 0, -1.5, 0.5 }, .{ 3, 0, 1.5 });
    defer flat_cutter.deinit();
    var cutter = try turned(&flat_cutter, .{ 0, 0, 0 }, vec.Z3, std.math.pi / 4.0);
    defer cutter.deinit();
    for ([_]pipeline.Op{ .intersection, .difference }) |op| {
        var forward = try sound(&pair, &cutter, op);
        defer forward.deinit();
        var swapped = try sound(&cutter, &pair, op);
        defer swapped.deinit();
    }
    // United, the cutter joins the boxes into one solid that still touches itself along
    // the line above and below it: refused by design (`pinched`), not unclassified
    for ([2]bool{ false, true }) |swap| {
        var refusal = Diagnostics.init(testing.allocator);
        defer refusal.deinit();
        const result = if (swap) pipeline.boolean(testing.allocator, &cutter, &pair, .@"union", .{}, &refusal, null) else pipeline.boolean(testing.allocator, &pair, &cutter, .@"union", .{}, &refusal, null);
        if (result) |made| {
            var body = made;
            body.deinit();
            return error.TestUnexpectedResult;
        } else |err| {
            try testing.expectEqual(error.Degenerate, err);
            try testing.expectEqual(diagnostics.Code.pinched, refusal.first().?.code);
        }
    }
}

test "degeneracy: a difference keeping a spike thinner than the tolerance at its root is refused as pinched, not made" {
    // The 10K session's find on d5d78c4b (2026-11-19, locus and locus_solids, bc), as the
    // fuzzer drew it: a box cut by a plate (zone 1e-4) united with a hull, less a second
    // hull whose face passes 1.7 to 3.3 tolerances inside the first hull's ridge for 0.8
    // units under the plate. The difference keeps the ridge's sliver outside that face as
    // a spike whose root under the plate's bottom is a triangle 2·xsect a side: a wall
    // thinner than the tolerance, the second hull's face within it of the plate bottom's
    // notch. The assembly's pinch test reads topology only and made it; the overlap rules,
    // run on a result whose features come nearer than its minimum feature size, refuse it
    var box_part = try helpers.fuzzPlaced(tol, .{ 1, 3, 2 }, .{ 2, 1, 2 }, vec.Z3, 0, .{ 0, 0, -0.5 }, .{ -2e-3, 2e-3, 0 });
    defer box_part.deinit();
    var plate = try helpers.fuzzPlaced(Tolerance.fromZone(1e-4), .{ 100, 100, 1 }, .{ -48, 2, 3 }, vec.Z3, 0, .{ 0, 0, 0 }, .{ -1.9999999855049283e-4, 2e-4, -2.000000014495072e-4 });
    defer plate.deinit();
    var cut = try sound(&box_part, &plate, .intersection);
    defer cut.deinit();
    var ridge = try fuzzHull(&.{ .{ 1, 4, 1 }, .{ 3, 2, 4 }, .{ 3, 3, 0 }, .{ 1, 4, 1 }, .{ 3, 0, 1 }, .{ 3, 1, 2 }, .{ 3, 1, 0 } }, .{ 0, 0, 0.5 }, .{ 0, 2.0000000006394886e-4, 0 });
    defer ridge.deinit();
    var joined = try sound(&cut, &ridge, .@"union");
    defer joined.deinit();
    var cutter = try fuzzHull(&.{ .{ 2, 4, 2 }, .{ 3, 4, 3 }, .{ 1, 1, 3 }, .{ 4, 0, 1 }, .{ 3, 3, 1 }, .{ 3, 3, 1 }, .{ 2, 2, 4 }, .{ 3, 3, 4 } }, .{ 0, 0, 1 }, .{ 0, 5e-5, 0 });
    defer cutter.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    if (pipeline.boolean(testing.allocator, &joined, &cutter, .difference, .{}, &diag, null)) |made| {
        var body = made;
        body.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(error.Degenerate, err);
        try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
    }
    // The union and the intersection keep no such wall: made and sound
    for ([_]pipeline.Op{ .@"union", .intersection }) |op| {
        var made = try sound(&joined, &cutter, op);
        defer made.deinit();
    }
}

test "degeneracy: a hull's tip a plate cuts off, a tetrahedron as high as the tolerance, is refused below the feature size, not called invalid" {
    // The locus fuzzer's find (2026-11-19, the sessions on 3681979b, bd), as it drew it: a
    // hull's lowest corner 2.05e-4 inside a plate's side (zone 1e-4, an intersection
    // tolerance of 2e-4). Their intersection is the tip, a tetrahedron 2.05e-4 high: every
    // face of it within the tolerance of another's plane, which the overlap rules, run on a
    // result nearer than its minimum feature size, find meeting away from their boundaries.
    // No decision of the tolerance keeps such faces apart: refused as the operands'
    // precondition refuses features that near (`below_feature_size`), not called invalid
    var hull = try fuzzHull(&.{ .{ 1, 2, 4 }, .{ 2, 2, 0 }, .{ 0, 0, 2 }, .{ 1, 4, 2 } }, .{ 0, -0.5, 1 }, .{ 5e-6, 0, 0 });
    defer hull.deinit();
    var plate = try helpers.fuzzPlaced(Tolerance.fromZone(1e-4), .{ 100, 150, 1 }, .{ 2, -48, 0 }, vec.Z3, 0, .{ 0, 0, 0 }, .{ -2.000000014495072e-4, -2.000000014495072e-4, 2e-2 });
    defer plate.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    if (pipeline.boolean(testing.allocator, &hull, &plate, .intersection, .{}, &diag, null)) |made| {
        var body = made;
        body.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(error.Degenerate, err);
        try testing.expectEqual(diagnostics.Code.below_feature_size, diag.first().?.code);
    }
    // The union and the difference keep the tip's corner apart from the rest: made and sound
    for ([_]pipeline.Op{ .@"union", .difference }) |op| {
        var made = try sound(&hull, &plate, op);
        defer made.deinit();
    }
}

test "degeneracy: a tetrahedron's edge 2.7e-5 from where two boxes' faces meet, their union's section edges lie on their faces within the gaps carried onto them" {
    // The locus fuzzer's find (2026-11-18, 10K session on a5301ce8, au), reduced: a
    // tetrahedron's edge passes 2.7e-5 from the corner where a box's side and top meet a
    // second box's side (beyond the intersection tolerance, 2e-5, of the corner, within it
    // and the gaps of the faces). The merged vertex there lay past the intersection
    // tolerance off the second box's side, within its gap; the section lines drawn through
    // it left that plane by as much, and their edges, made with no gap, were off their
    // face (`edge_off_surface`). Each
    // edge's gap covers its line's height over its faces' planes, and its ends' gaps cover
    // its own (`pipeline.coverFaces`, OCCT's CorrectCurveOnSurface and UpdateVertex). The
    // union is made; the difference, the corner's edge touching the tetrahedron's within
    // the tolerance, is refused by design (`pinched`)
    var t = try tetrahedron(.{ 3.5, 3, 5 }, .{ 0.5, 4, 2 }, .{ 1.5, 0, 3 }, .{ 4.5, 0, 1 });
    defer t.deinit();
    var a = try box(.{ -tol.xsect, 3, 2.5 }, .{ 2 - tol.xsect, 4, 3.5 });
    defer a.deinit();
    var b = try box(.{ 1, 0.5 - tol.xsect, 1 }, .{ 3, 3.5 - tol.xsect, 4 });
    defer b.deinit();
    var ta = try sound(&t, &a, .@"union");
    defer ta.deinit();
    var both = try sound(&ta, &b, .@"union");
    defer both.deinit();
    try expectProbe(&ta, &b);
}

/// The hull of `points` at the tolerance `tol`, moved by `move` and then by `nudge`, as the
/// solids fuzzer composes a placement (one rounding of each, in its order).
fn fuzzHull(points: []const Vec3, move: Vec3, nudge: Vec3) !Body {
    return fuzzHullPlaced(points, vec.Z3, 0, null, move, nudge);
}

/// The hull of `points` at the tolerance `tol`, turned by `turn` about `axis` through the
/// solids fuzzer's grid middle, scaled by `scale`, then moved by `move` and by `nudge`, as
/// the fuzzer composes a placement (one rounding of each, in its order).
pub fn fuzzHullPlaced(points: []const Vec3, axis: Vec3, turn: f64, scale: ?Vec3, move: Vec3, nudge: Vec3) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var shape = try @import("../construct/hull.zig").hull(testing.allocator, tol, points, &diag);
    defer shape.deinit();
    var place = mat.Affine.translate(.{ 0, 0, 0 });
    if (turn != 0) place = mat.Affine.rotateAbout(FUZZ_GRID_MIDDLE, vec.normalized(axis).?, turn).compose(&place);
    if (scale) |by| place = mat.Affine.scaleBy(by).compose(&place);
    place = mat.Affine.translate(move).compose(&place);
    place = mat.Affine.translate(nudge).compose(&place);
    return @import("../construct/transform.zig").transform(testing.allocator, &shape, &place, .{}, &diag);
}

test "degeneracy: a hull's side piece with one corner the tolerance over its bottom and another well clear of it intersects a plate the same either way round" {
    // The locus fuzzer's find (2026-11-19, the sessions on ab354a0a, bh), as it drew it: a
    // hull's back corner 4e-4 inside a plate's side (zone 1e-4, an intersection tolerance
    // of 2e-4), its bottom 1e-4 over the plate's. Their intersection keeps a triangle of
    // the hull's side there, one corner on the hull's bottom, one 2e-4 and 7e-13 over it,
    // the tolerance to rounding, and one 1.6e-3 over it. The piece does not lie on the
    // bottom, its third corner eight tolerances off; the fragment rule refused it at the
    // second corner (`at_tolerance`) when its loop began there, the hull first, and made
    // it the plate first, where the bottom's piece kept is the plate's
    const Affine = mat.Affine;
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var p0 = try helpers.boxAt(Tolerance.fromZone(1e-4), .{ -48, 2, 1 }, .{ 102, 52, 4 });
    defer p0.deinit();
    // The generator's placement, composed as it composes it
    var place = Affine.translate(vec.ZERO3);
    place = Affine.scaleBy(.{ 0.5, 2, 1 }).compose(&place);
    place = Affine.translate(.{ -1, 0, -1 }).compose(&place);
    place = Affine.translate(.{ 0, -2.000000014779289e-4, 0 }).compose(&place);
    var plate = try @import("../construct/transform.zig").transform(testing.allocator, &p0, &place, .{}, &diag);
    defer plate.deinit();
    var hull = try fuzzHull(&.{ .{ 3, 4, 0 }, .{ 4, 0, 2 }, .{ 1, 3, 0 }, .{ 1, 1, 0 }, .{ 2, 3, 4 }, .{ 4, 4, 0 }, .{ 1, 1, 3 } }, .{ 0, 0, 0 }, .{ 1e-4, 1.999999999431566e-4, 1e-4 });
    defer hull.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection }) |op| {
        var forward = try sound(&plate, &hull, op);
        defer forward.deinit();
        var swapped = try sound(&hull, &plate, op);
        defer swapped.deinit();
        try testing.expectEqual(forward.counts(), swapped.counts());
    }
}

test "degeneracy: a hull's edge laid in a box's bottom along its edge, one end on that edge and the other a hair off it, is refused below the feature size, not split by the imprint" {
    // The solids fuzzer's find (2026-11-19, the sessions on ab354a0a, bf), as it drew it: a
    // tetrahedron's bottom edge 5e-6 over a box's bottom, along the bottom's edge at 1e-6
    // rad and 1.9e-5 to 2e-5 inside it. Its first corner is 1.965e-5 from that edge, on it
    // (the tolerance 2e-5), and its second 2.06e-5, off it: the paves split the box's edge
    // at the first and laid the hull's edge in the bottom as a section from there. The
    // box's edge then runs from that corner, 1.9e-5 off its line, to the box's own, and the
    // second corner lies 7.3e-6 from it in the bottom's plane: the imprint's overlay welded
    // it onto the piece the paves kept it off (`imprint_unmatched`), every operation, either
    // way round. A piece left on a face within the tolerance of the face's own boundary in
    // its plane, other than where the paves joined them, is refused, as two pieces that
    // near are (`pave.sectionsApart`)
    var whole = try helpers.fuzzPlaced(tol, .{ 4, 3, 4 }, .{ 0, 0, 0 }, vec.Y3, std.math.pi, .{ 0, 0, 0 }, .{ 0, 0, 0 });
    defer whole.deinit();
    var hull = try fuzzHullPlaced(&.{ .{ 3, 0, 0 }, .{ 0, 2, 3 }, .{ 4, 3, 2 }, .{ 2, 0, 0 }, .{ 3, 0, 0 } }, vec.Y3, 1e-6, .{ 1, 2, 1 }, .{ 0, 0, 0 }, .{ -2e-3, 5e-6, 2.000000008526513e-5 });
    defer hull.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
        for ([_][2]*const Body{ .{ &whole, &hull }, .{ &hull, &whole } }) |pair| {
            var diag = Diagnostics.init(testing.allocator);
            defer diag.deinit();
            if (pipeline.boolean(testing.allocator, pair[0], pair[1], op, .{}, &diag, null)) |made| {
                var body = made;
                body.deinit();
                return error.TestUnexpectedResult;
            } else |err| {
                try testing.expectEqual(error.Degenerate, err);
                try testing.expectEqual(diagnostics.Code.below_feature_size, diag.first().?.code);
            }
        }
    }
}

test "degeneracy: a hull's bottom edge on a box's bottom face, the box's edge on the hull's side, unite and intersect the same either way round" {
    // The locus fuzzer's find (2026-11-19, the sessions on 3681979b, be), reduced from its
    // wall to a box: a hull's bottom edge lies 1e-5 under a box's bottom face and the box's
    // bottom edge 1.4e-5 off the hull's side, the two edges 3.2e-5 apart. The merged
    // vertices on both faces, sorted along the faces' line, had two at the box's side at one
    // position there, 3.2e-5 apart across it, ordered by their numbers, which follow the
    // operands': one way round the gap from the section's start to the hull's edge was a
    // piece of the section, the other way the gap to the box's corner, and the union and
    // the intersection differed in faces. Two at one position go by the points themselves,
    // along a direction the line alone gives
    var hull = try fuzzHull(&.{ .{ 3, 1, 4 }, .{ 3, 3, 2 }, .{ 0, 3, 0 }, .{ 4, 4, 1 }, .{ 1, 3, 0 } }, .{ 0, 0, 0 }, .{ -2.000000005684342e-5, -1e-5, -1.9999999943156583e-5 });
    defer hull.deinit();
    var wall = try box(.{ -1.748, 2.00002, -1e-5 }, .{ 0.0020299999999999745, 3.00002, 0.99999 });
    defer wall.deinit();
    for ([_]pipeline.Op{ .@"union", .intersection }) |op| {
        var forward = try sound(&hull, &wall, op);
        defer forward.deinit();
        var swapped = try sound(&wall, &hull, op);
        defer swapped.deinit();
        try testing.expectEqual(forward.counts(), swapped.counts());
    }
}

test "degeneracy: a piece's bottom lying in a plate's bottom with another piece's corner on it unites the same either way round, the corner its own shell's alone" {
    // The 10K session's find on 8db70212 (2026-11-18, locus_solids), as the fuzzer drew it:
    // a hull less a box, less another hull, is two pieces sharing a corner, one's bottom quad
    // 9e-5 under a plate's bottom (zone 1e-4). United with the plate, the quad's edges inside
    // the plate's bottom went one by one in the order of their numbers, the operands': one
    // way round a slit stayed with the other piece's corner at its tip, the other way a loop
    // of that corner alone, which `kvh` took from under the other piece's edges. Inner edges
    // go whole; the corner stays its own shell's (a point of two shells' faces needs only
    // one's boundary)
    var hull = try fuzzHull(&.{ .{ 2, 4, 0 }, .{ 3, 1, 3 }, .{ 2, 3, 4 }, .{ 1, 4, 2 } }, .{ 0.5, 0.5, 2e-5 }, .{ 0, 0, 0 });
    defer hull.deinit();
    var cut = try helpers.fuzzPlaced(tol, .{ 3, 2, 1 }, .{ 1, 2, 2 }, vec.Z3, 0, .{ 1, 0, 0 }, .{ 0, 2e-3, 1e-5 });
    defer cut.deinit();
    var once = try sound(&hull, &cut, .difference);
    defer once.deinit();
    var other = try fuzzHull(&.{ .{ 0, 4, 0 }, .{ 0, 0, 2 }, .{ 3, 1, 1 }, .{ 0, 3, 1 }, .{ 2, 0, 1 }, .{ 4, 1, 3 } }, .{ 0, 0, 0 }, .{ -2e-3, -2.000000005684342e-5, -1e-5 });
    defer other.deinit();
    var pieces = try sound(&once, &other, .difference);
    defer pieces.deinit();
    try testing.expectEqual(@as(usize, 2), pieces.counts().shells);
    var plate = try helpers.fuzzPlaced(Tolerance.fromSize(200), .{ 200, 150, 1 }, .{ -98, -98, 3 }, vec.Z3, 0, .{ 1, 0, 0 }, .{ 0, 2e-4, 1e-4 });
    defer plate.deinit();
    var forward = try sound(&pieces, &plate, .@"union");
    defer forward.deinit();
    var swapped = try sound(&plate, &pieces, .@"union");
    defer swapped.deinit();
    try testing.expectEqual(forward.counts(), swapped.counts());
    try testing.expect(!hasPointLoop(&forward));
    try testing.expect(!hasPointLoop(&swapped));
}

test "degeneracy: a hull's corner on a box's edge at its end's strip to rounding is refused, not collapsed into the box's corner" {
    // The 10K session's find on 6007ab01 (2026-11-18, locus and locus_solids), as the
    // fuzzer drew it: a turned bar united with a hull, less another hull, has a corner at
    // (3.000005, 4, 1.999995); a box's corner (3, 4.00002, 2) is 2.12e-5 from it, past the
    // tolerance of 2e-5, and the box's edge from that corner passes 7.1e-6 from it, its
    // foot the tolerance along the edge from the box's corner to 1e-17: at the bound of
    // the corner's strip. Compared raw it was a pave, the edge between the corners, the
    // minimum feature size long, collapsed into the box's corner and the hull's edge moved
    // there ended 2.0138e-5 off its line with no gap (`vertex_off_curve`; `coverLine` now
    // grows the gap, simplify's test). At the bound to rounding it is refused (D27)
    var bar = try helpers.fuzzPlaced(tol, .{ 4, 1, 1 }, .{ 0, 3, 0 }, .{ 1, 2, 3 }, 0.014142253478516982, .{ 1, 0, 0 }, .{ 0, 1e-5, 2e-5 });
    defer bar.deinit();
    var first = try fuzzHull(&.{ .{ 3, 3, 2 }, .{ 1, 1, 2 }, .{ 1, 2, 0 }, .{ 1, 1, 3 }, .{ 3, 0, 3 }, .{ 3, 0, 1 } }, .{ 0, 1, 0 }, .{ 5e-6, 0, -5e-6 });
    defer first.deinit();
    var joined = try sound(&bar, &first, .@"union");
    defer joined.deinit();
    var second = try fuzzHull(&.{ .{ 1, 4, 0 }, .{ 4, 2, 4 }, .{ 0, 1, 4 }, .{ 1, 2, 4 }, .{ 0, 2, 2 }, .{ 1, 1, 3 }, .{ 0, 0, 3 } }, .{ 0.5, 0, 0.5 }, .{ 0, 5e-6, 0 });
    defer second.deinit();
    var less = try sound(&joined, &second, .difference);
    defer less.deinit();
    var post = try helpers.fuzzPlaced(tol, .{ 1, 2, 2 }, .{ 3, 2, 2 }, vec.Z3, 0, .{ -1, 0, 0 }, .{ 0, 2e-5, 0 });
    defer post.deinit();
    try expectAtTolerance(&less, &post, .@"union");
}

test "degeneracy: a plate's top 0.8° off a box's top, its edge the tolerance under it, a point under where the two pass through each other is outside the difference" {
    // The locus fuzzer's find (2026-11-19, the sessions on ab354a0a, bg), as it drew it: a
    // plate (zone 1e-4) turned by the angular tolerance about x, less a box whose top lies
    // 2e-4, the intersection tolerance, over the plate's front top edge. The edge is on
    // the box's top within the tolerance, so the pocket's roof, between the box's top and
    // the plate's, starts at that edge (D28: the edge keeps its line), while the two
    // planes' true line lies 0.014 on: in that band the plate's top is under the box's,
    // up to 2e-4, more than the zone. A ray up from the pocket met the plate's top first
    // there, leaving, and the point read inside the difference, which the membership
    // oracle found. Two meetings within the faces' reach of each other are one place,
    // whose order says nothing: another ray decides
    var plate = try helpers.fuzzPlaced(Tolerance.fromZone(1e-4), .{ 100, 100, 4 }, .{ 2, 2, 0 }, vec.X3, 0.014142253476507214, .{ 0, 0, 0 }, .{ 2.0000000144976702e-4, -2.0000000144976702e-4, 2.0000000144976702e-4 });
    defer plate.deinit();
    var cutter = try helpers.fuzzPlaced(tol, .{ 3, 3, 2 }, .{ 0, 1, 1 }, vec.X3, 1.5707963267948966, .{ 0, -0.5, 0 }, .{ 2.0000000005684343e-4, 0, 1.999999999431566e-4 });
    defer cutter.deinit();
    var pocketed = try sound(&plate, &cutter, .difference);
    defer pocketed.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var index = try FaceIndex.build(testing.allocator, &pocketed, &diag);
    defer index.deinit(testing.allocator);
    // Under the band, in the pocket (the first the fuzzer's point) and before the plate, and over it
    for ([_]Vec3{ .{ 2.334200000000986, 1.9746873372535072, 3.8747999999999427 }, .{ 2.9, 1.98, 2.5 }, .{ 2.1, 1.975, 3.99 }, .{ 2.5, 1.978, 4.1 } }) |p| {
        errdefer std.debug.print("at ({d}, {d}, {d})\n", .{ p[0], p[1], p[2] });
        try testing.expectEqual(point_in_body.Place.outside, try point_in_body.classify(testing.allocator, &pocketed, &index, p, .{}, &diag));
    }
    // In the plate beside the pocket, and in the roof where it has grown past the tolerance
    for ([_]Vec3{ .{ 3.5, 2.2, 3 }, .{ 2.5, 2.4, 4.0035 } }) |p| {
        errdefer std.debug.print("at ({d}, {d}, {d})\n", .{ p[0], p[1], p[2] });
        try testing.expectEqual(point_in_body.Place.inside, try point_in_body.classify(testing.allocator, &pocketed, &index, p, .{}, &diag));
    }
}

/// The plate of the tests of a hull's top shallow to it, as the solids fuzzer placed it:
/// x from 2, its top at z = 4, at a zone of 1e-4.
pub fn shallowPlate() !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var drawn = try helpers.boxAt(Tolerance.fromZone(1e-4), .{ 2, -48, 1 }, .{ 52, 52, 3 });
    defer drawn.deinit();
    var place = mat.Affine.translate(vec.ZERO3);
    place = mat.Affine.translate(.{ 0, 0, 1 }).compose(&place);
    place = mat.Affine.translate(.{ 0, 5e-5, 0 }).compose(&place);
    return @import("../construct/transform.zig").transform(testing.allocator, &drawn, &place, .{}, &diag);
}

test "degeneracy: a hull's top at the angular tolerance to a plate's, two corners within the tolerance under it, takes the plate's strip beside them as under it" {
    // The locus fuzzer's find (2026-11-20, the session on 6f0faa84, bl), as it drew it less
    // a plate that plays no part: a hull turned 0.01414 rad about y, its top's corners at
    // x = 2.028 1.8e-4 under a plate's top (zone 1e-4, an intersection tolerance of 2e-4),
    // on it, the plate's side at x = 2. The two tops are parallel within the angular
    // tolerance (by 1.4e-14) and not in one plane, so they meet along the line through
    // those corners, the hull's top rising from it over the plate's edge, 2.2e-4 over
    // it there. The planes' own line is 0.0127 from the corners' and through the strip of
    // the plate's top between them and its edge: the strip is under the hull's top along
    // the corners' line as the paves made it, and its points are either side of that top,
    // none farther than 2.2e-4. The seam there was passed over, the faces parallel; a ray
    // from a point 1.4e-4 over the hull's top read the strip outside and kept it, and the
    // corners' line had three faces (`edge_coedge_count`), every operation either way
    var plate = try shallowPlate();
    defer plate.deinit();
    var hull = try fuzzHullPlaced(&SHALLOW_HULL, vec.Y3, TURN_AT_ANGLE, null, .{ 0, 0.5, 0 }, .{ 2e-5, 0, SHALLOW_LIFTS[0] });
    defer hull.deinit();
    try expectAllSound(&hull, &plate);
    // The same solid whichever operand comes first
    var forward = try sound(&hull, &plate, .@"union");
    defer forward.deinit();
    var swapped = try sound(&plate, &hull, .@"union");
    defer swapped.deinit();
    try testing.expectEqual(forward.counts(), swapped.counts());
}

test "degeneracy: a hull's top at the angular tolerance to a plate's or past it, its corners from the tolerance under the plate's top to over it, mirrored or not, is joined and cut either way round" {
    // The cases about the find above: the hull lifted so that its top's corners are 1.8e-4,
    // 1.4e-4, 1e-4 and 5e-5 under the plate's top and 5e-5 over it, turned at the angular
    // tolerance (the tops meeting along the corners' line) and past it (along their
    // planes' own), the hull as drawn and mirrored in y
    var plate = try shallowPlate();
    defer plate.deinit();
    for ([_]f64{ TURN_AT_ANGLE, TURN_PAST_ANGLE }) |turn| for (SHALLOW_LIFTS) |lift| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("turned {d}, lifted {e}, mirrored {}\n", .{ turn, lift, mirrored });
        var points = SHALLOW_HULL;
        if (mirrored) for (&points) |*p| {
            p[1] = 3 - p[1];
        };
        var hull = try fuzzHullPlaced(&points, vec.Y3, turn, null, .{ 0, 0.5, 0 }, .{ 2e-5, 0, lift });
        defer hull.deinit();
        try expectAllSound(&hull, &plate);
    };
}

/// The prism of cross-section `profile` (x and y, `RIDGE_*`) along z from 0 to 2, turned by
/// `turn` about its ridge (the z axis: positive lifts the face along +x off y = 0, negative
/// dips it under), mirrored in x or not, then lifted by `lift` in y.
pub fn ridgePrism(profile: []const vec.Vec2, turn: f64, mirrored: bool, lift: f64) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sheet = try primitives.polygon(testing.allocator, tol, profile, &diag);
    defer sheet.deinit();
    var drawn = try @import("../construct/sweep.zig").extrude(testing.allocator, &sheet, .{ 0, 0, 2 }, .{}, &diag);
    defer drawn.deinit();
    var place = mat.Affine.rotateAbout(vec.ZERO3, vec.Z3, turn);
    if (mirrored) place = mat.Affine.mirror(vec.X3).compose(&place);
    place = mat.Affine.translate(.{ 0, lift, 0 }).compose(&place);
    return @import("../construct/transform.zig").transform(testing.allocator, &drawn, &place, .{}, &diag);
}

/// Each operation of `a` and `b`, either way round, made and sound, the identities to the
/// tolerance; their union `solids` solids, the same with a ray cast from every fragment no
/// seam tells the side of (no contagion: the fragments `classify.wedgeSide` passes over
/// are a ray's each), and their intersection `common` solids (none where they only touch).
fn expectSolidCounts(a: *const Body, b: *const Body, solids: usize, common: usize) !void {
    try helpers.expectIdentitiesAtTolerance(a, b);
    try helpers.expectIdentitiesAtTolerance(b, a);
    var joined = try sound(a, b, .@"union");
    defer joined.deinit();
    try testing.expectEqual([2]usize{ solids, 0 }, shellKinds(&joined));
    var report = pipeline.Report.init(testing.allocator);
    defer report.deinit();
    var by_rays = try helpers.reported(a, b, .@"union", .{ .contagion = false }, &report);
    defer by_rays.deinit();
    try testing.expectEqual(joined.counts(), by_rays.counts());
    try testing.expectEqual(shellKinds(&joined), shellKinds(&by_rays));
    try testing.expectApproxEqAbs(try volume(&joined), try volume(&by_rays), CLOSE);
    var shared = try sound(a, b, .intersection);
    defer shared.deinit();
    try testing.expectEqual([2]usize{ common, 0 }, shellKinds(&shared));
}

test "degeneracy: a wedge resting on its ridge in a plate's face, its face beside the plate's shallow to it within the angular tolerance or past it, touches the plate along the ridge where that face rises and cuts into it where it dips, mirrored or not, the ridge within the tolerance of the face or on it" {
    // The targeted review of the places that take "in one plane" from the normals' angle
    // (2026-11-20, after bl): `classify.wedgeSide` reads the plate's face beside the
    // ridge, an edge of the wedge, with the wedge's shallow face "in the fragment's plane"
    // by the angle (`tol.parallel`) where the paves hold the two in no one plane (they
    // hinge at the ridge): toward the shallow face it tells no side (a ray's or another
    // seam's to tell), away from it the wedge's other face tells it alone; past the angle
    // both faces tell it. `pipeline.pairByWedges` then orders the four faces about the
    // ridge where the solids only touch, the shallow face the turn from the plate's. The
    // outcome is the geometry's whichever branch reads it: two solids touching along the
    // ridge where the face rises from the plate's, the wedge cut into the plate where it
    // dips under it, a ridge within the tolerance of the face on it
    var plate = try box(.{ -5, -2, -1 }, .{ 5, 0, 3 });
    defer plate.deinit();
    for (RIDGE_TURNS) |turn| for ([_]f64{ 1, -1 }) |sign| for ([_]bool{ false, true }) |mirrored| {
        // Mirrored at the angular tolerance only: the other turns' mirrors add no branch
        if (mirrored and turn != TURN_AT_ANGLE) continue;
        errdefer std.debug.print("turned {d}, mirrored {}\n", .{ sign * turn, mirrored });
        var wedge = try ridgePrism(&RIDGE_WEDGE, sign * turn, mirrored, 0);
        defer wedge.deinit();
        try expectSolidCounts(&plate, &wedge, if (sign > 0) 2 else 1, @intFromBool(sign < 0));
    };
    // Lifted: the rising face's ridge under the plate's face, the dipping one's over it
    for ([_]f64{ 1, -1 }, [_]f64{ RIDGE_LIFTS[1], RIDGE_LIFTS[0] }) |sign, lift| {
        errdefer std.debug.print("turned {d}, lifted {e}\n", .{ sign * TURN_AT_ANGLE, lift });
        var wedge = try ridgePrism(&RIDGE_WEDGE, sign * TURN_AT_ANGLE, false, lift);
        defer wedge.deinit();
        try expectSolidCounts(&plate, &wedge, if (sign > 0) 2 else 1, @intFromBool(sign < 0));
    }
}

test "degeneracy: a box's edge along a wedge's ridge, the wedge's face over the box's shallow to it within the angular tolerance or past it, or the box beside the ridge: they touch along the edge, or the wedge cuts into the box where its face dips" {
    // The same review: both operands' edges on the ridge, so each one's faces are read
    // about the other's edge (`classify.wedgeSide`: the box's face under the wedge's
    // shallow one runs onto it, no side; the box's side and the wedge's steep face are
    // read by both faces of the other's edge) and the four faces about the one line are
    // ordered with the shallow pair the turn apart (`pipeline.pairByWedges`). A box
    // beside the ridge, the shallow face away from it, touches the wedge along the edge
    var under = try box(.{ 0, -2, -1 }, .{ 5, 0, 3 });
    defer under.deinit();
    for (RIDGE_TURNS) |turn| for ([_]f64{ 1, -1 }) |sign| {
        errdefer std.debug.print("under the shallow face, turned {d}\n", .{sign * turn});
        var wedge = try ridgePrism(&RIDGE_WEDGE, sign * turn, false, 0);
        defer wedge.deinit();
        try expectSolidCounts(&under, &wedge, if (sign > 0) 2 else 1, @intFromBool(sign < 0));
    };
    var beside = try box(.{ -5, -2, -1 }, .{ 0, 0, 3 });
    defer beside.deinit();
    var wedge = try ridgePrism(&RIDGE_WEDGE, TURN_AT_ANGLE, false, 0);
    defer wedge.deinit();
    try expectSolidCounts(&beside, &wedge, 2, 0);
}

test "degeneracy: two wedges ridge to ridge, their facing faces shallow to each other within the angular tolerance or past it, touch along the ridge with a gap between the faces, join where the faces are one plane, and cut into each other where they cross" {
    // The same review: a wedge under y = 0 and one over it share the ridge, the lower's
    // top turned by the first angle and the upper's bottom by the second. The upper's
    // bottom the steeper, the two touch along the ridge, the faces the difference apart
    // about it (0.006 to 0.028: `pipeline.pairByWedges` orders them; within the angular
    // tolerance `classify.wedgeSide` reads each face as in the other's plane, which the
    // paves do not hold); the same turn, the faces are one plane and the wedges join; the
    // lower's top the steeper, they cut into each other
    const cases = [_]struct { under: f64, over: f64, solids: usize, common: usize }{
        .{ .under = 0, .over = TURN_AT_ANGLE, .solids = 2, .common = 0 },
        .{ .under = TURN_AT_ANGLE, .over = TURN_PAST_ANGLE, .solids = 2, .common = 0 },
        .{ .under = -TURN_AT_ANGLE, .over = TURN_AT_ANGLE, .solids = 2, .common = 0 },
        .{ .under = TURN_AT_ANGLE, .over = TURN_AT_ANGLE, .solids = 1, .common = 0 },
        .{ .under = 0, .over = -TURN_AT_ANGLE, .solids = 1, .common = 1 },
        .{ .under = TURN_AT_ANGLE, .over = RIDGE_TURNS[0], .solids = 1, .common = 1 },
    };
    for (cases) |case| {
        errdefer std.debug.print("the lower turned {d}, the upper {d}\n", .{ case.under, case.over });
        var lower = try ridgePrism(&RIDGE_WEDGE_UNDER, case.under, false, 0);
        defer lower.deinit();
        var upper = try ridgePrism(&RIDGE_WEDGE, case.over, false, 0);
        defer upper.deinit();
        try expectSolidCounts(&lower, &upper, case.solids, case.common);
    }
}

test "degeneracy: a wedge's strip past the angular tolerance to a plate's face, its far edge within the tolerance of the face, is joined to the plate along the strip; its far edge past the tolerance, the wedge touches the plate along its ridge or cuts into it" {
    // The same review, the two decisions the other way round: a strip 1e-3 wide from the
    // ridge, turned 0.018 (past the angular tolerance, 0.01414), has its far edge 1.8e-5
    // off the plate's face, within the tolerance, so the paves hold strip and face in one
    // plane (`liesIn`, by the strip's corners, whatever the angle) where
    // `classify.wedgeSide` reads the strip as across the face's plane by the angle. The
    // twins decide the strip and the seams the rest alike: one solid, joined along the
    // strip, rising or dipping, the plate through under it or a box ending at the ridge.
    // Turned 0.021, the far edge 2.1e-5 off, the strip is no part of the face: the wedge
    // touches the plate along the ridge, or cuts 2.1e-5 into it
    var plate = try box(.{ -5, -2, -1 }, .{ 5, 0, 3 });
    defer plate.deinit();
    var under = try box(.{ 0, -2, -1 }, .{ 5, 0, 3 });
    defer under.deinit();
    for ([_]f64{ 1, -1 }) |sign| {
        errdefer std.debug.print("turned {d} or {d}\n", .{ sign * RIDGE_STRIP_TURN_ON, sign * RIDGE_STRIP_TURN_OFF });
        var on = try ridgePrism(&RIDGE_STRIPPED, sign * RIDGE_STRIP_TURN_ON, false, 0);
        defer on.deinit();
        try expectSolidCounts(&plate, &on, 1, 0);
        try expectSolidCounts(&under, &on, 1, 0);
        var off = try ridgePrism(&RIDGE_STRIPPED, sign * RIDGE_STRIP_TURN_OFF, false, 0);
        defer off.deinit();
        try expectSolidCounts(&plate, &off, if (sign > 0) 2 else 1, @intFromBool(sign < 0));
    }
}

test "degeneracy: a block notched down to an edge in a plate's face, the notch's floor shallow to the face within the angular tolerance or past it, is joined and cut with the floor over the face or under it" {
    // The same review, a concave edge: the block holds the plate's face about the ridge
    // but for the notch over it, whose floor leaves the ridge the turn over the face (a
    // sliver of the block between them, which the block less the plate keeps as a solid of
    // its own, with the block's parts over and under the plate) or under it (the plate's
    // face shows in the notch). `classify.wedgeSide` reads the plate's face about the
    // ridge with the floor in its plane by the angle: toward the floor no side, away from
    // it behind the notch's wall, inside the block
    var plate = try box(.{ -5, -2, -1 }, .{ 5, 0, 3 });
    defer plate.deinit();
    for (RIDGE_TURNS) |turn| for ([_]f64{ 1, -1 }) |sign| {
        errdefer std.debug.print("turned {d}\n", .{sign * turn});
        var notched = try ridgePrism(&RIDGE_NOTCHED, sign * turn, false, 0);
        defer notched.deinit();
        try expectSolidCounts(&plate, &notched, 1, 1);
        var rest = try sound(&notched, &plate, .difference);
        defer rest.deinit();
        try testing.expectEqual([2]usize{ if (sign > 0) 3 else 2, 0 }, shellKinds(&rest));
    };
}

test "degeneracy: a keel in a plate's face, both faces of it shallow to the plate's within the angular tolerance or one past it, touches the plate where both rise, cuts into it either side where both dip, and through it where one does; a knife of two such faces lying on the plate is refused" {
    // The same review, both faces of the edge "in the fragment's plane" by the angle: a
    // block's bottom creased along the ridge, each side leaving it at its own angle to the
    // plate's face (`classify.wedgeSide` tells no side of the plate's face either way
    // along it where both are within the angular tolerance, and by one face where the
    // other is past it; `pipeline.pairByWedges` orders the four faces about the ridge,
    // each of the block's its angle from the plate's). Both rising, the block touches the
    // plate along the ridge, on the face or within the tolerance of it; both dipping, it
    // cuts into the plate either side of the ridge, the two cuts meeting along it; one
    // of each, it cuts in on one side only
    const cases = [_]struct { left: f64, right: f64, lift: f64, solids: usize, common: usize }{
        .{ .left = RIDGE_TURNS[0], .right = RIDGE_TURNS[0], .lift = 0, .solids = 2, .common = 0 },
        .{ .left = TURN_AT_ANGLE, .right = TURN_AT_ANGLE, .lift = 0, .solids = 2, .common = 0 },
        .{ .left = TURN_AT_ANGLE, .right = TURN_AT_ANGLE, .lift = RIDGE_LIFTS[1], .solids = 2, .common = 0 },
        .{ .left = RIDGE_TURNS[0], .right = TURN_PAST_ANGLE, .lift = 0, .solids = 2, .common = 0 },
        .{ .left = -RIDGE_TURNS[0], .right = -RIDGE_TURNS[0], .lift = 0, .solids = 1, .common = 2 },
        .{ .left = -TURN_AT_ANGLE, .right = -TURN_AT_ANGLE, .lift = 0, .solids = 1, .common = 2 },
        .{ .left = TURN_AT_ANGLE, .right = -TURN_AT_ANGLE, .lift = 0, .solids = 1, .common = 1 },
    };
    var plate = try box(.{ -5, -2, -1 }, .{ 5, 0, 3 });
    defer plate.deinit();
    for (cases) |case| {
        errdefer std.debug.print("left {d}, right {d}, lifted {e}\n", .{ case.left, case.right, case.lift });
        const profile = [_]vec.Vec2{ .{ 0, 0 }, .{ 3, 3 * @tan(case.right) }, .{ 3, 1 }, .{ -3, 1 }, .{ -3, 3 * @tan(case.left) } };
        var keel = try ridgePrism(&profile, 0, false, case.lift);
        defer keel.deinit();
        try expectSolidCounts(&plate, &keel, case.solids, case.common);
    }
    // A knife: both faces of the ridge to one side of it, within the angular tolerance of
    // each other and of the plate's face, which is within the tolerance of both by the
    // ridge (`pave.sandwiched`, the same angle deciding "parallel" there)
    const blade = [_]vec.Vec2{ .{ 0, 0 }, .{ 3, 3 * @tan(0.004) }, .{ 3, 3 * @tan(0.012) } };
    var knife = try ridgePrism(&blade, 0, false, 0);
    defer knife.deinit();
    try expectRefused(&plate, &knife, .below_feature_size);
    try expectRefused(&knife, &plate, .below_feature_size);
}

/// A box from `lo` to `hi` at the tolerance `t`, turned by `turn` about `axis` through the
/// solids fuzzer's grid middle, scaled by `scale`, then moved by `nudge`, as the fuzzer
/// composes a placement (one rounding of each, in its order).
fn fuzzBoxPlaced(t: Tolerance, lo: Vec3, hi: Vec3, axis: Vec3, turn: f64, scale: ?Vec3, nudge: Vec3) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var drawn = try helpers.boxAt(t, lo, hi);
    defer drawn.deinit();
    var place = mat.Affine.translate(vec.ZERO3);
    if (turn != 0) place = mat.Affine.rotateAbout(FUZZ_GRID_MIDDLE, vec.normalized(axis).?, turn).compose(&place);
    if (scale) |by| place = mat.Affine.scaleBy(by).compose(&place);
    place = mat.Affine.translate(nudge).compose(&place);
    return @import("../construct/transform.zig").transform(testing.allocator, &drawn, &place, .{}, &diag);
}

/// The slab of the tests of a top with an edge over its plane, as the solids fuzzer made
/// it: `LIPPED_HULL` (mirrored in y or not) under a plate (zone 1e-4) turned by `turn`,
/// its top 2e-4 under z = 2. The hull's edge between its corners at z = 2 less 2e-5 is
/// within the tolerance over the plate's top, on it, and bounds the slab's top where it
/// is (D28), 1.8e-4 over the top's plane.
fn lippedSlab(turn: f64, mirrored: bool) !Body {
    var points = LIPPED_HULL;
    if (mirrored) for (&points) |*p| {
        p[1] = 4 - p[1];
    };
    var hull = try fuzzHullPlaced(&points, vec.Z3, 0, null, .{ 0, 0, 0 }, .{ 2.000000005684342e-5, if (mirrored) 2e-3 else -2e-3, -2e-5 });
    defer hull.deinit();
    var cutter = try fuzzBoxPlaced(Tolerance.fromZone(1e-4), .{ -98, -48, 2 }, .{ 52, 102, 4 }, .{ 1, 2, 3 }, turn, .{ 2, 0.5, 0.5 }, .{ -2e-2, -5e-5, -1.999999972146702e-4 });
    defer cutter.deinit();
    return sound(&hull, &cutter, .intersection);
}

/// The plate over that slab (zone 1e-4), its side at x = 2 across the slab's edge, its
/// bottom `lift` over z = 2.
fn plateOverSlab(lift: f64) !Body {
    return fuzzBoxPlaced(Tolerance.fromZone(1e-4), .{ 2, -48, 2 }, .{ 52, 52, 4 }, vec.Z3, 0, null, .{ -1e-4, -2.0000000073896445e-4, lift });
}

test "degeneracy: a plate's bottom within the tolerance of an edge of a slab's top and past it of the top's plane, parallel to it, is refused below the feature size either way round" {
    // The locus fuzzer's find (2026-11-20, the session on 8a0a4a2c, bn), as it drew it: a
    // slab a plate cut from a hull, its top 2.7e-7 rad off level at z = 2 less 2e-4, one
    // edge of that top the hull's, 1.8e-4 over the top's plane (zone 1e-4, an intersection
    // tolerance of 2e-4), under a second plate whose bottom is 7e-5 over the edge and
    // 2.5e-4 over the top's plane. The edge lies on the bottom and the two faces do not
    // lie in one plane, parallel within the angular tolerance: the paves took them to meet
    // along the edge, and the top's side of the bottom there was read from the turn
    // between them, 2.1e-7, into the plate (`unclassified`, the seams of the slab
    // disagreeing; before the seam was read, a ray had it outside and the four faces
    // about the edge were ordered by that turn, `edge_coedge_count`). Two planes farther
    // apart than the tolerance do not meet along a line within it of both
    var slab = try lippedSlab(LIPPED_TURNS[0], false);
    defer slab.deinit();
    var plate = try plateOverSlab(LIPPED_LIFTS_APART[1]);
    defer plate.deinit();
    try expectRefused(&slab, &plate, .below_feature_size);
    try expectRefused(&plate, &slab, .below_feature_size);
}

test "degeneracy: a plate over a slab's top with an edge over its plane, the top a hair off level either way or level, mirrored or not: in the top's plane joined, past it and on the edge refused, clear of the edge two solids" {
    // The cases about the find above: the plate's bottom within the tolerance of the top's
    // plane (one plane with it: joined), past it of the plane and within it of the edge
    // (refused, whichever way the turn's noise falls: the unmirrored slab under a top
    // turned 1e-6 and the mirrored one under −1e-6 were `unclassified`, the level top
    // unmirrored `edge_coedge_count`, and the rest were made, two solids along the edge,
    // by the same noise), and past it of the edge (two solids apart)
    for (LIPPED_TURNS) |turn| for ([_]bool{ false, true }) |mirrored| {
        var slab = try lippedSlab(turn, mirrored);
        defer slab.deinit();
        for (LIPPED_LIFTS_IN_PLANE) |lift| {
            errdefer std.debug.print("turned {d}, mirrored {}, lifted {e}\n", .{ turn, mirrored, lift });
            var plate = try plateOverSlab(lift);
            defer plate.deinit();
            try helpers.expectIdentitiesAtTolerance(&slab, &plate);
            try helpers.expectIdentitiesAtTolerance(&plate, &slab);
            var joined = try sound(&slab, &plate, .@"union");
            defer joined.deinit();
            try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&joined));
        }
        for (LIPPED_LIFTS_APART) |lift| {
            errdefer std.debug.print("turned {d}, mirrored {}, lifted {e}\n", .{ turn, mirrored, lift });
            var plate = try plateOverSlab(lift);
            defer plate.deinit();
            try expectRefused(&slab, &plate, .below_feature_size);
            try expectRefused(&plate, &slab, .below_feature_size);
        }
        for (LIPPED_LIFTS_CLEAR) |lift| {
            errdefer std.debug.print("turned {d}, mirrored {}, lifted {e}\n", .{ turn, mirrored, lift });
            var plate = try plateOverSlab(lift);
            defer plate.deinit();
            try expectAllSound(&slab, &plate);
            var apart = try sound(&slab, &plate, .@"union");
            defer apart.deinit();
            try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&apart));
        }
    };
}

/// The slab of the tests of corners off their own face's plane: `LIPPED_HULL` (mirrored
/// in y or not) under a level plate (zone 1e-4) whose top is `lip` under the hull's edge
/// between its corners at z = 2 (over it when `lip` is negative). The edge is within the
/// tolerance of the plate's top, on it, and bounds the slab's top where it is (D28),
/// `lip` over the top's plane; the slab's bottom has the hull's corner (1, 3, 1) the same
/// way, `lip` over the bottom's plane.
fn lippedSlabAt(lip: f64, mirrored: bool) !Body {
    return lippedSlabTurned(lip, 0, mirrored);
}

/// That slab cut by a plate turned by `turn` as the solids fuzzer turned bn's (about
/// (1, 2, 3) through its grid's middle): its top that far off level.
pub fn lippedSlabTurned(lip: f64, turn: f64, mirrored: bool) !Body {
    var hull = try lippedHull(mirrored);
    defer hull.deinit();
    var cutter = try lipCutter(lip, turn);
    defer cutter.deinit();
    return sound(&hull, &cutter, .intersection);
}

/// The hull that slab is cut from, mirrored in y or not.
pub fn lippedHull(mirrored: bool) !Body {
    var points = LIPPED_HULL;
    if (mirrored) for (&points) |*p| {
        p[1] = 4 - p[1];
    };
    return fuzzHullPlaced(&points, vec.Z3, 0, null, .{ 0, 0, 0 }, .{ LIP_NUDGE[0], if (mirrored) -LIP_NUDGE[1] else LIP_NUDGE[1], LIP_NUDGE[2] });
}

/// The plate that cuts the slab from that hull: its top `lip` under the hull's edge,
/// turned by `turn`.
pub fn lipCutter(lip: f64, turn: f64) !Body {
    return fuzzBoxPlaced(LIP_TOLERANCE, .{ -98, -48, 2 }, .{ 52, 102, 4 }, .{ 1, 2, 3 }, turn, .{ 2, 0.5, 0.5 }, .{ -2e-2, -5e-5, LIP_NUDGE[2] - lip });
}

/// A wedge in the lifted edge's frame, its edge along that edge `dz` over it, its faces
/// rising at 45° to either side.
pub fn wedgeOver(dz: f64) [6]Vec3 {
    const z = LIP_Z + dz;
    return .{ .{ -0.5, 0, z }, .{ 0.5, 0, z }, .{ -0.5, 0.5, z + 0.5 }, .{ 0.5, 0.5, z + 0.5 }, .{ -0.5, -0.5, z + 0.5 }, .{ 0.5, -0.5, z + 0.5 } };
}

/// The frame of that slab's lifted edge, in x and y: its origin the edge's middle, or its
/// end at the hull's corner (0, 1, 2) (`at_end`); `along` runs to the hull's corner
/// (3, 0, 2), `inward` across the edge into the top. Mirrored as the slab is.
fn lipFrame(mirrored: bool, at_end: bool) struct { origin: Vec3, along: Vec3, inward: Vec3 } {
    const nudge_y = if (mirrored) -LIP_NUDGE[1] else LIP_NUDGE[1];
    const from: Vec3 = .{ LIP_NUDGE[0], (if (mirrored) @as(f64, 3) else 1) + nudge_y, 0 };
    const to: Vec3 = .{ 3 + LIP_NUDGE[0], (if (mirrored) @as(f64, 4) else 0) + nudge_y, 0 };
    const along = vec.normalized(vec.sub(to, from)).?;
    const left: Vec3 = .{ -along[1], along[0], 0 };
    return .{ .origin = if (at_end) from else vec.lerp(from, to, 0.5), .along = along, .inward = if (mirrored) vec.neg(left) else left };
}

/// The other operand `shape` of a test against the slab whose edge lies `lip` over its
/// top's plane (zone 1e-4), mirrored in y as the slab is.
pub fn lipOperand(shape: LipShape, lip: f64, mirrored: bool) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const world: ?[2]Vec3 = switch (shape) {
        .on_top => |s| .{ .{ s.foot[0][0], s.foot[0][1], LIP_Z - lip + s.lift }, .{ s.foot[1][0], s.foot[1][1], 3 } },
        .under => |s| .{ .{ s.foot[0][0], s.foot[0][1], 0 }, .{ s.foot[1][0], s.foot[1][1], LIP_Z - 1 - lip + s.lift } },
        .box => |b| b,
        else => null,
    };
    if (world) |b| {
        if (!mirrored) return helpers.boxAt(LIP_TOLERANCE, b[0], b[1]);
        return helpers.boxAt(LIP_TOLERANCE, .{ b[0][0], 4 - b[1][1], b[0][2] }, .{ b[1][0], 4 - b[0][1], b[1][2] });
    }
    switch (shape) {
        .by_edge, .by_end => |b| {
            const frame = lipFrame(mirrored, shape == .by_end);
            // The box in the right-handed frame of `along` and its left: across the edge
            // the other way when mirrored
            var drawn = try helpers.boxAt(LIP_TOLERANCE, if (mirrored) .{ b[0][0], -b[1][1], b[0][2] } else b[0], if (mirrored) .{ b[1][0], -b[0][1], b[1][2] } else b[1]);
            defer drawn.deinit();
            const place = mat.Affine.translate(frame.origin).compose(&mat.Affine.rotate(vec.Z3, std.math.atan2(frame.along[1], frame.along[0])));
            return @import("../construct/transform.zig").transform(testing.allocator, &drawn, &place, .{}, &diag);
        },
        .wedge => |points| {
            const frame = lipFrame(mirrored, false);
            var placed: [6]Vec3 = undefined;
            for (points, &placed) |q, *p| p.* = vec.add(vec.addScaled(vec.addScaled(frame.origin, frame.along, q[0]), frame.inward, q[1]), .{ 0, 0, q[2] });
            return @import("../construct/hull.zig").hull(testing.allocator, LIP_TOLERANCE, &placed, &diag);
        },
        else => unreachable,
    }
}

/// `a` and `b` meet as `want`: refused below the minimum feature size either way round;
/// or each operation made and sound, the union the solids `want` names and the
/// intersection a solid or none, the volume identities to the slab the tolerance may
/// count either way and the reports' shifts (`pipeline_test.expectIdentitiesAtTolerance`'s
/// measure), and the union and the intersection the same the other way round.
fn expectMeeting(a: *const Body, b: *const Body, want: Meeting) !void {
    if (want == .refused) {
        try expectRefused(a, b, .below_feature_size);
        return expectRefused(b, a, .below_feature_size);
    }
    var reports: [3]pipeline.Report = .{ .init(testing.allocator), .init(testing.allocator), .init(testing.allocator) };
    defer for (&reports) |*r| r.deinit();
    var u = try helpers.soundReported(a, b, .@"union", &reports[0]);
    defer u.deinit();
    var i = try helpers.soundReported(a, b, .intersection, &reports[1]);
    defer i.deinit();
    var d = try helpers.soundReported(a, b, .difference, &reports[2]);
    defer d.deinit();
    try testing.expectEqual([2]usize{ if (want == .two_solids) 2 else 1, 0 }, shellKinds(&u));
    try testing.expectEqual([2]usize{ if (want == .overlap) 1 else 0, 0 }, shellKinds(&i));
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const ma = try mass.mass(a, .{}, &diag);
    const mb = try mass.mass(b, .{}, &diag);
    const slab = CLOSE * @max(ma.volume + mb.volume, 1) + Tolerance.merge(a.tol, b.tol).xsect * @min(ma.area, mb.area);
    const vi = try volume(&i);
    try testing.expectApproxEqAbs(ma.volume + mb.volume, try volume(&u) + vi, slab + reports[0].shift + reports[1].shift);
    try testing.expectApproxEqAbs(ma.volume - vi, try volume(&d), slab + reports[1].shift + reports[2].shift);
    for ([_]pipeline.Op{ .@"union", .intersection }, [_]*const Body{ &u, &i }) |op, forward| {
        var swapped = try sound(b, a, op);
        defer swapped.deinit();
        try testing.expectEqual(forward.counts(), swapped.counts());
        try testing.expectEqual(shellKinds(forward), shellKinds(&swapped));
    }
}

/// Each of `cases` against its slab, mirrored in y and not.
fn expectLipCases(cases: []const LipCase) !void {
    for ([_]f64{ LIP_OVER, LIP_UNDER }) |lip| for ([_]bool{ false, true }) |mirrored| {
        var slab = try lippedSlabAt(lip, mirrored);
        defer slab.deinit();
        for (cases, 0..) |case, i| {
            if (case.lip != lip) continue;
            errdefer std.debug.print("case {d}: the edge {e} over the top's plane, mirrored {}\n", .{ i, lip, mirrored });
            var other = try lipOperand(case.shape, lip, mirrored);
            defer other.deinit();
            try expectMeeting(&slab, &other, case.want);
        }
    };
}

test "degeneracy: a box on the top of a slab whose edge lies off the top's plane, over it or under it, is joined in the top's plane, refused where the plane or the edge alone holds it, and apart past both" {
    // The targeted review after bn (2026-11-20): a boolean's result has corners up to the
    // tolerance off their own face's plane (D28), and every decision that takes a face's
    // corner for a point of its plane is asked here with one that is not. The top's
    // plane holds the box's bottom or the pair is not in one plane (`liesIn` by either
    // face's corners; one plane for the group, `Provenance.representative`): between the
    // plane and the edge, or at the edge's height, joined. A bottom within the tolerance
    // of the plane with the edge inside it past the tolerance of the bottom, or within it
    // of the edge and past it of the plane, holds one of the two alone: refused
    // (`blocksInside`, `hingedWithin`). Clear of the edge's reach the box is apart or
    // overlaps as the plane alone has it
    try expectLipCases(&LIP_ON_TOP);
}

test "degeneracy: a box through the top of a slab whose edge lies off the top's plane, across the edge, along it and beside it, cuts the slab as the edge's own line has it" {
    // The edge's line, not its foot in the top's plane, is what an edge of the box
    // passes within the tolerance of (edge–edge), and what a point of the top is on the
    // boundary by (`in_face.placeWithin`, measured in space); the section along it keeps
    // its line (`alongBoundary`, `runOnPlane`). A side 3e-4 inside the edge cuts the top
    // and the face under the edge 9e-5 apart where the edge is over the plane (the slab
    // is thinner than the tolerance there: refused) and 4.5e-4 apart where it is under
    try expectLipCases(&LIP_THROUGH);
}

test "degeneracy: an edge, a corner and a wedge on the edge of a slab that lies off its top's plane touch the slab along it, join it, or are refused where they are on the edge and off the plane" {
    // A box's edge or a wedge's within the tolerance of the lifted edge is on it
    // (vertex–edge, a common block), and its corner at the edge's end is that corner
    // (vertex–vertex), whatever the top's plane: beside the slab two solids touching, over
    // the top joined with it where its bottom is within the tolerance of the top's plane.
    // Within the tolerance of the edge and past it of the plane, a bottom parallel to
    // the top meets it along no line (`hingedWithin`), and a wedge's faces at 45° end
    // within the tolerance of a top they do not reach: refused
    try expectLipCases(&LIP_ALONG);
}

test "degeneracy: a box against the one corner of a slab's bottom that lies off the bottom's plane is joined, overlaps or touches at the corner as the bottom's plane has it, and is refused where the corner is past the tolerance inside it" {
    // One corner off the plane, not an edge: no line of merged vertices for two parallel
    // faces to meet along, so a box's top 1e-4 past the corner and 2.8e-4 past the
    // bottom's plane overlaps the slab by that; a top the tolerance from the plane with
    // the corner 2.8e-4 inside it is refused (`blocksInside`: the bottom's boundary
    // inside the box's top beyond reach of its plane)
    try expectLipCases(&LIP_UNDER_BOTTOM);
}

test "degeneracy: a slab whose edge lies off its top's plane is cut by planes at the top, along the edge and across it into parts that make it up" {
    // `trim.trimByPlane` on the same slabs: nothing in front of the top's plane, and the
    // whole behind it; a plane 5e-4 under the top, one along the edge 0.5 inside it and
    // one across the edge at its middle each cut it in two sound parts
    const oracle = @import("oracle_test.zig");
    for ([_]f64{ LIP_OVER, LIP_UNDER }) |lip| {
        errdefer std.debug.print("the edge {e} over the top's plane\n", .{lip});
        var slab = try lippedSlabAt(lip, false);
        defer slab.deinit();
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        const whole = try mass.mass(&slab, .{}, &diag);
        const close = CLOSE * @max(whole.volume, 1) + slab.tol.xsect * whole.area;
        const frame = lipFrame(false, false);
        const middle: Vec3 = .{ frame.origin[0], frame.origin[1], LIP_Z };
        var front = try trim.trimByPlane(testing.allocator, &slab, vec.Z3, LIP_Z - lip, .{}, &diag, null);
        defer front.deinit();
        try testing.expect(front.isEmpty());
        var back = try trim.trimByPlane(testing.allocator, &slab, vec.neg(vec.Z3), -(LIP_Z - lip), .{}, &diag, null);
        defer back.deinit();
        try oracle.expectSolid(&back, &diag);
        try testing.expectEqual(slab.counts(), back.counts());
        try testing.expectApproxEqAbs(whole.volume, try volume(&back), close);
        for ([_]struct { n: Vec3, at: f64 }{
            .{ .n = vec.Z3, .at = LIP_Z - lip - 5e-4 },
            .{ .n = frame.inward, .at = vec.dot(frame.inward, middle) + 0.5 },
            .{ .n = frame.along, .at = vec.dot(frame.along, middle) },
        }) |plane| {
            var parts = try trim.splitByPlane(testing.allocator, &slab, plane.n, plane.at, .{}, &diag);
            defer for (&parts) |*part| part.deinit();
            for (&parts) |*part| {
                try oracle.expectSolid(part, &diag);
                try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(part));
            }
            try testing.expectApproxEqAbs(whole.volume, try volume(&parts[0]) + try volume(&parts[1]), close);
        }
    }
}

test "degeneracy: what a boolean made of a slab whose edge lies off its top's plane is an operand of the next: cut across the edge, joined along it and joined under its bottom, then crossed by a bar" {
    // A chain's third step: the lifted edge cut in two by a box through it, kept whole
    // under a box joined along it, and the bottom's corner under a box joined to the
    // bottom; then a bar across the whole of each, through the top and at the edge's
    // height. Each made and sound, the identities at the tolerance, the union the same
    // the other way round
    const bar = [2]Vec3{ .{ 2.2, -1, 0.5 }, .{ 2.7, 4.5, 3.5 } };
    const bar_at_edge = [2]Vec3{ .{ 1.2, -1, LIP_Z }, .{ 1.7, 4.5, 3.5 } };
    const steps = [_]struct { shape: LipShape, op: pipeline.Op, then: [2]Vec3 }{
        .{ .shape = .{ .box = .{ .{ 1, -1, 1.5 }, .{ 2, 1.5, 3 } } }, .op = .difference, .then = bar },
        .{ .shape = .{ .box = .{ .{ 1, -1, 1.5 }, .{ 2, 1.5, 3 } } }, .op = .difference, .then = bar_at_edge },
        .{ .shape = .{ .by_edge = .{ .{ -0.5, 0, LIP_Z }, .{ 0.5, 1, 3 } } }, .op = .@"union", .then = bar_at_edge },
        .{ .shape = .{ .under = .{ .foot = FOOT_COVER, .lift = 0 } }, .op = .@"union", .then = bar },
    };
    for ([_]f64{ LIP_OVER, LIP_UNDER }) |lip| {
        var slab = try lippedSlabAt(lip, false);
        defer slab.deinit();
        for (steps, 0..) |step, i| {
            errdefer std.debug.print("step {d}: the edge {e} over the top's plane\n", .{ i, lip });
            var other = try lipOperand(step.shape, lip, false);
            defer other.deinit();
            var kept = try sound(&slab, &other, step.op);
            defer kept.deinit();
            var then = try helpers.boxAt(LIP_TOLERANCE, step.then[0], step.then[1]);
            defer then.deinit();
            try helpers.expectIdentitiesAtTolerance(&kept, &then);
            var forward = try sound(&kept, &then, .@"union");
            defer forward.deinit();
            var swapped = try sound(&then, &kept, .@"union");
            defer swapped.deinit();
            try testing.expectEqual(forward.counts(), swapped.counts());
        }
    }
}

test "degeneracy: a slab whose edge lies off its top's plane measures, meshes and holds points as its faces' planes and that edge have it" {
    // The readers of a result: the mesh closed and manifold through the corners off
    // their planes, its volume the solid's to the slab the tolerance allows; points clear
    // of the boundary by the lifted edge inside and outside as the wedge there has them
    const tessellate = @import("../mesh/tessellate.zig");
    const validate = @import("../mesh/validate.zig");
    for ([_]f64{ LIP_OVER, LIP_UNDER }) |lip| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("the edge {e} over the top's plane, mirrored {}\n", .{ lip, mirrored });
        var slab = try lippedSlabAt(lip, mirrored);
        defer slab.deinit();
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        const measured = try mass.mass(&slab, .{}, &diag);
        var mesh = try tessellate.tessellate(testing.allocator, &slab, .{}, .{}, &diag);
        defer mesh.deinit(testing.allocator);
        try testing.expect((try validate.grade(testing.allocator, mesh.triangles, mesh.positions.len)).isManifoldClosed());
        var six: f64 = 0;
        for (mesh.triangles) |t| six += vec.dot(mesh.positions[t[0]], vec.cross(mesh.positions[t[1]], mesh.positions[t[2]]));
        try testing.expectApproxEqAbs(measured.volume, six / 6, slab.tol.xsect * measured.area);
        var index = try FaceIndex.build(testing.allocator, &slab, &diag);
        defer index.deinit(testing.allocator);
        const frame = lipFrame(mirrored, false);
        const top = LIP_Z - lip;
        // 0.01 inside the edge the slab is 0.009 thick under its top
        const inside = vec.add(vec.addScaled(frame.origin, frame.inward, 0.01), .{ 0, 0, top - 3e-3 });
        const over = vec.add(vec.addScaled(frame.origin, frame.inward, 0.01), .{ 0, 0, top + 1e-3 });
        const beside = vec.add(vec.addScaled(frame.origin, frame.inward, -1e-3), .{ 0, 0, LIP_Z });
        try testing.expectEqual(.inside, try point_in_body.classify(testing.allocator, &slab, &index, inside, .{}, &diag));
        try testing.expectEqual(.outside, try point_in_body.classify(testing.allocator, &slab, &index, over, .{}, &diag));
        try testing.expectEqual(.outside, try point_in_body.classify(testing.allocator, &slab, &index, beside, .{}, &diag));
    };
}

test "degeneracy: a box across a slab's lifted edge, its bottom within the tolerance of the edge and past it of the top's plane, the two faces sharing only where its sides cross the edge, is refused below the feature size either way round, mirrored or not" {
    // The targeted review's find (2026-11-20, lead 1), in bn's rule: the slab's edge over
    // its top's plane and a box whose sides cross the edge (no corner of the slab under
    // its bottom), its bottom within the tolerance over the edge and past it over the
    // top's plane, parallel to it. The two faces share only the two crossings, merged
    // vertices of gap 1.5e-5, and `pave.hingedWithin` held the planes' gap there (2.1e-4
    // for the first) to each vertex's reach (2e-4 and that gap), so the hinge stood and
    // the side was read from the turn between the planes: `edge_coedge_count`, or two
    // solids the other way round. The planes' gap is held to the tolerance alone, as the
    // faces' corners are (`liesIn`). With the bottom at the edge's height the box is
    // joined, and clear of the edge it is apart (`LIP_ON_TOP`)
    for (LIP_HINGE_WINDOW) |case| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("edge {e} over the plane, bottom {e} over the edge, mirrored {}\n", .{ case[0], case[1], mirrored });
        var slab = try lippedSlabAt(case[0], mirrored);
        defer slab.deinit();
        var other = try lipOperand(.{ .on_top = .{ .foot = FOOT_ACROSS, .lift = case[0] + case[1] } }, case[0], mirrored);
        defer other.deinit();
        try expectMeeting(&slab, &other, .refused);
    };
}

/// `body` turned and shifted as `turn` has it (`SLIVER_TURNS`).
fn sliverMoved(body: *const Body, turn: @TypeOf(SLIVER_TURNS[0])) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    return @import("../construct/transform.zig").transform(testing.allocator, body, &sliverMove(turn), .{}, &diag);
}

fn sliverMove(turn: @TypeOf(SLIVER_TURNS[0])) mat.Affine {
    return mat.Affine.translate(turn.shift).compose(&mat.Affine.rotate(vec.normalized(turn.axis).?, turn.angle));
}

test "degeneracy: a box over a slab's top by its lifted edge, clear of the slab, is apart from it however the two are turned" {
    // The edge matrix's find (2026-11-20, bq), as it drew it: the slab's edge 1.8e-4 over
    // its top's plane (a tolerance of 2e-4), the slab's side face through the edge at 42°
    // to the top, so the side runs on past the top's plane for 2.7e-4 from the edge (in
    // its loops, and no boundary of the solid); a box over the top, its bottom edge 3e-4
    // in from the edge and 1.7e-4 over it, 3.5e-4 over the top's plane. The paves find the
    // two apart and one corner of the box classifies its shell: its foot on the side face
    // lay 1.09e-4 along it from the edge, past the zone and so strictly in the face, the
    // ray to it met that face first from behind, and went on between the edge and the
    // top's boundary in its plane, meeting nothing: inside, the union the slab alone and
    // the intersection the whole box. In place another face's foot came first; turned,
    // the side's did. A meeting in an edge's sliver is at the edge (`in_face.inSliver`)
    for (SLIVER_BOXES) |at| for ([_]bool{ false, true }) |mirrored| {
        const x = LIP_TOLERANCE.xsect;
        var slab = try lippedSlabAt(LIP_OVER, mirrored);
        defer slab.deinit();
        var over = try lipOperand(.{ .by_edge = .{ .{ -0.5, at[0] * x, LIP_Z + at[1] * x }, .{ 0.5, at[0] * x + 1, 3 } } }, LIP_OVER, mirrored);
        defer over.deinit();
        for (SLIVER_TURNS, 0..) |turn, k| {
            errdefer std.debug.print("the box {d} tolerances in from the edge and {d} over it, mirrored {}, turn {d}\n", .{ at[0], at[1], mirrored, k });
            var moved_slab = try sliverMoved(&slab, turn);
            defer moved_slab.deinit();
            var moved_box = try sliverMoved(&over, turn);
            defer moved_box.deinit();
            try expectMeeting(&moved_slab, &moved_box, .two_solids);
        }
    };
}

test "degeneracy: points clear of a slab by its lifted edge are inside or outside it as its two faces' planes there have them, and a segment in from each crosses its boundary once, however it is turned" {
    // The cases about the find above, on the queries themselves: points across the edge
    // and over it, three tolerances either way, each farther than the tolerance from both
    // planes and from the edge; the edge over its top's plane (the side face runs past
    // the top's plane, and the top past the side's) and under it (both stop short of each
    // other, and a ray through the gap between the edge and the planes' line met the
    // solid's boundary nowhere: points 2 to 3 tolerances outside were inside, in place
    // too). A segment from each point outside to a point well inside goes in once
    const in_face = @import("../query/in_face.zig");
    const raycast = @import("../query/raycast.zig");
    const x = LIP_TOLERANCE.xsect;
    for ([_]f64{ LIP_OVER, LIP_UNDER }) |lip| for ([_]bool{ false, true }) |mirrored| {
        var slab = try lippedSlabAt(lip, mirrored);
        defer slab.deinit();
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        const frame = lipFrame(mirrored, false);
        const mid = vec.add(frame.origin, .{ 0, 0, LIP_Z });
        // The two faces at the edge, by their planes
        var planes: [2]struct { n: Vec3, at: Vec3 } = undefined;
        var n_planes: usize = 0;
        for (0..slab.faces.items.len) |fi| {
            const f = types.FaceIndex.of(@intCast(fi));
            if (slab.face(f).flags.tombstone or !try in_face.nearEdge(&slab, f, mid, CLOSE, &diag)) continue;
            try testing.expect(n_planes < planes.len);
            planes[n_planes] = .{ .n = in_face.outwardNormal(&slab, f, .{ 0, 0 }), .at = slab.geometry.planes.items[slab.face(f).surface.index].frame.origin };
            n_planes += 1;
        }
        try testing.expectEqual(planes.len, n_planes);
        // 0.01 inside the edge the slab is 0.009 thick under its top
        const within = vec.add(vec.addScaled(mid, frame.inward, 0.01), .{ 0, 0, -lip - 3e-3 });
        for (SLIVER_TURNS, 0..) |turn, k| {
            const move = sliverMove(turn);
            var moved = try sliverMoved(&slab, turn);
            defer moved.deinit();
            var index = try FaceIndex.build(testing.allocator, &moved, &diag);
            defer index.deinit(testing.allocator);
            var iy: i32 = -SLIVER_HALVES;
            while (iy <= SLIVER_HALVES) : (iy += 1) {
                var iz: i32 = -SLIVER_HALVES;
                while (iz <= SLIVER_HALVES) : (iz += 1) {
                    const y = 0.5 * x * @as(f64, @floatFromInt(iy));
                    const z = 0.5 * x * @as(f64, @floatFromInt(iz));
                    if (@sqrt(y * y + z * z) <= x) continue;
                    const p = vec.add(vec.addScaled(mid, frame.inward, y), .{ 0, 0, z });
                    const over = @max(vec.dot(planes[0].n, vec.sub(p, planes[0].at)), vec.dot(planes[1].n, vec.sub(p, planes[1].at)));
                    if (@abs(over) <= x) continue;
                    errdefer std.debug.print("the edge {e} over the top's plane, mirrored {}, turn {d}: {d} tolerances in from the edge and {d} over it\n", .{ lip, mirrored, k, y / x, z / x });
                    const want: point_in_body.Place = if (over > 0) .outside else .inside;
                    try testing.expectEqual(want, try point_in_body.classify(testing.allocator, &moved, &index, move.point(p), .{}, &diag));
                    if (want == .inside) continue;
                    const hits = try raycast.cast(testing.allocator, &moved, &index, move.point(p), move.point(within), .{}, &diag);
                    defer testing.allocator.free(hits);
                    var depth: i32 = 0;
                    for (hits) |hit| depth += hit.crossing;
                    try testing.expectEqual(@as(i32, 1), depth);
                }
            }
        }
    };
}

/// The box of the tests of an edge from a corner off a side (`OFFSIDE_BOX`, less its
/// cavity when `hollow`) joined with the plate through its side, mirrored in y or not: the
/// side's face in the plate's plane, the box's own edges of it 1e-4 off that plane.
fn offsideBox(hollow: bool, mirrored: bool) !Body {
    var outer = try offsidePlaced(OFFSIDE_BOX, OFFSIDE_BOX_NUDGE, mirrored);
    defer outer.deinit();
    var plate = try offsidePlaced(OFFSIDE_PLATE, OFFSIDE_PLATE_NUDGE, mirrored);
    defer plate.deinit();
    if (!hollow) return sound(&plate, &outer, .@"union");
    var cavity = try offsidePlaced(OFFSIDE_CAVITY, OFFSIDE_BOX_NUDGE, mirrored);
    defer cavity.deinit();
    var wall = try sound(&outer, &cavity, .difference);
    defer wall.deinit();
    return sound(&plate, &wall, .@"union");
}

/// A box of those tests between `corners`, moved by `nudge`, mirrored in y or not.
fn offsidePlaced(corners: [2]Vec3, nudge: Vec3, mirrored: bool) !Body {
    if (!mirrored) return fuzzBoxPlaced(OFFSIDE_TOLERANCE, corners[0], corners[1], vec.Z3, 0, null, nudge);
    return fuzzBoxPlaced(OFFSIDE_TOLERANCE, .{ corners[0][0], OFFSIDE_MIRROR_Y - corners[1][1], corners[0][2] }, .{ corners[1][0], OFFSIDE_MIRROR_Y - corners[0][1], corners[1][2] }, vec.Z3, 0, null, .{ nudge[0], -nudge[1], nudge[2] });
}

/// The hull of those tests shifted by `dx` and `dy` (toward the box's inside in y when
/// positive), mirrored in y or not.
fn offsideHull(dx: f64, dy: f64, mirrored: bool) !Body {
    var points = OFFSIDE_HULL;
    if (mirrored) for (&points) |*p| {
        p[1] = OFFSIDE_MIRROR_Y - p[1];
    };
    const y = OFFSIDE_HULL_NUDGE[1] + dy;
    return fuzzHullPlaced(&points, vec.Z3, 0, null, .{ 0, 0, 0 }, .{ OFFSIDE_HULL_NUDGE[0] + dx, if (mirrored) -y else y, OFFSIDE_HULL_NUDGE[2] });
}

/// The hull through the box's side, its corner on the box's top edge: every operation made
/// and sound with the identities at the tolerance, the hull first; the union and the
/// intersection the same solids the other way round, one each (the union with the box's
/// `voids`); and the box less the hull refused by design, the pocket the hull leaves
/// touching the box's edge at the corner alone (`pinched`).
fn expectThroughSide(joined: *const Body, hull: *const Body, voids: usize) !void {
    try helpers.expectIdentitiesAtTolerance(hull, joined);
    for ([2][2]*const Body{ .{ joined, hull }, .{ hull, joined } }) |operands| {
        var both = try sound(operands[0], operands[1], .@"union");
        defer both.deinit();
        try testing.expectEqual([2]usize{ 1, voids }, shellKinds(&both));
        var common = try sound(operands[0], operands[1], .intersection);
        defer common.deinit();
        try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&common));
    }
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, joined, hull, .difference, .{}, &diag, null));
    try testing.expectEqual(diagnostics.Code.pinched, diag.first().?.code);
}

test "degeneracy: a hull's corner within the tolerance of a side's plane and off the side, on the box's edge beside it, its edge crossing the side farther on, is cut by the side there" {
    // The nightly's find (2026-11-20, locus_solids, bp), as it drew it: a box hollowed to
    // a wall 3 tolerances thick, joined with a plate whose side is 1e-4 inside the wall's
    // (one face, in the plate's plane, the wall's edges 1e-4 off it), then a hull whose
    // corner lies on the box's top edge at y = 1: 1.5e-4 from that face's plane (a
    // tolerance of 2e-4), its foot on the footprint of the face's edge at y = 1 and
    // 2.5e-4 from the edge itself, so off the face. Edge–face left the crossing of the
    // hull's edge from that corner to vertex–face, the corner being on the plane, and
    // vertex–face had the corner off the face: the edge crossed the side 3.7e-4 from the
    // corner, 3e-4 inside it, with no vertex there, the hull's section of the side ended
    // inside it, and the side's fragment read both sides of the hull from the spur
    // (`unclassified`). The crossing is the corner's only where the corner is on the face
    var joined = try offsideBox(true, false);
    defer joined.deinit();
    var hull = try offsideHull(0, 0, false);
    defer hull.deinit();
    try expectThroughSide(&joined, &hull, 3);
}

test "degeneracy: a hull's corner on a box's edge, within the tolerance of the plane of the side beside it or clear of it, its foot on the side's edge, outside it or inside it, mirrored or not: cut by the side where the corner is off it, refused where its foot is inside" {
    // The cases about the find above, the box solid: the corner 1.6e-4 to 1.9e-4 from the
    // side's plane and its foot on the footprint of the side's edge or up to 6e-5 outside
    // it (off the side: the edge from it crosses the side farther on, a vertex of its own,
    // each of these `unclassified` before); the corner 2.5e-4 from the plane (the edge
    // crossed the side as any other, then and now); and the foot inside the footprint,
    // the corner inside the side by its distance from the side's edge and on that edge by
    // its foot (`below_feature_size`, the paves' feature-size rule, then and now)
    for ([_]bool{ false, true }) |mirrored| {
        var joined = try offsideBox(false, mirrored);
        defer joined.deinit();
        for (OFFSIDE_NEAR ++ [_]f64{OFFSIDE_CLEAR}) |dx| for (OFFSIDE_OUT) |dy| {
            errdefer std.debug.print("mirrored {}, shifted {e} in x and {e} in y\n", .{ mirrored, dx, dy });
            var hull = try offsideHull(dx, dy, mirrored);
            defer hull.deinit();
            try expectThroughSide(&joined, &hull, 0);
        };
        for (OFFSIDE_NEAR) |dx| for (OFFSIDE_IN) |dy| {
            errdefer std.debug.print("mirrored {}, shifted {e} in x and {e} in y\n", .{ mirrored, dx, dy });
            var hull = try offsideHull(dx, dy, mirrored);
            defer hull.deinit();
            try expectRefused(&joined, &hull, .below_feature_size);
            try expectRefused(&hull, &joined, .below_feature_size);
        };
    }
}

/// Each operation of `a` and `b`, either way round, made and sound, every face of it a
/// part of one face of one operand (operands with no two faces in one plane: the paves
/// find none, so the result's faces share no plane record but as parts of one face); the
/// identities.
fn expectSoundFaceByFace(a: *const Body, b: *const Body) !void {
    for ([2][2]*const Body{ .{ a, b }, .{ b, a } }) |operands| {
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            errdefer std.debug.print("{s}\n", .{@tagName(op)});
            var r = pipeline.Report.init(testing.allocator);
            defer r.deinit();
            var made = try helpers.soundReported(operands[0], operands[1], op, &r);
            defer made.deinit();
            for (r.faces.items, 0..) |x, i| for (r.faces.items[i + 1 ..]) |y| try testing.expect(x.result != y.result);
        }
    }
    try helpers.expectIdentities(a, b);
}

test "degeneracy: a flat tetrahedron cut by a hull to a strip along its upper edge keeps its two upper faces two, each operation sound either way round" {
    // The locus fuzzer's find (2026-11-20, the session on 5c1e164e, br), as it drew it: a
    // tetrahedron two of whose opposite edges are three intersection tolerances apart
    // (6e-5), its two upper faces 1.2e-4 rad apart about the upper edge, its two lower
    // about the lower; a hull's edge 2e-3 over the upper edge, the hull's faces cutting a
    // strip 3e-3 wide of the tetrahedron along it, to the corner at its end. The two upper
    // faces' parts in the strip have their corners 1.6e-7 off each other's planes, and
    // simplify, deciding "one plane" by that, made them one face: it met the lower face
    // along the two edges that end at the corner, 6e-5 from it at the strip's other end,
    // and the intersection and the difference were bodies whose faces intersect. Two faces
    // of one operand are one plane only where the paves found them so (D28)
    var hull = try fuzzHullPlaced(&.{ .{ 1, 4, 1 }, .{ 3, 3, 4 }, .{ 4, 0, 1 }, .{ 1, 4, 1 }, .{ 4, 4, 3 }, .{ 3, 1, 4 } }, vec.Z3, 0, null, .{ 0, 0, 0 }, .{ 0, 0, -5e-6 });
    defer hull.deinit();
    const half = 3.0 * tol.xsect / 2.0;
    var flat = try fuzzHullPlaced(&.{ .{ 1, 1, 4 - half }, .{ 3, 1, 4 - half }, .{ 2, 0, 4 + half }, .{ 2, 2, 4 + half } }, vec.Z3, 0, null, .{ 1, 0, 0 }, .{ 0, 1e-5, -2e-3 });
    defer flat.deinit();
    try expectSoundFaceByFace(&hull, &flat);
    var common = try sound(&hull, &flat, .intersection);
    defer common.deinit();
    try testing.expectEqual(@as(usize, 8), common.counts().faces);
}

test "degeneracy: a flat tetrahedron cut by a hull to a strip along its upper edge, its edges a few tolerances apart, its corner sharp or blunt, the strip narrow or wider, mirrored or not, keeps its faces apart" {
    // The cases about the find above. The face simplify made of the two upper faces met
    // the lower face along two edges from the tetrahedron's corner; the overlap rules saw
    // it where the corner is sharp or a right angle from above (the edges' marks along the
    // two planes' line out of order: `faces_intersect`) and passed it where the corner is
    // blunt, the same two faces on each other. Every case made, each face of a result a
    // part of one face of an operand
    for ([_]bool{ false, true }) |mirrored| {
        var corners = FLAT_HULL;
        if (mirrored) for (&corners) |*p| {
            p[1] = 4 - p[1];
        };
        var hull = try fuzzHullPlaced(&corners, vec.Z3, 0, null, .{ 0, 0, 0 }, .{ 0, 0, -5e-6 });
        defer hull.deinit();
        for (FLAT_SHAPES) |shape| for (FLAT_PLACES) |place| {
            errdefer std.debug.print("mirrored {}, {d} tolerances apart, lower edge {d} either way, {e} under, nudged {e}\n", .{ mirrored, shape[0], shape[1], place[0], place[1] });
            const half = shape[0] * tol.xsect / 2.0;
            var points = [_]Vec3{ .{ 3 - shape[1], 1, 4 - half }, .{ 3 + shape[1], 1, 4 - half }, .{ 3, 0, 4 + half }, .{ 3, 2, 4 + half } };
            if (mirrored) for (&points) |*p| {
                p[1] = 4 - p[1];
            };
            var flat = try fuzzHullPlaced(&points, vec.Z3, 0, null, .{ 0, 0, 0 }, .{ 0, place[1], -place[0] });
            defer flat.deinit();
            try expectSoundFaceByFace(&hull, &flat);
        };
    }
}

/// The two hulls of the tests of an edge along another's (`ALONG_HULL`, `ALONG_OTHER`),
/// placed as the solids fuzzer placed them, the second nudged by `nudge`; mirrored in y
/// or not.
fn alongHulls(nudge: Vec3, mirrored: bool) ![2]Body {
    var first = ALONG_HULL;
    var second = ALONG_OTHER;
    if (mirrored) for ([_][]Vec3{ &first, &second }) |points| for (points) |*p| {
        p[1] = 4 - p[1];
    };
    var a = try fuzzHullPlaced(&first, vec.Z3, 0, null, .{ -1, 0, 0 }, ALONG_NUDGE);
    errdefer a.deinit();
    const quarter: f64 = if (mirrored) -std.math.pi / 2.0 else std.math.pi / 2.0;
    const b = try fuzzHullPlaced(&second, vec.Z3, quarter, null, .{ 0, 0, 0 }, .{ nudge[0], if (mirrored) -nudge[1] else nudge[1], nudge[2] });
    return .{ a, b };
}

/// `op` of `a` and `b` refused with `code`.
fn expectRefusedOf(a: *const Body, b: *const Body, op: pipeline.Op, code: diagnostics.Code) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    if (pipeline.boolean(testing.allocator, a, b, op, .{}, &diag, null)) |result| {
        var made = result;
        made.deinit();
        std.debug.print("{s} was not refused\n", .{@tagName(op)});
        return error.TestExpectedError;
    } else |_| {}
    errdefer std.debug.print("{s}: {f}\n", .{ @tagName(op), diag });
    try testing.expectEqual(code, diag.first().?.code);
}

/// `a` and `b` meet as `want` whichever comes first: an operation made is sound, and a
/// union or an intersection made has the same counts and shells either way round; one
/// refused is refused alike either way round.
fn expectAlong(a: *const Body, b: *const Body, want: Along) !void {
    switch (want) {
        .edge_too_short => for ([2][2]*const Body{ .{ a, b }, .{ b, a } }) |operands| try expectRefused(operands[0], operands[1], .edge_too_short),
        .below_feature_size => for ([2][2]*const Body{ .{ a, b }, .{ b, a } }) |operands| try expectRefused(operands[0], operands[1], .below_feature_size),
        .made, .sliver_in_common, .sliver_in_common_and_rest => {
            for ([_]pipeline.Op{ .@"union", .intersection }) |op| {
                errdefer std.debug.print("{s}\n", .{@tagName(op)});
                if (op == .intersection and want != .made) {
                    try expectRefusedOf(a, b, op, .sliver_face);
                    try expectRefusedOf(b, a, op, .sliver_face);
                    continue;
                }
                var forward = try sound(a, b, op);
                defer forward.deinit();
                var swapped = try sound(b, a, op);
                defer swapped.deinit();
                try testing.expectEqual(forward.counts(), swapped.counts());
                try testing.expectEqual(shellKinds(&forward), shellKinds(&swapped));
            }
            var less = try sound(a, b, .difference);
            less.deinit();
            if (want == .sliver_in_common_and_rest) return expectRefusedOf(b, a, .difference, .sliver_face);
            var rest = try sound(b, a, .difference);
            rest.deinit();
        },
    }
}

test "degeneracy: a hull's edge along another's within the tolerance, their corners two tolerances apart, is intersected the same either way round" {
    // The locus fuzzer's find (2026-11-21, the session on 0856d7ba, bs), as it drew it: an
    // edge of each hull along the other's, 1.67e-5 apart (a tolerance of 2e-5), each
    // ending at a corner, the corners 4.15e-5 apart. The piece between the corners is one
    // edge of the result (a common block), and the intersection keeps both of the first
    // hull's faces about it and, of one of them, the corner the second hull's faces cut
    // off: a face 4e-5 across. On the first hull's line that face is 1.37 times the
    // least area that is no sliver's, on the second's 0.96 of it, and the block took the
    // first operand's line: made with the first hull first, refused (`sliver_face`) with
    // the second. The edge between two faces of one hull is that hull's
    // (`pipeline.Provenance.blockLines`): made either way round, the same
    var hulls = try alongHulls(ALONG_CASES[0].nudge, false);
    defer for (&hulls) |*h| h.deinit();
    try expectAlong(&hulls[0], &hulls[1], .made);
    try helpers.expectIdentitiesAtTolerance(&hulls[0], &hulls[1]);
    try helpers.expectIdentitiesAtTolerance(&hulls[1], &hulls[0]);
}

test "degeneracy: a hull's edge along another's within the tolerance, inside its face or outside it, level with it or to one side, the corners near or nearer, mirrored or not, meets it the same either way round" {
    // The cases about the find above: where the block's two lines differ, the result's
    // faces along it decide whose it keeps, and what follows from the line (a corner of a
    // face a sliver or not) is the same whichever hull comes first. By the first operand's
    // line 6 of the 16 were made one way round and refused the other, mirrored alike
    for ([_]bool{ false, true }) |mirrored| for (ALONG_CASES) |case| {
        errdefer std.debug.print("nudged ({e}, {e}, {e}), mirrored {}\n", .{ case.nudge[0], case.nudge[1], case.nudge[2], mirrored });
        var hulls = try alongHulls(case.nudge, mirrored);
        defer for (&hulls) |*h| h.deinit();
        try expectAlong(&hulls[0], &hulls[1], case.meet);
    };
}

test "degeneracy: a common block between two regions of both operands takes the finer operand's line, either way round" {
    // The nightly's find (2026-11-21, run 44939579466, by), its slab alone: the block's
    // two edges are each along a region of both operands, as many faces of each, and the
    // block took the first operand's line. The intersection's corner triangle was 1.29
    // times the least area that is no sliver's on the box's line and 0.96 of it on the
    // hull's: made with the box first, refused (`sliver_face`) with the hull first. The
    // hull's zone is the finer, its edge stated the more closely: its line either way
    // round, so refused alike; with the zones the other way round, the box's, made alike
    var solids = try tieSolids(TIE_ZONES[0], TIE_DROPS[0], 0, false);
    defer for (&solids) |*x| x.deinit();
    try expectRefusedOf(&solids[0], &solids[1], .intersection, .sliver_face);
    try expectRefusedOf(&solids[1], &solids[0], .intersection, .sliver_face);
    var other = try tieSolids(TIE_ZONES[1], TIE_DROPS[0], 0, false);
    defer for (&other) |*x| x.deinit();
    var forward = try sound(&other[0], &other[1], .intersection);
    defer forward.deinit();
    var swapped = try sound(&other[1], &other[0], .intersection);
    defer swapped.deinit();
    try testing.expectEqual(forward.counts(), swapped.counts());
}

test "degeneracy: a common block between two regions of both operands, the hull's top under the box's by less than the zone or more, at either zone, turned and mirrored, meets alike either way round" {
    // The cases about the find above: whatever the line makes of the corner, a sliver or
    // not, the union and the intersection are made alike or refused alike whichever
    // solid comes first. By the first operand's line 24 of the 64 intersections were made
    // one way round and refused the other
    for (TIE_ZONES) |zones| for (TIE_DROPS) |drop| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("zones {any}, drop {e}, quarter turns {d}, mirrored {}\n", .{ zones, drop, quarter, mirrored });
        var solids = try tieSolids(zones, drop, quarter, mirrored);
        defer for (&solids) |*x| x.deinit();
        for ([_]pipeline.Op{ .@"union", .intersection }) |op| {
            errdefer std.debug.print("{s}\n", .{@tagName(op)});
            try expectAlikeEitherWay(&solids[0], &solids[1], op);
        }
    };
}

test "degeneracy: an edge lying in a face from its boundary to an apex inside it is joined either way round" {
    // The fuzz find (2026-11-22, cg): the tetrahedron's edge, in the plane of the hull's
    // face, lay on it from the hull's edge to the apex 2.83e-5 inside, a spur of the face's
    // fragment run there and back. The tetrahedron's faces along that edge, one above the
    // face's plane and one below it within the tolerance, read the fragment inside along
    // one run and outside along the other, and the union was refused (`unclassified`)
    var solids = try spurSolids(SPUR_INSETS[0], 0, false);
    defer for (&solids) |*x| x.deinit();
    var forward = try sound(&solids[0], &solids[1], .@"union");
    defer forward.deinit();
    var swapped = try sound(&solids[1], &solids[0], .@"union");
    defer swapped.deinit();
    try testing.expectEqual(forward.counts(), swapped.counts());
}

test "degeneracy: an edge lying in a face from its boundary to an apex inside it, the apex near the boundary or farther, turned and mirrored, is decided alike either way round" {
    // The cases about the find above: the apex on the face's edge within the tolerance,
    // and inside the face from the tolerance and D27's band out to 2.5 tolerances. Each
    // union, intersection and difference is decided, never left unclassified by the
    // spur's two runs, and the union and the intersection alike whichever solid comes
    // first. Before, 84 of the 240 were refused `unclassified`; the rest are made, or
    // refused for features nearer than the minimum size or an edge too short
    for (SPUR_INSETS) |inset| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("inset {e}, quarter turns {d}, mirrored {}\n", .{ inset, quarter, mirrored });
        var solids = try spurSolids(inset, quarter, mirrored);
        defer for (&solids) |*x| x.deinit();
        for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
            errdefer std.debug.print("{s}\n", .{@tagName(op)});
            for ([2][2]*const Body{ .{ &solids[0], &solids[1] }, .{ &solids[1], &solids[0] } }) |operands| {
                var diag = Diagnostics.init(testing.allocator);
                defer diag.deinit();
                var result = pipeline.boolean(testing.allocator, operands[0], operands[1], op, .{}, &diag, null) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    try testing.expect(diag.first().?.code != .unclassified);
                    continue;
                };
                result.deinit();
            }
            if (op != .difference) try expectAlikeEitherWay(&solids[0], &solids[1], op);
        }
    };
}

/// The tetrahedron and the hull of those tests, the hull's edge moved back by `inset`,
/// both turned `quarter` quarter turns about z and mirrored as `tieMove` does.
fn spurSolids(inset: f64, quarter: usize, mirrored: bool) ![2]Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const hull = @import("../construct/hull.zig").hull;
    var apex: [SPUR_APEX.len]Vec3 = undefined;
    for (SPUR_APEX, &apex) |p, *q| q.* = tieMove(p, quarter, mirrored);
    var a = try hull(testing.allocator, tol, &apex, &diag);
    errdefer a.deinit();
    var points: [SPUR_HULL.len]Vec3 = undefined;
    for (SPUR_HULL, &points) |p, *q| q.* = tieMove(.{ p[0] - inset + SPUR_HULL_NUDGE[0], p[1] + SPUR_HULL_NUDGE[1], p[2] - inset + SPUR_HULL_NUDGE[2] }, quarter, mirrored);
    const b = try hull(testing.allocator, tol, &points, &diag);
    return .{ a, b };
}

/// The box and the hull of those tests at `zones`, the hull's top `drop` under 4, both
/// turned `quarter` quarter turns about z through the origin and then mirrored in x = 0
/// when `mirrored` (exact: coordinates swapped and negated).
pub fn tieSolids(zones: [2]f64, drop: f64, quarter: usize, mirrored: bool) ![2]Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const corners = [2]Vec3{ tieMove(TIE_BOX[0], quarter, mirrored), tieMove(TIE_BOX[1], quarter, mirrored) };
    var lo: Vec3 = undefined;
    var hi: Vec3 = undefined;
    for (0..3) |k| {
        lo[k] = @min(corners[0][k], corners[1][k]);
        hi[k] = @max(corners[0][k], corners[1][k]);
    }
    var a = try helpers.boxAt(Tolerance.fromZone(zones[0]), lo, hi);
    errdefer a.deinit();
    var points: [TIE_HULL.len]Vec3 = undefined;
    for (TIE_HULL, &points) |p, *q| q.* = tieMove(.{ p[0], p[1], p[2] - drop }, quarter, mirrored);
    const b = try @import("../construct/hull.zig").hull(testing.allocator, Tolerance.fromZone(zones[1]), &points, &diag);
    return .{ a, b };
}

/// Point `p` turned `quarter` quarter turns about z through the origin, then mirrored in
/// x = 0 when `mirrored`.
fn tieMove(p: Vec3, quarter: usize, mirrored: bool) Vec3 {
    var q = p;
    for (0..quarter) |_| {
        const turned_once: Vec3 = .{ -q[1], q[0], q[2] };
        q = turned_once;
    }
    return if (mirrored) .{ -q[0], q[1], q[2] } else q;
}

/// `op` of `a` and `b` and of `b` and `a` alike: both made, sound, with the same counts
/// and shells, or both refused for the same finding.
fn expectAlikeEitherWay(a: *const Body, b: *const Body, op: pipeline.Op) !void {
    var codes: [2]?diagnostics.Code = .{ null, null };
    var made: [2]?Body = .{ null, null };
    defer for (&made) |*m| if (m.*) |*body| body.deinit();
    for ([2][2]*const Body{ .{ a, b }, .{ b, a } }, 0..) |operands, k| {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        if (pipeline.boolean(testing.allocator, operands[0], operands[1], op, .{}, &diag, null)) |result| {
            made[k] = result;
        } else |err| {
            if (err == error.OutOfMemory) return err;
            codes[k] = diag.first().?.code;
        }
    }
    errdefer std.debug.print("refused: {any}\n", .{codes});
    try testing.expectEqual(codes[0], codes[1]);
    if (codes[0] != null) return;
    for (&made) |m| {
        var report = try check.run(testing.allocator, &m.?, .global);
        defer report.deinit(testing.allocator);
        if (report.first()) |f| {
            std.debug.print("the checker: {f}\n", .{f});
            return error.ResultNotValid;
        }
    }
    try testing.expectEqual(made[0].?.counts(), made[1].?.counts());
    try testing.expectEqual(shellKinds(&made[0].?), shellKinds(&made[1].?));
}

/// A box of the tests of a pocket's mouth between `corners`, mirrored in y or not.
fn pocketBox(corners: [2]Vec3, mirrored: bool) !Body {
    if (!mirrored) return helpers.boxAt(tol, corners[0], corners[1]);
    return helpers.boxAt(tol, .{ corners[0][0], POCKET_MIRROR_Y - corners[1][1], corners[0][2] }, .{ corners[1][0], POCKET_MIRROR_Y - corners[0][1], corners[1][2] });
}

/// `points` of those tests, mirrored in y or not.
fn pocketPoints(comptime n: usize, points: [n]Vec3, mirrored: bool) [n]Vec3 {
    var out = points;
    if (mirrored) for (&out) |*p| {
        p[1] = POCKET_MIRROR_Y - p[1];
    };
    return out;
}

/// A move of those tests, mirrored in y or not.
fn pocketMove(by: Vec3, mirrored: bool) Vec3 {
    return if (mirrored) .{ by[0], -by[1], by[2] } else by;
}

/// The solid with a pocket open through a cut face (`POCKET_OUTER`), mirrored in y or not.
fn pocketSolid(mirrored: bool) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var outer = try pocketBox(POCKET_OUTER, mirrored);
    defer outer.deinit();
    var cavity = try pocketBox(POCKET_CAVITY, mirrored);
    defer cavity.deinit();
    var drawn = try sound(&outer, &cavity, .difference);
    defer drawn.deinit();
    // As the fuzzer composes a placement: one rounding of the move and the nudge together
    const place = mat.Affine.translate(pocketMove(POCKET_NUDGE, mirrored)).compose(&mat.Affine.translate(pocketMove(POCKET_MOVE, mirrored)));
    var wall = try @import("../construct/transform.zig").transform(testing.allocator, &drawn, &place, .{}, &diag);
    defer wall.deinit();
    const points = pocketPoints(POCKET_CUTTER.len, POCKET_CUTTER, mirrored);
    var cutter = try fuzzHull(&points, POCKET_CUTTER_MOVE, pocketMove(POCKET_CUTTER_NUDGE, mirrored));
    defer cutter.deinit();
    return sound(&wall, &cutter, .intersection);
}

/// The hull of those tests moved along its face's normal to have the pocket's corner
/// `depth` intersection tolerances behind that face (not moved at the fuzzer's depth),
/// mirrored in y or not.
fn pocketHull(depth: f64, mirrored: bool) !Body {
    const points = pocketPoints(POCKET_HULL.len, POCKET_HULL, mirrored);
    return fuzzHullPlaced(&points, vec.Z3, 0, POCKET_HULL_SCALE, pocketMove(POCKET_HULL_MOVE, mirrored), vec.scale(POCKET_FACE_NORMAL, (depth - POCKET_FOUND_DEPTH) * tol.xsect));
}

/// The pocket's solid and a hull by its mouth's corner meet as `want` has it
/// (`POCKET_CASES`), either way round.
fn expectByPocket(solid: *const Body, hull: *const Body, want: @FieldType(PocketCase, "want")) !void {
    switch (want) {
        .made => {
            try helpers.expectIdentitiesAtTolerance(solid, hull);
            try helpers.expectIdentitiesAtTolerance(hull, solid);
        },
        .below_feature_size, .edge_too_short => {
            const code: diagnostics.Code = if (want == .edge_too_short) .edge_too_short else .below_feature_size;
            try expectRefused(solid, hull, code);
            try expectRefused(hull, solid, code);
        },
        .sliver_tip => {
            for ([2][2]*const Body{ .{ solid, hull }, .{ hull, solid } }) |operands| {
                var joined = try sound(operands[0], operands[1], .@"union");
                defer joined.deinit();
                try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&joined));
                var diag = Diagnostics.init(testing.allocator);
                defer diag.deinit();
                try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, operands[0], operands[1], .intersection, .{}, &diag, null));
                try testing.expectEqual(diagnostics.Code.sliver_face, diag.first().?.code);
            }
            var cut = try sound(solid, hull, .difference);
            defer cut.deinit();
            try testing.expectEqual([2]usize{ 1, 0 }, shellKinds(&cut));
            var diag = Diagnostics.init(testing.allocator);
            defer diag.deinit();
            try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, hull, solid, .difference, .{}, &diag, null));
            try testing.expectEqual(diagnostics.Code.sliver_face, diag.first().?.code);
        },
    }
}

test "degeneracy: a hull's face 1.6 tolerances from a corner of a pocket's mouth, the chord between its crossings of the mouth's two edges over the open mouth, joins the solids either way round" {
    // The locus fuzzer's find (2026-11-21, the session on 0856d7ba, bt), as it drew it: a
    // pocket open through a cut face, its ceiling and its side meeting that face at one
    // corner, a reflex edge between them (the face has a notch there, the mouth), and a
    // hull's face 3.27e-5 from the corner (a tolerance of 2e-5), which cuts the corner's
    // three edges. Its crossings of the mouth's two edges are 6e-5 apart, the chord
    // between them 1.5e-5 from one edge at its middle and over the open mouth: beside the
    // cut face, not in it. The paves made it a section of the two faces as they make a
    // chord across a corner of a face, and the piece of the hull's face in the pocket, a
    // triangle all within the zone of the pocket's faces, was outside by its seams on the
    // ceiling and the side and inside by its seam on the cut face (`unclassified`, every
    // operation). The hull fills the pocket to its face; what the two have in common ends
    // in the corner's tip, a face of it a sliver, refused by design
    var solid = try pocketSolid(false);
    defer solid.deinit();
    var hull = try pocketHull(POCKET_FOUND_DEPTH, false);
    defer hull.deinit();
    try expectByPocket(&solid, &hull, .sliver_tip);
}

test "degeneracy: a hull's face by a corner of a pocket's mouth, from clear of the corner on its far side through it to well past it, mirrored or not, meets the pocket's solid the same either way round" {
    // The cases about the find above (`POCKET_CASES`): the chord between the face's
    // crossings of the mouth's two edges lies within reach of them, over the open mouth,
    // while the corner is 1.5 to 1.8 tolerances behind the face (at 1.5 and at the find's
    // 1.635 every operation was `unclassified`; at 1.8 the chord's middle is past reach of
    // the edges and was left out as outside the cut face); nearer, the corner is within
    // the minimum feature size of the hull's face and refused, or on it; farther, the
    // crossings are clear of the corner
    for ([_]bool{ false, true }) |mirrored| {
        var solid = try pocketSolid(mirrored);
        defer solid.deinit();
        for (POCKET_CASES) |case| {
            errdefer std.debug.print("the corner {d} tolerances behind the face, mirrored {}\n", .{ case.depth, mirrored });
            var hull = try pocketHull(case.depth, mirrored);
            defer hull.deinit();
            try expectByPocket(&solid, &hull, case.want);
        }
    }
}

test "degeneracy: a plate's edge along a hull's sloped face, its height over the face's plane past the intersection tolerance and its ends on the face by their reach, is refused either way round" {
    // The locus fuzzer's find (2026-11-21, bx), as it drew it: a box joined with a plate
    // (zone 1e-4), then with a hull whose sloped face the plate's edge runs along 2.12e-4
    // below, past the intersection tolerance, 2e-4, its ends merged within it. The edge
    // keeps the plate's line (D28) and its gap covers the line's height over the face's
    // plane past the tolerance (`pipeline.coverFaces`), set to that height as the plane
    // measures it; the checker measures it by projecting points of the edge onto the
    // face, 5.5e-16 more, and refused the union (`edge_off_surface`). The edge between
    // its ends is a pave block of the plate's own boundary with its line past the
    // tolerance of the hull's face: the paves refuse it (`runOnPlane`), as they refuse a
    // run of a face's boundary off the other's plane on every path (Leo, 2026-11-24; the
    // union was made only because the block's middle, measured, had left the plate's face)
    try expectSlopeJoined(SLOPE_HULL_NUDGE[2], SLOPE_TURNS[0]);
}

test "degeneracy: a plate's edge along a hull's sloped face, from within the intersection tolerance of its plane to well past it, turned about skew axes, is made within it and refused past it either way round" {
    // The cases about the find above (`SLOPE_LIFTS` × `SLOPE_TURNS`): the edge's height
    // over the face's plane from under the tolerance to 0.62 of the zone past it, the three
    // operands in place and turned. Within the tolerance (`SLOPE_LIFT_WITHIN`) the union is
    // made and sound; past it refused `below_feature_size`, either way round
    for (SLOPE_TURNS) |turn| for (SLOPE_LIFTS) |lift| {
        errdefer std.debug.print("the hull nudged {e} in z, turned {d} about {any}\n", .{ lift, turn.angle, turn.axis });
        try expectSlopeJoined(lift, turn);
    };
}

/// The box and the plate of the tests of an edge along a sloped face joined, then joined
/// with the hull nudged `lift` in z, all three turned as `turn` has it: each union made and
/// sound, the last either way round.
/// The box and the plate of the tests of an edge along a sloped face joined, then joined
/// with the hull nudged `lift` in z and tilted alone by `angle` about `axis` through
/// `SLOPE_EDGE_MIDDLE`: each union made and sound, the last either way round.
fn expectSlopeTilted(lift: f64, axis: Vec3, angle: f64) !void {
    var block = try fuzzBoxPlaced(tol, SLOPE_BOX[0], SLOPE_BOX[1], vec.Z3, 0, null, SLOPE_BOX_MOVE);
    defer block.deinit();
    var plate = try fuzzBoxPlaced(Tolerance.fromZone(1e-4), SLOPE_PLATE[0], SLOPE_PLATE[1], vec.Z3, 0, SLOPE_PLATE_SCALE, SLOPE_PLATE_NUDGE);
    defer plate.deinit();
    var drawn_hull = try fuzzHullPlaced(&SLOPE_HULL, SLOPE_HULL_AXIS, std.math.pi, SLOPE_HULL_SCALE, vec.ZERO3, .{ SLOPE_HULL_NUDGE[0], SLOPE_HULL_NUDGE[1], lift });
    defer drawn_hull.deinit();
    const tilt = mat.Affine.rotateAbout(SLOPE_EDGE_MIDDLE, axis, angle);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var hull = try @import("../construct/transform.zig").transform(testing.allocator, &drawn_hull, &tilt, .{}, &diag);
    defer hull.deinit();
    var joined = try helpers.sound(&block, &plate, .@"union");
    defer joined.deinit();
    try expectSlopeAlike(&joined, &hull);
}

/// The union of `a` and `b` decided alike either way round: made and sound, or refused for
/// the plate's edge off the hull's face past the tolerance (`below_feature_size`).
fn expectSlopeAlike(a: *const Body, b: *const Body) !void {
    const forward = try outcomeOf(a, b, .@"union");
    try testing.expectEqual(forward, try outcomeOf(b, a, .@"union"));
    switch (forward) {
        .made => {
            var all = try helpers.sound(a, b, .@"union");
            defer all.deinit();
        },
        .refused => |code| try testing.expectEqual(diagnostics.Code.below_feature_size, code),
    }
}

fn expectSlopeJoined(lift: f64, turn: @TypeOf(SLIVER_TURNS[0])) !void {
    var operands = try slopeOperands(lift, turn);
    defer for (&operands) |*body| body.deinit();
    if (lift <= SLOPE_LIFT_WITHIN) {
        var all = try helpers.sound(&operands[0], &operands[1], .@"union");
        defer all.deinit();
        var swapped = try helpers.sound(&operands[1], &operands[0], .@"union");
        defer swapped.deinit();
        return;
    }
    const refused: Outcome = .{ .refused = .below_feature_size };
    try testing.expectEqual(refused, try outcomeOf(&operands[0], &operands[1], .@"union"));
    try testing.expectEqual(refused, try outcomeOf(&operands[1], &operands[0], .@"union"));
}

/// Find bx's operands, `lift` the hull's nudge in z (the fuzzer's 5e-5) and all three
/// solids moved by `turn`: the union of the box and the plate, checked (`helpers.sound`),
/// and the hull whose sloped face the plate's edge runs along. The edge matrix's family
/// about bx takes them too.
pub fn slopeOperands(lift: f64, turn: @TypeOf(SLIVER_TURNS[0])) ![2]Body {
    var drawn_block = try fuzzBoxPlaced(tol, SLOPE_BOX[0], SLOPE_BOX[1], vec.Z3, 0, null, SLOPE_BOX_MOVE);
    defer drawn_block.deinit();
    var drawn_plate = try fuzzBoxPlaced(Tolerance.fromZone(1e-4), SLOPE_PLATE[0], SLOPE_PLATE[1], vec.Z3, 0, SLOPE_PLATE_SCALE, SLOPE_PLATE_NUDGE);
    defer drawn_plate.deinit();
    var drawn_hull = try fuzzHullPlaced(&SLOPE_HULL, SLOPE_HULL_AXIS, std.math.pi, SLOPE_HULL_SCALE, vec.ZERO3, .{ SLOPE_HULL_NUDGE[0], SLOPE_HULL_NUDGE[1], lift });
    defer drawn_hull.deinit();
    var block = try sliverMoved(&drawn_block, turn);
    defer block.deinit();
    var plate = try sliverMoved(&drawn_plate, turn);
    defer plate.deinit();
    var joined = try helpers.sound(&block, &plate, .@"union");
    errdefer joined.deinit();
    return .{ joined, try sliverMoved(&drawn_hull, turn) };
}

test "degeneracy: a hull less a box, cut by a plate whose top crosses the hull's face parallel to the box's bottom edge, keeps the same edges moved whole" {
    // The first ReleaseSafe session's find (2026-11-22, cd), as the solids fuzzer drew it.
    // On the hull's face the box's bottom edge and the plate's top run parallel 9e-5 apart,
    // so of the chain's four vertices the two on the box's edge lie exactly as far from
    // the chord between the two on the plate's top. The join split the chain at the one
    // the rounding put farther: in place at the first, every vertex kept, moved whole (a
    // turn of 0.3 about x, a shift 2.3e3 out) at the second, two edges joined into one
    try expectChainMoved(CHAIN_DROPS[0], CHAIN_MOVES[CHAIN_MOVES.len - 1], false);
}

test "degeneracy: a hull less a box, cut by a plate whose top crosses the hull's face parallel to the box's bottom edge, from 1e-5 under it to 1.5e-4, keeps the same edges moved whole and either way round" {
    // The cases about the find above (`CHAIN_DROPS` × `CHAIN_MOVES` × the plate second or
    // first): two lines parallel within the face at every gap within the intersection
    // tolerance, the two vertices on the box's edge tied for the farthest from the chord.
    // Without the tie taken as one, 21 of the 60 differed, one in place the plate first
    for (CHAIN_DROPS) |drop| for (CHAIN_MOVES) |move| for ([_]bool{ false, true }) |plate_first| {
        errdefer std.debug.print("the box nudged {e} in z, turned {d} about {any}, shifted {any}, the plate {s}\n", .{ drop, move.angle, move.axis, move.shift, if (plate_first) "first" else "second" });
        try expectChainMoved(drop, move, plate_first);
    };
}

/// The hull less the box nudged `drop` in z, cut by the plate (second, or first when
/// `plate_first`), the three moved as `move` has it, has the counts it has in place, the
/// plate second.
fn expectChainMoved(drop: f64, move: @TypeOf(CHAIN_MOVES[0]), plate_first: bool) !void {
    var placed = try chainCut(drop, CHAIN_MOVES[0], false);
    defer placed.deinit();
    var moved = try chainCut(drop, move, plate_first);
    defer moved.deinit();
    errdefer std.debug.print("in place {any}, moved {any}\n", .{ placed.counts(), moved.counts() });
    try testing.expectEqual(placed.counts(), moved.counts());
}

/// The chain tests' hull less their box nudged `drop` in z, intersected with their plate
/// (second, or first when `plate_first`), the three moved as `move` has it, each boolean
/// made and sound.
fn chainCut(drop: f64, move: @TypeOf(CHAIN_MOVES[0]), plate_first: bool) !Body {
    var drawn_hull = try fuzzHullPlaced(&CHAIN_HULL, vec.Z3, 0, null, CHAIN_HULL_MOVE, CHAIN_HULL_NUDGE);
    defer drawn_hull.deinit();
    var drawn_box = try fuzzBoxPlaced(tol, CHAIN_BOX[0], CHAIN_BOX[1], vec.Z3, 0, null, .{ CHAIN_BOX_NUDGE[0], CHAIN_BOX_NUDGE[1], drop });
    defer drawn_box.deinit();
    var drawn_plate = try fuzzBoxPlaced(Tolerance.fromZone(1e-4), CHAIN_PLATE[0], CHAIN_PLATE[1], vec.Z3, 0, null, CHAIN_PLATE_NUDGE);
    defer drawn_plate.deinit();
    var hull = try sliverMoved(&drawn_hull, move);
    defer hull.deinit();
    var cutter = try sliverMoved(&drawn_box, move);
    defer cutter.deinit();
    var plate = try sliverMoved(&drawn_plate, move);
    defer plate.deinit();
    var notched = try helpers.sound(&hull, &cutter, .difference);
    defer notched.deinit();
    return if (plate_first) helpers.sound(&plate, &notched, .intersection) else helpers.sound(&notched, &plate, .intersection);
}

test "degeneracy: two faces in one plane a hair apart sharing a region take the plane their own regions move least, whichever operand comes first" {
    // The solids fuzzer's find (2026-11-21, ca): the group's plane was the one moving its
    // kept fragments least, and the region the two faces share was kept as the first
    // operand's copy only, so it moved nothing on the first operand's plane: A ∪ B took
    // A's plane and B ∪ A B's, and the section across the face was one edge one way round
    // and two the other. Counted by both copies, the region weighs alike on either plane,
    // and B's own region, the longer, gives B's plane either way round
    var a = try sharedBox(SHARED_A, 0, false);
    defer a.deinit();
    var b = try sharedBox(.{ .{ SHARED_B_FROM, SHARED_GAPS[2], 0 }, .{ SHARED_B_ENDS[2], SHARED_B_TOP, 1 } }, 0, false);
    defer b.deinit();
    for ([2][2]*const Body{ .{ &a, &b }, .{ &b, &a } }) |operands| {
        var joined = try sound(operands[0], operands[1], .@"union");
        defer joined.deinit();
        try testing.expectEqual(1, facesAt(&joined, .{ 0, -1, 0 }, -SHARED_GAPS[2]));
        try testing.expectEqual(0, facesAt(&joined, .{ 0, -1, 0 }, 0));
    }
}

test "degeneracy: two faces in one plane a hair apart sharing a region, the gap and the regions beside it varied, turned and mirrored, are joined and intersected on the same planes either way round" {
    // The cases about the find above: A's plane, a tie and B's, at three gaps within the
    // tolerance; the union keeps the shared region and both regions beside it, the
    // intersection the shared region alone (a tie, its two copies a gap apart). By the
    // kept copy alone every case took its first operand's plane
    for (SHARED_B_ENDS) |end| for (SHARED_GAPS) |gap| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("B to {d}, gap {e}, quarter turns {d}, mirrored {}\n", .{ end, gap, quarter, mirrored });
        var a = try sharedBox(SHARED_A, quarter, mirrored);
        defer a.deinit();
        var b = try sharedBox(.{ .{ SHARED_B_FROM, gap, 0 }, .{ end, SHARED_B_TOP, 1 } }, quarter, mirrored);
        defer b.deinit();
        for ([_]pipeline.Op{ .@"union", .intersection }) |op| {
            errdefer std.debug.print("{s}\n", .{@tagName(op)});
            var forward = try sound(&a, &b, op);
            defer forward.deinit();
            var swapped = try sound(&b, &a, op);
            defer swapped.deinit();
            try testing.expectEqual(forward.counts(), swapped.counts());
            try expectSamePlanes(&forward, &swapped);
        }
    };
}

/// A box of those tests between `corners`, turned and mirrored as `tieMove` has it.
fn sharedBox(corners: [2]Vec3, quarter: usize, mirrored: bool) !Body {
    const moved = [2]Vec3{ tieMove(corners[0], quarter, mirrored), tieMove(corners[1], quarter, mirrored) };
    var lo: Vec3 = undefined;
    var hi: Vec3 = undefined;
    for (0..3) |k| {
        lo[k] = @min(moved[0][k], moved[1][k]);
        hi[k] = @max(moved[0][k], moved[1][k]);
    }
    return helpers.boxAt(tol, lo, hi);
}

/// How many of `body`'s faces have the outward normal `n` and lie in the plane through
/// the point `at` times `n` (exactly: the plane is one record, copied).
fn facesAt(body: *const Body, n: Vec3, at: f64) usize {
    var count: usize = 0;
    for (0..body.faces.items.len) |i| {
        const f = types.FaceIndex.of(i);
        const plane = body.geometry.planes.items[body.face(f).surface.index];
        const outward = if (body.face(f).same_sense) plane.frame.z else vec.scale(plane.frame.z, -1);
        if (!std.meta.eql(outward, n)) continue;
        if (vec.dot(plane.frame.origin, n) == at) count += 1;
    }
    return count;
}

/// `a` and `b` have the same faces' planes: the outward normal and the offset of each,
/// sorted, exactly (a plane is one operand's record, copied).
fn expectSamePlanes(a: *const Body, b: *const Body) !void {
    var planes: [2][]([4]f64) = undefined;
    for ([2]*const Body{ a, b }, &planes) |body, *list| {
        list.* = try testing.allocator.alloc([4]f64, body.faces.items.len);
        for (list.*, 0..) |*row, i| {
            const f = types.FaceIndex.of(i);
            const plane = body.geometry.planes.items[body.face(f).surface.index];
            const n = if (body.face(f).same_sense) plane.frame.z else vec.scale(plane.frame.z, -1);
            row.* = .{ n[0], n[1], n[2], vec.dot(plane.frame.origin, n) };
        }
        std.mem.sort([4]f64, list.*, {}, struct {
            fn lessThan(_: void, x: [4]f64, y: [4]f64) bool {
                for (x, y) |p, q| if (p != q) return p < q;
                return false;
            }
        }.lessThan);
    }
    defer for (planes) |list| testing.allocator.free(list);
    try testing.expectEqualSlices([4]f64, planes[0], planes[1]);
}

test "degeneracy: two solids of an intersection touching along a thin plate's corner, a face holding it across its plane, pair their faces about it" {
    // The ReleaseSafe session's find on a1444371 (2026-11-21, locus, bz), as the solids
    // fuzzer drew it: (a hull ∪ a plate 5e-5 thick) ∩ a second hull keeps the plate's
    // corner and a wedge of the two hulls, touching along the corner's edge, 5e-5 long.
    // Of its four uses, the second hull's sloped face holds the edge by reach alone, at 24°
    // to its plane: the faces did not pair (`edge_coedge_count`), the rule for a face
    // across its plane taking two uses of one plane only. A face bounded by the edge across
    // its plane is read by its bi-normal about it, as OCCT's GetFaceDir reads every face
    var joined, var hull = try cornerSolids(2.5, CORNER_HULL_B_NUDGE[2], SLIVER_TURNS[0]);
    defer joined.deinit();
    defer hull.deinit();
    var meet = try sound(&joined, &hull, .intersection);
    defer meet.deinit();
    try testing.expectEqual([2]usize{ 2, 0 }, shellKinds(&meet));
    try expectPairedEitherWay(&joined, &hull);
}

test "degeneracy: a thin plate's corner where two solids touch, its edge across a face's plane, is paired however thick, lifted or turned" {
    // Around the find above: the plate 2.1, 2.5 and 3 intersection tolerances thick (the
    // corner's edge 4.2e-5 to 6e-5 long, held by the sloped face's reach, and past it), the
    // second hull's sloped edge crossing it at four heights, the three solids in place
    // and turned about skew axes (one shifted far out); every operation either way round,
    // its faces never left unpaired, what it makes sound, the union and the intersection
    // alike
    for (CORNER_THICKNESSES) |thickness| for (CORNER_LIFTS) |lift| for (SLIVER_TURNS) |turn| {
        errdefer std.debug.print("{d} tolerances thick, lifted {e}, turned {d} about {any}\n", .{ thickness, lift, turn.angle, turn.axis });
        var joined, var hull = try cornerSolids(thickness, lift, turn);
        defer joined.deinit();
        defer hull.deinit();
        try expectPairedEitherWay(&joined, &hull);
    };
}

/// The first hull joined with the plate `thickness` intersection tolerances thick, and the
/// second hull lifted `lift` in z, as the solids fuzzer drew them (`CORNER_*`), each turned
/// as `turn` has it.
fn cornerSolids(thickness: f64, lift: f64, turn: @TypeOf(SLIVER_TURNS[0])) !struct { Body, Body } {
    const half = thickness * tol.xsect / 2;
    var drawn_a = try fuzzHullPlaced(&CORNER_HULL_A, vec.Y3, std.math.pi / 2.0, null, vec.ZERO3, CORNER_HULL_A_NUDGE);
    defer drawn_a.deinit();
    var drawn_plate = try fuzzBoxPlaced(tol, .{ CORNER_PLATE[0][0], CORNER_PLATE[0][1], CORNER_PLATE[0][2] - half }, .{ CORNER_PLATE[1][0], CORNER_PLATE[1][1], CORNER_PLATE[1][2] + half }, vec.Z3, 0, null, CORNER_PLATE_NUDGE);
    defer drawn_plate.deinit();
    var drawn_b = try fuzzHullPlaced(&CORNER_HULL_B, vec.Z3, 0, null, vec.ZERO3, .{ CORNER_HULL_B_NUDGE[0], CORNER_HULL_B_NUDGE[1], lift });
    defer drawn_b.deinit();
    var a = try sliverMoved(&drawn_a, turn);
    defer a.deinit();
    var plate = try sliverMoved(&drawn_plate, turn);
    defer plate.deinit();
    var joined = try sound(&a, &plate, .@"union");
    errdefer joined.deinit();
    return .{ joined, try sliverMoved(&drawn_b, turn) };
}

/// A result made sound as the solids fuzzer's oracle holds it: the checker's every rule,
/// then the overlap rules (a result the boolean made that touches itself was refused only
/// there: find dn, 2026-11-24).
fn expectHeld(result: *const Body) !void {
    var report = try check.run(testing.allocator, result, .global);
    defer report.deinit(testing.allocator);
    if (report.first()) |f| {
        std.debug.print("the checker: {f}\n", .{f});
        return error.ResultNotValid;
    }
    var rules = Diagnostics.init(testing.allocator);
    defer rules.deinit();
    overlap.check(testing.allocator, result, .{}, &rules) catch |err| {
        if (rules.first()) |f| std.debug.print("the overlap rules: {f}\n", .{f});
        return err;
    };
}

/// Each operation of `a` and `b` either way round never leaves an edge's faces unpaired
/// (`NotValid`), and what it makes is sound; the union and the intersection come out alike
/// either way round (`expectAlikeEitherWay`).
fn expectPairedEitherWay(a: *const Body, b: *const Body) !void {
    for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
        errdefer std.debug.print("{t}\n", .{op});
        for ([2][2]*const Body{ .{ a, b }, .{ b, a } }) |operands| {
            var diag = Diagnostics.init(testing.allocator);
            defer diag.deinit();
            var result = pipeline.boolean(testing.allocator, operands[0], operands[1], op, .{}, &diag, null) catch |err| {
                if (err == error.NotValid) std.debug.print("{f}\n", .{diag.first().?});
                if (err == error.NotValid or err == error.OutOfMemory) return err;
                continue;
            };
            defer result.deinit();
            try expectHeld(&result);
        }
        if (op != .difference) try expectAlikeEitherWay(a, b, op);
    }
}

test "degeneracy: an edge two faces hold across their planes, a side's two pieces and a hull face's slit, pairs each plane's uses" {
    // The nightly's find on 1ade5090 (run 44955501203, 2026-11-21, locus_solids, ce), as
    // the solids fuzzer drew it: (a plate ∪ a wall) ∩ a hull. A section line 4.9e-4 long
    // crosses the wall's side y = 1 at 8° to it, the side's pieces either side of it, and
    // lies in a hull's face at 33° to it as a slit, both by reach: four uses, two planes
    // across, and the faces did not pair (`edge_coedge_count`), the rule taking one plane
    // across only. Each plane across the edge pairs its own two uses
    var joined, var hull = try slitSolids(SLIT_DROPS[0], SLIVER_TURNS[0]);
    defer joined.deinit();
    defer hull.deinit();
    try expectPairedEitherWay(&joined, &hull);
}

test "degeneracy: an edge two planes hold across, each its two uses, is paired however far the hull drops or the solids turn" {
    // Around the find above: the hull a quarter of the plate's tolerance higher and lower,
    // the solids in place and turned about skew axes (one shifted far out); every
    // operation either way round, its faces never left unpaired, what it makes sound, the
    // union and the intersection alike
    for (SLIT_DROPS) |drop| for (SLIVER_TURNS) |turn| {
        errdefer std.debug.print("dropped {e}, turned {d} about {any}\n", .{ drop, turn.angle, turn.axis });
        var joined, var hull = try slitSolids(drop, turn);
        defer joined.deinit();
        defer hull.deinit();
        try expectPairedEitherWay(&joined, &hull);
    };
}

/// The plate joined with the wall, and the hull dropped `drop`, as the solids fuzzer drew
/// them (`SLIT_*`), each turned as `turn` has it.
fn slitSolids(drop: f64, turn: @TypeOf(SLIVER_TURNS[0])) !struct { Body, Body } {
    const coarse = Tolerance.fromZone(1e-4);
    var drawn_plate = try fuzzBoxPlaced(coarse, SLIT_PLATE[0], SLIT_PLATE[1], vec.Z3, 0, null, SLIT_PLATE_NUDGE);
    defer drawn_plate.deinit();
    var drawn_wall = try fuzzWallPlaced(coarse, SLIT_WALL_AT, SLIT_WALL[0], SLIT_WALL[1], SLIT_WALL_XSECTS, SLIT_WALL_MOVE, SLIT_WALL_NUDGE);
    defer drawn_wall.deinit();
    var drawn_hull = try fuzzHullPlaced(&SLIT_HULL, vec.Z3, 0, null, SLIT_HULL_MOVE, .{ 0, 0, -drop });
    defer drawn_hull.deinit();
    var plate = try sliverMoved(&drawn_plate, turn);
    defer plate.deinit();
    var wall = try sliverMoved(&drawn_wall, turn);
    defer wall.deinit();
    var joined = try sound(&plate, &wall, .@"union");
    errdefer joined.deinit();
    return .{ joined, try sliverMoved(&drawn_hull, turn) };
}

/// The solids fuzzer's wall `xsects` intersection tolerances thick at the tolerance `t`
/// (`GapShape.wall`): a box less a cavity, the wall's middle plane x = `at[0]`, from `lo`
/// to `hi` in y and z; moved by `move` and by `nudge` in one translation, as the fuzzer
/// places a solid of a tolerance of its own.
fn fuzzWallPlaced(t: Tolerance, at: Vec3, lo: Vec3, hi: Vec3, xsects: f64, move: Vec3, nudge: Vec3) !Body {
    var wall = try fuzzWall(t, at, lo, hi, xsects);
    defer wall.deinit();
    return fuzzPlaced(&wall, vec.Z3, 0, null, move, nudge);
}

/// The solids fuzzer's wall (`GapShape.wall`), unplaced: a box less a cavity, the wall
/// `xsects` intersection tolerances of `t` thick about the plane x = `at[0]`.
fn fuzzWall(t: Tolerance, at: Vec3, lo: Vec3, hi: Vec3, xsects: f64) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const half = xsects * t.xsect / 2;
    var outer = try helpers.boxAt(t, .{ at[0] - FUZZ_WALL_DEPTH - FUZZ_WALL_INSET, lo[1], lo[2] }, .{ at[0] + half, hi[1], hi[2] });
    defer outer.deinit();
    var cavity = try helpers.boxAt(t, .{ at[0] - FUZZ_WALL_DEPTH, lo[1] + FUZZ_WALL_INSET, lo[2] + FUZZ_WALL_INSET }, .{ at[0] - half, hi[1] - FUZZ_WALL_INSET, hi[2] - FUZZ_WALL_INSET });
    defer cavity.deinit();
    return pipeline.boolean(testing.allocator, &outer, &cavity, .difference, .{}, &diag, null);
}

/// The solids fuzzer's plate with a gap (`GapShape.plate`), unplaced: `xsects`
/// intersection tolerances of `t` thick about the plane z = `at[2]`, from `lo` to `hi` in
/// x and y.
fn fuzzGapPlate(t: Tolerance, at: Vec3, lo: Vec3, hi: Vec3, xsects: f64) !Body {
    const half = xsects * t.xsect / 2;
    return helpers.boxAt(t, .{ lo[0], lo[1], at[2] - half }, .{ hi[0], hi[1], at[2] + half });
}

/// `shape` placed as the solids fuzzer places a solid: turned by `turn` about `axis`
/// through its grid middle, scaled by `scale`, moved by `move`, then nudged by `nudge`
/// (one rounding of each, in its order).
fn fuzzPlaced(shape: *const Body, axis: Vec3, turn: f64, scale: ?Vec3, move: Vec3, nudge: Vec3) !Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var place = mat.Affine.translate(vec.ZERO3);
    if (turn != 0) place = mat.Affine.rotateAbout(FUZZ_GRID_MIDDLE, vec.normalized(axis).?, turn).compose(&place);
    if (scale) |by| place = mat.Affine.scaleBy(by).compose(&place);
    place = mat.Affine.translate(move).compose(&place);
    place = mat.Affine.translate(nudge).compose(&place);
    return @import("../construct/transform.zig").transform(testing.allocator, shape, &place, .{}, &diag);
}

test "degeneracy: a plate's edge along a hull's sloped face tilted under it, its height changing along the edge, is decided alike either way round" {
    // The audit of 2026-11-22 drew this to reach a join of pieces of different gaps
    // (simplify.coverEdge after joinRun): the cover gives each piece of the plate's edge
    // the gap of its line's height at its own ends, and a run joined into one edge must
    // give its ends the joined edge's. Here the box's sides leave the pieces' vertices
    // more than two edges, so no run is joined, and the find's operands with the hull
    // tilted alone about x and z through the edge's middle (`SLOPE_TILTS` ×
    // `SLOPE_TILT_AXES` × `SLOPE_TILT_LIFTS`) guard the cover of an edge whose height
    // changes along it; the join itself is pinned by simplify's own tests
    for (SLOPE_TILT_AXES) |axis| for (SLOPE_TILTS) |angle| for (SLOPE_TILT_LIFTS) |lift| {
        errdefer std.debug.print("the hull nudged {e} in z, tilted {e} about {any}\n", .{ lift, angle, axis });
        try expectSlopeTilted(lift, axis, angle);
    };
}

test "degeneracy: a hull's top at the angular tolerance to a plate's, an edge of it within the tolerance under the plate's top, takes the plate's strip beside the edge as under it, either way round" {
    // The bl configuration with the seam a piece of the hull's top edge, not a section of
    // the two tops: the hull turned about y, its top's edge at x = 2.028 from the
    // tolerance under the plate's top (zone 1e-4) to over it, its top rising from the edge
    // over the plate's side at x = 2, the face beyond the edge sloping down into the
    // plate; turned at the angular tolerance (the tops parallel within it, not in one
    // plane) and past it, the hull as drawn and mirrored in y
    var plate = try shallowPlate();
    defer plate.deinit();
    for ([_]f64{ TURN_AT_ANGLE, TURN_PAST_ANGLE }) |turn| for (SHALLOW_LIFTS) |lift| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("turned {d}, lifted {e}, mirrored {}\n", .{ turn, lift, mirrored });
        var points = EDGE_HULL;
        if (mirrored) for (&points) |*p| {
            p[1] = 3 - p[1];
        };
        var hull = try fuzzHullPlaced(&points, vec.Y3, turn, null, .{ 0, 0.5, 0 }, .{ 2e-5, 0, lift });
        defer hull.deinit();
        try expectAllSound(&hull, &plate);
        var forward = try sound(&hull, &plate, .@"union");
        defer forward.deinit();
        var swapped = try sound(&plate, &hull, .@"union");
        defer swapped.deinit();
        try testing.expectEqual(forward.counts(), swapped.counts());
    };
}

/// Every operation of `a` and `b` either way round decided: made and sound (`expectHeld`),
/// or refused for a configuration (never `unclassified` or an edge's faces unpaired, the kernel's own
/// contradictions); the union and the intersection alike either way round.
fn expectDecidedEitherWay(a: *const Body, b: *const Body) !void {
    for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
        errdefer std.debug.print("{t}\n", .{op});
        for ([2][2]*const Body{ .{ a, b }, .{ b, a } }) |operands| {
            var diag = Diagnostics.init(testing.allocator);
            defer diag.deinit();
            var result = pipeline.boolean(testing.allocator, operands[0], operands[1], op, .{}, &diag, null) catch |err| switch (err) {
                error.NotValid, error.IntersectionFailed => {
                    std.debug.print("{f}\n", .{diag.first().?});
                    return err;
                },
                error.OutOfMemory => return err,
                else => continue,
            };
            defer result.deinit();
            try expectHeld(&result);
        }
        if (op != .difference) try expectAlikeEitherWay(a, b, op);
    }
}

/// The solids of the tests of a face a hair off parallel to a box's side: `OFFSET_HULL_B`
/// turned `turn` and its face lifted `lift` out past the box's side (with `OFFSET_HULL_A`
/// joined to it when `joined`), and the box; both moved by `move`.
fn offsetSolids(lift: f64, turn: f64, joined: bool, move: @TypeOf(SLIVER_TURNS[0])) ![2]Body {
    var b_hull = try fuzzHullPlaced(&OFFSET_HULL_B, OFFSET_AXIS, turn, null, OFFSET_HULL_B_MOVE, .{ 0, lift, OFFSET_HULL_B_DROP });
    defer b_hull.deinit();
    var drawn = if (joined) blk: {
        var a_hull = try fuzzHullPlaced(&OFFSET_HULL_A, vec.Z3, 0, OFFSET_HULL_A_SCALE, OFFSET_HULL_A_MOVE, OFFSET_HULL_A_NUDGE);
        defer a_hull.deinit();
        break :blk try helpers.sound(&a_hull, &b_hull, .@"union");
    } else try b_hull.clone(testing.allocator);
    defer drawn.deinit();
    var box_drawn = try fuzzBoxPlaced(tol, OFFSET_BOX[0], OFFSET_BOX[1], vec.Z3, 0, null, OFFSET_BOX_NUDGE);
    defer box_drawn.deinit();
    var hull = try sliverMoved(&drawn, move);
    errdefer hull.deinit();
    return .{ hull, try sliverMoved(&box_drawn, move) };
}

/// The solids of the tests of a hull's fin cut a hair under its tip: (`FIN_HULL_A` ∪
/// `FIN_HULL_B`) less `FIN_HULL_C`, and `FIN_HULL_D` nudged `drop` more in z; both moved
/// by `move`.
fn finSolids(drop: f64, move: @TypeOf(SLIVER_TURNS[0])) ![2]Body {
    var a = try fuzzHullPlaced(&FIN_HULL_A, vec.Z3, 0, null, vec.ZERO3, FIN_HULL_A_NUDGE);
    defer a.deinit();
    var b = try fuzzHullPlaced(&FIN_HULL_B, vec.Z3, 0, FIN_HULL_B_SCALE, FIN_HULL_B_MOVE, FIN_HULL_B_NUDGE);
    defer b.deinit();
    var c = try fuzzHullPlaced(&FIN_HULL_C, vec.Y3, std.math.pi, null, FIN_HULL_C_MOVE, FIN_HULL_C_NUDGE);
    defer c.deinit();
    var joined = try helpers.sound(&a, &b, .@"union");
    defer joined.deinit();
    var finned = try helpers.sound(&joined, &c, .difference);
    defer finned.deinit();
    var d = try fuzzHullPlaced(&FIN_HULL_D, vec.Z3, 0, null, vec.ZERO3, vec.add(FIN_NUDGE, .{ 0, 0, drop }));
    defer d.deinit();
    var fin = try sliverMoved(&finned, move);
    errdefer fin.deinit();
    return .{ fin, try sliverMoved(&d, move) };
}

test "degeneracy: a face a hair off parallel to a box's side, the tolerance outside it, is decided outside, not by its turn" {
    // The first ReleaseSafe session's find on a1444371 (2026-11-21, locus, ci), as the
    // solids fuzzer drew it: two hulls joined, the second turned 1e-9 rad, its face in
    // y = 4 nudged 2e-5 out, then intersected with a box whose side is y = 4. The face lay
    // 1.99987e-5 to 2.00021e-5 outside the side, hinged along its edge where that lay
    // within the tolerance; read by the turn, toward the box but meeting its plane 2e4
    // away, its fragment was inside, though every corner of it was outside, and its seams
    // disagreed with its own operand's beyond the box (`unclassified`). Its corners decide
    var hull, var box_body = try offsetSolids(OFFSET_LIFTS[0], OFFSET_TURNS[0], true, SLIVER_TURNS[0]);
    defer hull.deinit();
    defer box_body.deinit();
    try expectDecidedEitherWay(&hull, &box_body);
}

test "degeneracy: a face a hair off parallel to a box's side about the tolerance outside it is decided, however turned or moved" {
    // Around the find above: the face's turn either way and a hundred times larger, its
    // lift the find's, the tolerance and a hair either way of it, the hull alone or joined
    // with the first, the solids in place and turned about skew axes (one shifted far
    // out); every operation either way round decided, what it makes sound, the union and
    // the intersection alike. 60 of the 160 were unclassified by the turn
    for (OFFSET_LIFTS) |lift| for (OFFSET_TURNS) |turn| for ([_]bool{ false, true }) |joined| for (SLIVER_TURNS) |move| {
        errdefer std.debug.print("lifted {e}, turned {e}, joined {}, moved {any}\n", .{ lift, turn, joined, move });
        var hull, var box_body = try offsetSolids(lift, turn, joined, move);
        defer hull.deinit();
        defer box_body.deinit();
        try expectDecidedEitherWay(&hull, &box_body);
    };
}

test "degeneracy: a hull's fin cut a hair under its tip, its two faces one region over the cut, is refused, not left unpaired" {
    // The ReleaseSafe fuzz on 25411cf5 (2026-11-22, locus, cl), as the solids fuzzer drew
    // it: ((a hull ∪ a hull) less a hull turned a half turn) with a hull whose top lies
    // 8.2e-5 under the tip of a fin of the first. The fin's two faces meet the top along
    // one section, within the tolerance of each other, so over the top they are two
    // fragments of one triangle facing apart, wholly within reach of their faces'
    // boundaries; the union kept both, a fin of no volume, and its edges did not pair
    // (`edge_coedge_count`). Over the same pieces, they are one region of the operand,
    // refused as a feature below the tolerance either way round; the intersection drops
    // them and is made
    var fin, var hull = try finSolids(FIN_DROPS[0], SLIVER_TURNS[0]);
    defer fin.deinit();
    defer hull.deinit();
    for ([2][2]*const Body{ .{ &fin, &hull }, .{ &hull, &fin } }) |operands| {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        try testing.expectError(error.Degenerate, pipeline.boolean(testing.allocator, operands[0], operands[1], .@"union", .{}, &diag, null));
        try testing.expectEqual(diagnostics.Code.below_feature_size, diag.first().?.code);
    }
    try expectDecidedEitherWay(&fin, &hull);
}

test "degeneracy: a hull's fin cut about a hair under its tip is decided, however moved" {
    // Around the find above: the cutting hull a quarter of the tolerance higher and lower
    // and the find's, the solids in place and turned about skew axes (one shifted far
    // out); every operation either way round decided, what it makes sound, the union and
    // the intersection alike. 20 of the 25 left the fin's edges unpaired
    for (FIN_DROPS) |drop| for (SLIVER_TURNS) |move| {
        errdefer std.debug.print("dropped {e}, moved {any}\n", .{ drop, move });
        var fin, var hull = try finSolids(drop, move);
        defer fin.deinit();
        defer hull.deinit();
        try expectDecidedEitherWay(&fin, &hull);
    };
}

test "degeneracy: a solid touching a face along a line through a pocket's mouth, the face's loop bridged to the mouth, is made, sound and meshed either way round" {
    // The locus target's ReleaseSafe find of 2026-11-22 (cp): a hull's edge lay in a
    // plate's side, from beyond its top through a corner of a pocket's mouth and on into
    // the side; the union's face ran its loop along the edge to the mouth's corner, round
    // the mouth, out to the edge's end and back (a bridge and a spur), which the checker
    // takes, and the overlap rules and the mesher, which took out spurs alone, handed the
    // triangulator a bridge's two passages along one segment, refused as not simple
    // (`triangulate.splitSlits` takes out any step run both ways)
    for (KEYHOLE_EDGES, 0..) |edge, e| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("edge {d}, {d} quarter turns, mirrored {}\n", .{ e, quarter, mirrored });
        try expectKeyholeSound(edge, quarter, mirrored);
    };
}

/// The plate less the pocket and the solid touching its side along `edge`, turned and
/// mirrored (`tieMove`): their union either way round and the plate less the solid made,
/// sound (the checker and the overlap rules), and meshed with every face meshed.
fn expectKeyholeSound(edge: [2]Vec3, quarter: usize, mirrored: bool) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var plate = try movedBox(KEYHOLE_PLATE, quarter, mirrored);
    defer plate.deinit();
    var pocket = try movedBox(KEYHOLE_POCKET, quarter, mirrored);
    defer pocket.deinit();
    var pocketed = try helpers.sound(&plate, &pocket, .difference);
    defer pocketed.deinit();
    const middle = vec.scale(vec.add(edge[0], edge[1]), 0.5);
    const corners = [4]Vec3{
        edge[0],
        edge[1],
        .{ middle[0] + KEYHOLE_STANDOFF, middle[1] + KEYHOLE_SPREAD, middle[2] },
        .{ middle[0] + KEYHOLE_STANDOFF, middle[1] - KEYHOLE_SPREAD, middle[2] },
    };
    var points: [4]Vec3 = undefined;
    for (corners, &points) |p, *q| q.* = tieMove(p, quarter, mirrored);
    var touching = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    defer touching.deinit();
    for ([_][2]*const Body{ .{ &pocketed, &touching }, .{ &touching, &pocketed } }) |operands| {
        var joined = try helpers.sound(operands[0], operands[1], .@"union");
        defer joined.deinit();
        try expectMeshedWhole(&joined);
    }
    var less = try helpers.sound(&pocketed, &touching, .difference);
    defer less.deinit();
    try expectMeshedWhole(&less);
}

/// The box between `corners` turned and mirrored (`tieMove`).
fn movedBox(corners: [2]Vec3, quarter: usize, mirrored: bool) !Body {
    const moved = [2]Vec3{ tieMove(corners[0], quarter, mirrored), tieMove(corners[1], quarter, mirrored) };
    var lo: Vec3 = undefined;
    var hi: Vec3 = undefined;
    for (0..3) |k| {
        lo[k] = @min(moved[0][k], moved[1][k]);
        hi[k] = @max(moved[0][k], moved[1][k]);
    }
    return helpers.boxAt(tol, lo, hi);
}

/// `body`'s mesh with every face meshed, none refused or pruned.
fn expectMeshedWhole(body: *const Body) !void {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var mesh = try @import("../mesh/tessellate.zig").tessellate(testing.allocator, body, .{}, .{}, &diag);
    defer mesh.deinit(testing.allocator);
    for (mesh.faces, 0..) |range, f| {
        errdefer std.debug.print("face {d}: {s}\n", .{ f, @tagName(range.status) });
        try testing.expectEqual(@import("../mesh/tessellate.zig").Status.ok, range.status);
    }
}
/// The slab and the box of the common-block tests, the box's side `side` inside the slab's
/// and its top `top` under it, both turned and mirrored (`tieMove`).
fn cornerBoxes(side: f64, top: f64, quarter: usize, mirrored: bool) ![2]Body {
    const box_hi: Vec3 = .{ CORNER_SLAB[1][0] - side, CORNER_BOX[1][1], CORNER_SLAB[1][2] - top };
    return .{ try sharedBox(CORNER_SLAB, quarter, mirrored), try sharedBox(.{ CORNER_BOX[0], box_hi }, quarter, mirrored) };
}

/// The longest edges' lines of the common-block tests: each edge longer than
/// `CORNER_LONG`, its line's origin and direction (the direction's first non-zero
/// coordinate positive), sorted. A line is one operand's record, copied, so two results
/// whose edges took the same records give the same rows exactly.
fn longLines(body: *const Body) ![][6]f64 {
    var rows: std.ArrayList([6]f64) = .empty;
    errdefer rows.deinit(testing.allocator);
    for (body.edges.items) |e| {
        if (e.t1 - e.t0 <= CORNER_LONG) continue;
        const line = body.geometry.curve(e.curve).line;
        var d = line.d;
        const first = if (d[0] != 0) d[0] else if (d[1] != 0) d[1] else d[2];
        if (first < 0) d = vec.scale(d, -1);
        try rows.append(testing.allocator, .{ line.o[0], line.o[1], line.o[2], d[0], d[1], d[2] });
    }
    std.mem.sort([6]f64, rows.items, {}, struct {
        fn lessThan(_: void, x: [6]f64, y: [6]f64) bool {
            for (x, y) |p, q| if (p != q) return p < q;
            return false;
        }
    }.lessThan);
    return rows.toOwnedSlice(testing.allocator);
}

/// `op` of `a` and `b` and of `b` and `a` alike (`expectAlikeEitherWay`) and, made, with the
/// same planes and the same lines for their long edges: an edge between two faces takes the
/// line their planes meet in either way round. (The merged vertices may still differ by the
/// operands' order, a corner the first operand's point, within the tolerance.)
fn expectSameLines(a: *const Body, b: *const Body, op: pipeline.Op) !void {
    try expectAlikeEitherWay(a, b, op);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var forward = pipeline.boolean(testing.allocator, a, b, op, .{}, &diag, null) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer forward.deinit();
    var swapped = try pipeline.boolean(testing.allocator, b, a, op, .{}, &diag, null);
    defer swapped.deinit();
    try expectSamePlanes(&forward, &swapped);
    const lines = [2][][6]f64{ try longLines(&forward), try longLines(&swapped) };
    defer for (lines) |list| testing.allocator.free(list);
    try testing.expectEqualSlices([6]f64, lines[0], lines[1]);
}

test "degeneracy: a slab's corner edge in one plane with a box's along both its faces takes the line those faces' planes meet in, whichever operand comes first" {
    // The ReleaseSafe find cq (2026-11-22): a slab's top and side each one plane with a
    // box's, both at zone 1e-5. The edge where they meet is a block of an edge of each
    // with a region of both on either side, a tie the operands' order broke: both faces
    // took the box's planes either way round (D28's tie rule) and the edge the slab's line
    // one way round, 1e-5 off them along its length 1, so the intersection's area differed
    // by 1.5e-5 between the orders. The line follows the planes its faces took
    var solids = try cornerBoxes(1e-5, 5e-6, 0, false);
    defer for (&solids) |*body| body.deinit();
    try expectSameLines(&solids[0], &solids[1], .intersection);
}

test "degeneracy: a slab's corner edge tied between two operands follows its faces' planes at every offset, turned and mirrored" {
    for (CORNER_SIDES) |side| for (CORNER_TOPS) |top| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("side {e}, top {e}, quarter turns {d}, mirrored {}\n", .{ side, top, quarter, mirrored });
        var solids = try cornerBoxes(side, top, quarter, mirrored);
        defer for (&solids) |*body| body.deinit();
        for ([_]pipeline.Op{ .intersection, .@"union" }) |op| {
            errdefer std.debug.print("{s}\n", .{@tagName(op)});
            try expectSameLines(&solids[0], &solids[1], op);
        }
    };
}

/// The hulls of the gap tests, the first nudged `nudge_x` in x and down `drop`, placed as
/// the fuzzer places them (the turn, the move and the nudge one affine map).
fn gapHulls(nudge_x: f64, drop: f64) ![2]Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const hull = @import("../construct/hull.zig").hull;
    const transform_fn = @import("../construct/transform.zig").transform;
    var first = try hull(testing.allocator, tol, &GAP_FIRST, &diag);
    defer first.deinit();
    const half_turn = mat.Affine.rotateAbout(GAP_MIDDLE, vec.X3, std.math.pi);
    const first_place = mat.Affine.translate(.{ nudge_x, 0, -drop }).compose(&mat.Affine.translate(GAP_FIRST_MOVE).compose(&half_turn));
    var a = try transform_fn(testing.allocator, &first, &first_place, .{}, &diag);
    errdefer a.deinit();
    var second = try hull(testing.allocator, tol, &GAP_SECOND, &diag);
    defer second.deinit();
    const second_place = mat.Affine.translate(GAP_SECOND_NUDGE).compose(&mat.Affine.translate(GAP_SECOND_MOVE));
    return .{ a, try transform_fn(testing.allocator, &second, &second_place, .{}, &diag) };
}

test "degeneracy: two pieces in a face's plane the intersection tolerance and a hair apart are measured alike whichever operand comes first" {
    // The ReleaseSafe find co (2026-11-22): a block of one hull's face and a section of the
    // other lay 2e-5 and a hair apart in that face's plane, and the gap was measured from
    // the pieces' ends in the order the operands gave them: 2.0000000056848476e-5 one way
    // round, 2.0000000056756098e-5 the other, either side of D27's band, so the
    // intersection was made one way round and refused `at_tolerance` the other. A point's
    // distance to a segment is measured from the segment's lesser end
    for (GAP_NUDGES_X) |nudge_x| for (GAP_DROPS) |drop| {
        errdefer std.debug.print("nudged {e} in x, down {e}\n", .{ nudge_x, drop });
        var hulls = try gapHulls(nudge_x, drop);
        defer for (&hulls) |*body| body.deinit();
        for ([_]pipeline.Op{ .intersection, .@"union" }) |op| {
            errdefer std.debug.print("{s}\n", .{@tagName(op)});
            try expectAlikeEitherWay(&hulls[0], &hulls[1], op);
        }
    };
}

/// The outcome of `op` on `a` and `b`: the counts made or the code refused.
const Outcome = union(enum) { made: Body.Counts, refused: diagnostics.Code };

fn outcomeOf(a: *const Body, b: *const Body, op: pipeline.Op) !Outcome {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var result = pipeline.boolean(testing.allocator, a, b, op, .{}, &diag, null) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{ .refused = diag.first().?.code };
    };
    defer result.deinit();
    return .{ .made = result.counts() };
}

test "degeneracy: a tetrahedron's apex beside a hull's edge, its edges crossing that edge, is decided alike mirrored" {
    // cg's family (2026-11-22, cj): the apex 2.5e-5 from the hull's edge, one of its edges
    // crossing it exactly and two passing it 6.9e-6 and 1.6e-5 away. The edges' crossings
    // were taken in the numbering's order; mirrored, the hull's edges numbered otherwise,
    // the two near misses came first, made two vertices 2.24e-5 apart, and the union was
    // refused `below_feature_size`, where unmirrored the exact crossing came first, the
    // others shared its vertex, and it was made. Nearest first, made both ways
    var plain = try spurSolids(2.5e-5, 0, false);
    defer for (&plain) |*body| body.deinit();
    var mirrored = try spurSolids(2.5e-5, 0, true);
    defer for (&mirrored) |*body| body.deinit();
    const expected = try outcomeOf(&plain[0], &plain[1], .@"union");
    try testing.expect(expected == .made);
    try testing.expectEqual(expected, try outcomeOf(&mirrored[0], &mirrored[1], .@"union"));
}

test "degeneracy: crossings beside a corner are decided alike in every quarter turn and mirror, union and intersection either way round" {
    for (SPUR_INSETS) |inset| for ([_]pipeline.Op{ .@"union", .intersection, .difference }) |op| {
        var outcome: ?Outcome = null;
        for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
            errdefer std.debug.print("inset {e}, {t}, quarter turns {d}, mirrored {}\n", .{ inset, op, quarter, mirrored });
            var solids = try spurSolids(inset, quarter, mirrored);
            defer for (&solids) |*body| body.deinit();
            // Either way round for the two operations that are the same so
            if (op != .difference) try expectAlikeEitherWay(&solids[0], &solids[1], op);
            const this = try outcomeOf(&solids[0], &solids[1], op);
            if (outcome) |first| try testing.expectEqual(first, this) else outcome = this;
        };
    };
}

/// The hull and the box of the ridge tests: the hull turned `turn` about `PEAK_TURN_AXIS`,
/// then moved `past` along x and `rise` along z, and the box; both moved whole by `move`.
fn peakSolids(rise: f64, past: f64, turn: f64, move: @TypeOf(SLIVER_TURNS[0])) ![2]Body {
    var drawn_hull = try fuzzHullPlaced(&PEAK_HULL, PEAK_TURN_AXIS, turn, null, vec.ZERO3, .{ past, 0, rise });
    defer drawn_hull.deinit();
    var drawn_box = try helpers.boxAt(tol, PEAK_BOX[0], PEAK_BOX[1]);
    defer drawn_box.deinit();
    var hull = try sliverMoved(&drawn_hull, move);
    errdefer hull.deinit();
    return .{ hull, try sliverMoved(&drawn_box, move) };
}

test "degeneracy: a hull's ridge a hair over a box's bottom, its end on the box's side, keeps none of its faces over the bottom in the union, either way round" {
    // The locus_solids ReleaseSafe find (2026-11-22, cv), as the fuzzer drew it: the hull's
    // ridge 4e-5 over the box's bottom, its end and the edge down from it on the box's side
    // by the paves (2e-5 past it, the tolerance less its turn's 3e-10). Of the hull's faces
    // over the bottom, inside the box, one is a triangle at the box's corner within the
    // tolerance of its bottom and side all over; its seams there read it inside, but neither
    // clearly (within reach of the box's bottom edge), and its ray took a sample past the
    // zone outside the side, where the paves had its corner on it: kept, it left an edge
    // of the union with three faces (`edge_coedge_count`)
    var hull = try fuzzHullPlaced(&PEAK_HULL, .{ 1, 2, 3 }, 1e-9, null, vec.ZERO3, .{ 2.000000005684342e-5, -1.9999999943156583e-5, 1.9999999943156583e-5 });
    defer hull.deinit();
    var over = try fuzzBoxPlaced(tol, PEAK_BOX[0], PEAK_BOX[1], vec.Z3, 0, null, .{ 0, 0, -2e-5 });
    defer over.deinit();
    try expectDecidedEitherWay(&hull, &over);
}

test "degeneracy: a hull's ridge a hair over a box's bottom, its end within the tolerance of the box's side, is decided alike either way round and moved whole" {
    // The family of find cv: the hull turned `PEAK_TURNS`, its ridge `PEAK_RISES` over
    // the box's bottom and its end `PEAK_PASTS` past the box's side, in place and moved
    // whole (`SLIVER_TURNS`): every operation in either order decided (made and sound, or
    // refused for its own reason), union and intersection alike either way round
    for (PEAK_TURNS) |turn| for (PEAK_PASTS) |past| for (PEAK_RISES) |rise| for (SLIVER_TURNS) |move| {
        errdefer std.debug.print("turn {e}, past {e}, rise {e}, moved {any}\n", .{ turn, past, rise, move });
        var solids = try peakSolids(rise, past, turn, move);
        defer for (&solids) |*b| b.deinit();
        try expectDecidedEitherWay(&solids[0], &solids[1]);
    };
}

test "degeneracy: a common block tied between operands of one zone, its faces' planes one exactly, takes the line those planes hold whichever operand comes first" {
    // The edge matrix's family of find by (2026-11-22): with the box and the hull at one
    // zone, their sides y = 3 are one plane exactly and tie in the plane choice to its
    // last step, the first operand's record, while the tops take the hull's plane both
    // ways round. The tied block's line went by which operand's record each face took:
    // the box's line one way round (1e-4 off the top's plane, made) and the hull's the
    // other (a corner a sliver, refused). It goes by which operand's line lies in the
    // planes the faces took, the hull's both ways round
    for (TIE_EQUAL_RISES) |rise| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("the tops {d} tolerances apart, {d} quarter turns, mirrored {}\n", .{ rise, quarter, mirrored });
        var solids = try tieSolids(.{ TIE_EQUAL_ZONE, TIE_EQUAL_ZONE }, TIE_EQUAL_UNDER + rise * Tolerance.fromZone(TIE_EQUAL_ZONE).xsect, quarter, mirrored);
        defer for (&solids) |*body| body.deinit();
        for ([_]pipeline.Op{ .intersection, .@"union" }) |op| {
            errdefer std.debug.print("{s}\n", .{@tagName(op)});
            try expectAlikeEitherWay(&solids[0], &solids[1], op);
        }
    };
}

/// The plate and the hull of those tests, `thickness` intersection tolerances thick and
/// moved `shift` in y, both turned `quarter` quarter turns about z and mirrored as
/// `tieMove` does.
fn endSolids(thickness: f64, shift: f64, quarter: usize, mirrored: bool) ![2]Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const top = END_PLATE_LO[2] + thickness * tol.xsect;
    const corners = [2]Vec3{ tieMove(END_PLATE_LO, quarter, mirrored), tieMove(.{ END_PLATE_HI_XY[0], END_PLATE_HI_XY[1], top }, quarter, mirrored) };
    var lo: Vec3 = undefined;
    var hi: Vec3 = undefined;
    for (0..3) |k| {
        lo[k] = @min(corners[0][k], corners[1][k]);
        hi[k] = @max(corners[0][k], corners[1][k]);
    }
    var plate = try helpers.boxAt(tol, lo, hi);
    errdefer plate.deinit();
    var points: [END_HULL.len]Vec3 = undefined;
    for (END_HULL, &points) |p, *q| q.* = tieMove(.{ p[0], p[1] + shift, p[2] }, quarter, mirrored);
    const hull = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    return .{ plate, hull };
}

test "degeneracy: a hull's edge across a plate's end, its face leaving the end toward the plate's inside, is decided either way round" {
    // The ReleaseSafe session's find on ff515852 (df): the hull's edge lay on the plate's
    // end over the plate's thickness (3 tolerances), and its face along the edge left the
    // end 17.5° off it toward the plate's inside, 1.8e-5 behind the end at most before it
    // ran out under the plate. The piece's middle was clear of the end's boundary, and the
    // face read inside the plate behind it though every point of it lay outside: its seams
    // disagreed with the hull's other faces' (`unclassified`). The side is read where the
    // face has left the piece past the tolerance while over the end
    var solids = try endSolids(3, 2e-3, 0, false);
    defer for (&solids) |*body| body.deinit();
    try expectDecidedEitherWay(&solids[0], &solids[1]);
}

test "degeneracy: hulls' edges across plates' ends of several thicknesses, turned and mirrored, are decided either way round" {
    for (END_THICKNESSES) |thickness| for (END_SHIFTS) |shift| for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
        errdefer std.debug.print("{d} tolerances thick, the edge {e} past y = 2, {d} quarter turns, mirrored {}\n", .{ thickness, shift, quarter, mirrored });
        var solids = try endSolids(thickness, shift, quarter, mirrored);
        defer for (&solids) |*body| body.deinit();
        try expectDecidedEitherWay(&solids[0], &solids[1]);
    };
}

test "degeneracy: two faces taken for one plane whose boundaries pass each other beyond the tolerance are refused alike either way round" {
    // The ReleaseSafe session's find on ff515852 (dd), as the fuzzer drew it: a hull's face
    // in y = 2 and a wall's face beside its gap 1.8e-5 to 2.0e-5 off it, turned 1e-6, taken
    // for one plane; the wall's edge from its corner inside the hull's face, 1.97e-5 off it,
    // passes the hull's edge 2.0e-5 from it, beyond the tolerance, where the paves found no
    // vertex. The hull's imprint of the wall ran to that corner, a spur, and the wall's of
    // the hull another, and the two imprints disagreed (`imprint_unmatched`). The block
    // leaving the face with no vertex where it crosses its boundary is refused where it
    // meets that boundary in the plane (`pave.passesOut`, `apartInPlane`), and every
    // neighbour of the find is decided: the wall turned a tenth and three times as much, its
    // face a tenth of the tolerance nearer and farther, moved whole
    for (CROSS_WALL_TURNS) |turn| for (CROSS_WALL_LIFTS) |lift| for (SLIVER_TURNS[0..2]) |move| {
        errdefer std.debug.print("turned {e}, lifted {e}, moved {any}\n", .{ turn, lift, move });
        var hull_drawn = try fuzzHullPlaced(&CROSS_HULL, vec.Z3, 0, null, vec.ZERO3, CROSS_HULL_NUDGE);
        defer hull_drawn.deinit();
        var wall_shape = try fuzzWall(tol, CROSS_WALL_AT, CROSS_WALL_LO, CROSS_WALL_HI, CROSS_WALL_XSECTS);
        defer wall_shape.deinit();
        var wall_drawn = try fuzzPlaced(&wall_shape, CROSS_WALL_AXIS, turn, null, vec.ZERO3, .{ CROSS_WALL_NUDGE_X, lift, CROSS_WALL_NUDGE_Z });
        defer wall_drawn.deinit();
        var hull = try sliverMoved(&hull_drawn, move);
        defer hull.deinit();
        var wall = try sliverMoved(&wall_drawn, move);
        defer wall.deinit();
        try expectDecidedEitherWay(&hull, &wall);
    };
}

test "degeneracy: a section piece running across the line its faces meet along shows no side, the chain decided moved whole" {
    // The nightly's find on ff515852 (cz), as the fuzzer drew it: (box ∪ wall − hull) ∪
    // hull, moved whole. A section piece 5e-5 long at a tolerance of 2e-5, its two merged
    // vertices both within reach of both faces, ran across the line the faces meet along,
    // and the side read from its chord was the noise of their places: outside, where the
    // fragment's piece along the line beside it read inside (`unclassified`). A section
    // piece's way is the faces' own line, and a piece no longer along it than its ends
    // reach is not clear (`classify.sectionInto`)
    for (ACROSS_WHOLE) |whole| {
        errdefer std.debug.print("moved whole {any}\n", .{whole});
        var box_shape = try helpers.boxAt(tol, ACROSS_BOX[0], ACROSS_BOX[1]);
        defer box_shape.deinit();
        var wall_shape = try fuzzWall(tol, ACROSS_WALL_AT, ACROSS_WALL_LO, ACROSS_WALL_HI, ACROSS_WALL_XSECTS);
        defer wall_shape.deinit();
        var drawn = [_]Body{
            try fuzzPlaced(&box_shape, vec.Z3, 0, null, vec.ZERO3, ACROSS_BOX_NUDGE),
            try fuzzPlaced(&wall_shape, vec.Z3, 0, null, ACROSS_WALL_MOVE, ACROSS_WALL_NUDGE),
            try fuzzHullPlaced(&ACROSS_CUT, vec.Z3, 0, null, vec.ZERO3, ACROSS_CUT_NUDGE),
            try fuzzHullPlaced(&ACROSS_JOIN, vec.Z3, 0, ACROSS_JOIN_SCALE, vec.ZERO3, ACROSS_JOIN_NUDGE),
        };
        defer for (&drawn) |*body| body.deinit();
        var moved: [drawn.len]Body = undefined;
        for (&drawn, &moved, 0..) |*body, *out, k| out.* = sliverMoved(body, whole) catch |err| {
            for (moved[0..k]) |*done| done.deinit();
            return err;
        };
        defer for (&moved) |*body| body.deinit();
        var joined = try helpers.sound(&moved[0], &moved[1], .@"union");
        defer joined.deinit();
        var cut = try helpers.sound(&joined, &moved[2], .difference);
        defer cut.deinit();
        try expectDecidedEitherWay(&cut, &moved[3]);
    }
}

test "degeneracy: a section piece of a coarse plate running across the line its faces meet along shows no side, either way round" {
    // The ReleaseSafe session's find on ff515852 (de), as the fuzzer drew it: ((plate ∪
    // plate) − hull) ∩ a plate with a gap at a zone of 1e-4. A section piece 5.4e-4 long at
    // a tolerance of 2e-4 ran 87° off the line its faces meet along and read outside, where
    // the fragment's other pieces read inside (`unclassified`); with the gap plate a hair
    // nearer and farther, moved whole
    const coarse = Tolerance.fromZone(SPAN_PLATE_ZONE);
    for (SPAN_GAP_LIFTS) |lift| for (SLIVER_TURNS[0..3]) |move| {
        errdefer std.debug.print("gap plate nudged {e} in y, moved {any}\n", .{ lift, move });
        var plate_shape = try helpers.boxAt(coarse, SPAN_PLATE[0], SPAN_PLATE[1]);
        defer plate_shape.deinit();
        var step_shape = try helpers.boxAt(tol, SPAN_STEP[0], SPAN_STEP[1]);
        defer step_shape.deinit();
        var gap_shape = try fuzzGapPlate(coarse, SPAN_GAP_AT, SPAN_GAP_LO, SPAN_GAP_HI, SPAN_GAP_XSECTS);
        defer gap_shape.deinit();
        var drawn = [_]Body{
            try fuzzPlaced(&plate_shape, vec.Z3, 0, null, .{ 0, std.math.floatTrueMin(f64), 0 }, SPAN_PLATE_NUDGE),
            try fuzzPlaced(&step_shape, vec.Z3, 0, SPAN_STEP_SCALE, SPAN_STEP_MOVE, SPAN_STEP_NUDGE),
            try fuzzHullPlaced(&SPAN_CUT, vec.Z3, 0, null, vec.ZERO3, SPAN_CUT_NUDGE),
            try fuzzPlaced(&gap_shape, vec.Z3, 0, null, SPAN_GAP_MOVE, .{ 0, lift, 0 }),
        };
        defer for (&drawn) |*body| body.deinit();
        var moved: [drawn.len]Body = undefined;
        for (&drawn, &moved, 0..) |*body, *out, k| out.* = sliverMoved(body, move) catch |err| {
            for (moved[0..k]) |*done| done.deinit();
            return err;
        };
        defer for (&moved) |*body| body.deinit();
        var joined = try helpers.sound(&moved[0], &moved[1], .@"union");
        defer joined.deinit();
        var cut = try helpers.sound(&joined, &moved[2], .difference);
        defer cut.deinit();
        try expectDecidedEitherWay(&cut, &moved[3]);
    };
}

test "degeneracy: a section segment's middle outside one face and the tolerance to rounding from the other's edge is no part of where they meet, whichever operand comes first" {
    // The ReleaseSafe session's find on e83d2a0e (dl), as the fuzzer drew it: (hull ∪ a
    // plate with a gap) ∪ a wall with a gap, the wall nudged the tolerance and D27's band.
    // A section segment's middle lay outside the hull's face and the tolerance to rounding
    // from an edge of the wall's face; face–face asked the first operand's face first and
    // stopped at "outside", or refused `at_tolerance` at the wall's before asking the
    // hull's. Outside either settles it whatever the other (`pave.placeInBoth`)
    var hull_drawn = try fuzzHullPlaced(&BESIDE_HULL, vec.Z3, BESIDE_HULL_TURN, null, BESIDE_HULL_MOVE, BESIDE_HULL_NUDGE);
    defer hull_drawn.deinit();
    var plate_shape = try fuzzGapPlate(tol, BESIDE_PLATE_AT, BESIDE_GAP_LO, BESIDE_GAP_HI, BESIDE_GAP_XSECTS);
    defer plate_shape.deinit();
    var plate = try fuzzPlaced(&plate_shape, vec.Z3, BESIDE_PLATE_TURN, null, BESIDE_PLATE_MOVE, BESIDE_PLATE_NUDGE);
    defer plate.deinit();
    var joined = try helpers.sound(&hull_drawn, &plate, .@"union");
    defer joined.deinit();
    var wall_shape = try fuzzWall(tol, BESIDE_WALL_AT, BESIDE_GAP_LO, BESIDE_GAP_HI, BESIDE_GAP_XSECTS);
    defer wall_shape.deinit();
    for (BESIDE_STEPS) |steps| {
        errdefer std.debug.print("the wall {d} steps of 2^-51 past the find's nudge\n", .{steps});
        var wall = try fuzzPlaced(&wall_shape, vec.Z3, 0, null, vec.ZERO3, .{ BESIDE_WALL_NUDGE_XY[0], BESIDE_WALL_NUDGE_XY[1], BESIDE_WALL_NUDGE_Z + steps * BESIDE_STEP });
        defer wall.deinit();
        for ([_]pipeline.Op{ .@"union", .intersection }) |op| {
            errdefer std.debug.print("{t}\n", .{op});
            try testing.expectEqual(try outcomeOf(&joined, &wall, op), try outcomeOf(&wall, &joined, op));
        }
    }
}

test "degeneracy: two solids touching along a line through a face's centroid are one sound union, its shells counted clear of each other" {
    // A locus_solids ReleaseSafe run's find on e83d2a0e (dk), as the fuzzer drew it: the
    // block (box − box) leaves touches the hull's face along its edge, laid in that face
    // as a slit through the face's centroid. The shells' count sampled the hull at that
    // centroid, on two of the block's faces at once, where the block winds twice a half,
    // and the sound union was said to overlap itself (`shell_overlaps`). A shell is
    // counted at a point clear of the others (`overlap.onShell`)
    for (TOUCH_LIFTS) |lift| for (SLIVER_TURNS) |whole| {
        errdefer std.debug.print("the hull nudged {e} in z, moved whole {any}\n", .{ lift, whole });
        var drawn = [_]Body{
            try fuzzBoxPlaced(tol, TOUCH_BOX[0], TOUCH_BOX[1], vec.Z3, 0, null, TOUCH_BOX_NUDGE),
            try fuzzBoxPlaced(tol, TOUCH_CUT[0], TOUCH_CUT[1], vec.Z3, 0, null, TOUCH_CUT_NUDGE),
            try fuzzHullPlaced(&TOUCH_HULL, vec.Z3, 0, null, vec.ZERO3, .{ 0, TOUCH_HULL_NUDGE_Y, lift }),
        };
        defer for (&drawn) |*body| body.deinit();
        var moved: [drawn.len]Body = undefined;
        for (&drawn, &moved, 0..) |*body, *out, k| out.* = sliverMoved(body, whole) catch |err| {
            for (moved[0..k]) |*done| done.deinit();
            return err;
        };
        defer for (&moved) |*body| body.deinit();
        var block = try helpers.sound(&moved[0], &moved[1], .difference);
        defer block.deinit();
        var forward = try helpers.sound(&block, &moved[2], .@"union");
        defer forward.deinit();
        var swapped = try helpers.sound(&moved[2], &block, .@"union");
        defer swapped.deinit();
        try testing.expectEqual(forward.counts(), swapped.counts());
        try testing.expectEqual(@as(u32, 2), forward.counts().shells);
    };
}

test "degeneracy: a chain of vertices along two traces a hair apart keeps as many edges whichever operand comes first, the passes deciding it once" {
    // The ReleaseSafe session's find on ff515852 (dj), as the fuzzer drew it: ((hull −
    // wall) ∪ wall) ∪ box. The hull's face crosses the box's bottom and a wall's 1.5e-5
    // under it, a chain of vertices along the two traces, 2.6e-5 apart in the face. The
    // fewest runs took one vertex away or another, by the chain's order; one way round a
    // later pass then joined a further vertex away on a line the vertex the first pass
    // took lay off by more than the tolerance, and the union had a vertex fewer than the
    // other way round. A joined edge keeps the vertices it took the place of
    // (`simplify.Absorbed`), and a later pass finds no run the first did not have
    for (ACROSS_WHOLE) |whole| {
        errdefer std.debug.print("moved whole {any}\n", .{whole});
        var cut_shape = try fuzzWall(tol, TRACE_CUT_AT, TRACE_CUT_LO, TRACE_CUT_HI, TRACE_CUT_XSECTS);
        defer cut_shape.deinit();
        var wall_shape = try fuzzWall(tol, TRACE_WALL_AT, TRACE_WALL_LO, TRACE_WALL_HI, TRACE_WALL_XSECTS);
        defer wall_shape.deinit();
        var drawn = [_]Body{
            try fuzzHullPlaced(&TRACE_HULL, TRACE_HULL_AXIS, TRACE_HULL_TURN, TRACE_HULL_SCALE, TRACE_HULL_MOVE, TRACE_HULL_NUDGE),
            try fuzzPlaced(&cut_shape, vec.Z3, 0, null, TRACE_CUT_MOVE, TRACE_CUT_NUDGE),
            try fuzzPlaced(&wall_shape, vec.Z3, 0, null, TRACE_WALL_MOVE, TRACE_WALL_NUDGE),
            try fuzzBoxMovedPlaced(),
        };
        defer for (&drawn) |*body| body.deinit();
        var moved: [drawn.len]Body = undefined;
        for (&drawn, &moved, 0..) |*body, *out, k| out.* = sliverMoved(body, whole) catch |err| {
            for (moved[0..k]) |*done| done.deinit();
            return err;
        };
        defer for (&moved) |*body| body.deinit();
        var cut = try helpers.sound(&moved[0], &moved[1], .difference);
        defer cut.deinit();
        var joined = try helpers.sound(&cut, &moved[2], .@"union");
        defer joined.deinit();
        try expectDecidedEitherWay(&joined, &moved[3]);
    }
}

/// dj's box, placed as the fuzzer placed it (turned, scaled, moved, nudged).
fn fuzzBoxMovedPlaced() !Body {
    var shape = try helpers.boxAt(tol, TRACE_BOX[0], TRACE_BOX[1]);
    defer shape.deinit();
    return fuzzPlaced(&shape, vec.Z3, TRACE_BOX_TURN, TRACE_BOX_SCALE, TRACE_BOX_MOVE, TRACE_BOX_NUDGE);
}

test "degeneracy: a corner face whose edge ends a hair from its vertex measures alike mirrored, a sliver or not" {
    // The equal-zone family of by (2026-11-22): the slab's corner triangle has a top edge,
    // the hull's, ending 1e-4 under the vertex it meets the box's edge at (D28: an edge
    // keeps its source's line). The checker's sliver measure walked each line short of
    // its end, cutting that corner one way round the loop and keeping it the other: 0.9956
    // of the limit unmirrored, refused, and 1.047 of it mirrored, made. Each curve is
    // measured from its own start to its own end and a step across each gap, the polygon
    // the volume is measured on (`check.loopMeasure`, `integrals.planarFace`), the same
    // either way
    for (TIE_EQUAL_RISES) |rise| for (0..4) |quarter| for ([_]pipeline.Op{ .intersection, .@"union" }) |op| {
        errdefer std.debug.print("the tops {d} tolerances apart, {d} quarter turns, {t}\n", .{ rise, quarter, op });
        var outcomes: [2]Outcome = undefined;
        for ([_]bool{ false, true }, &outcomes) |mirrored, *outcome| {
            var solids = try tieSolids(.{ TIE_EQUAL_ZONE, TIE_EQUAL_ZONE }, TIE_EQUAL_UNDER + rise * Tolerance.fromZone(TIE_EQUAL_ZONE).xsect, quarter, mirrored);
            defer for (&solids) |*body| body.deinit();
            outcome.* = try outcomeOf(&solids[0], &solids[1], op);
        }
        try testing.expectEqual(outcomes[0], outcomes[1]);
    };
}

test "degeneracy: a hull's corner within the tolerance of a plate's side, its edge along the side's plane and its faces rising from it, cuts the side along that edge: made and sound either way round" {
    // The find dm (the nightly's locus_solids, 2026-11-23, on 9c931fef), as the fuzzer
    // drew it. The merged vertices on both the side and the hull's face between the
    // corner's edges down to the plate's bottom (the corner, and where the two edges cross
    // the bottom) were a triangle, all three within the tolerance of both; the corner and
    // one crossing one place along the faces' line by the angle, ordered across, the gaps
    // skipped the edge along the side's plane, which was not cut along it: the side's piece
    // inside the hull was kept with the hull's triangle over part of it, an edge of the
    // intersection with three faces and another with one (`edge_coedge_count`, every
    // operation either way round)
    var drawn = try fuzzGapPlate(tol, .{ 0, 1, 2 }, SIDE_CORNER_PLATE[0], .{ 4, 4, 4 }, SIDE_CORNER_XSECTS);
    defer drawn.deinit();
    var plate = try fuzzPlaced(&drawn, vec.Z3, 0, null, vec.ZERO3, SIDE_CORNER_PLATE_NUDGE);
    defer plate.deinit();
    var hull = try fuzzHull(&SIDE_CORNER_HULL, vec.ZERO3, SIDE_CORNER_HULL_NUDGE);
    defer hull.deinit();
    for ([_]pipeline.Op{ .intersection, .@"union", .difference }) |op| {
        for ([2][2]*const Body{ .{ &plate, &hull }, .{ &hull, &plate } }) |operands| {
            var made = try sound(operands[0], operands[1], op);
            made.deinit();
        }
        if (op != .difference) try expectAlikeEitherWay(&plate, &hull, op);
    }
}

test "degeneracy: a hull's corner near a plate's side, within the tolerance of it or past it, turned and mirrored, is decided alike either way round" {
    for ([_][]const f64{ &SIDE_CORNER_WITHIN, &SIDE_CORNER_BESIDE }, 0..) |shifts, set| for (shifts) |shift| for ([_]pipeline.Op{ .intersection, .@"union", .difference }) |op| {
        var outcome: ?Outcome = null;
        for (0..4) |quarter| for ([_]bool{ false, true }) |mirrored| {
            errdefer std.debug.print("shift {e}, {t}, quarter turns {d}, mirrored {}\n", .{ shift, op, quarter, mirrored });
            var solids = try sideCornerSolids(shift, quarter, mirrored);
            defer for (&solids) |*body| body.deinit();
            if (op != .difference) try expectAlikeEitherWay(&solids[0], &solids[1], op);
            const this = try outcomeOf(&solids[0], &solids[1], op);
            if (outcome) |first| try testing.expectEqual(first, this) else outcome = this;
        };
        // The corner on the side within the tolerance, every operation is made
        if (set == 0) try testing.expect(outcome.? == .made);
    };
}

/// The plate and the hull of the tests of a hull's corner near a plate's side, the hull
/// moved `shift` more in x, both turned `quarter` quarter turns about z and mirrored or
/// not (`tieMove`, exact).
fn sideCornerSolids(shift: f64, quarter: usize, mirrored: bool) ![2]Body {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const half = SIDE_CORNER_XSECTS * tol.xsect / 2;
    const drawn = [2]Vec3{ .{ SIDE_CORNER_PLATE[0][0], SIDE_CORNER_PLATE[0][1], SIDE_CORNER_PLATE[0][2] - half }, .{ SIDE_CORNER_PLATE[1][0], SIDE_CORNER_PLATE[1][1], SIDE_CORNER_PLATE[1][2] + half } };
    const corners = [2]Vec3{ tieMove(vec.add(drawn[0], SIDE_CORNER_PLATE_NUDGE), quarter, mirrored), tieMove(vec.add(drawn[1], SIDE_CORNER_PLATE_NUDGE), quarter, mirrored) };
    var lo: Vec3 = undefined;
    var hi: Vec3 = undefined;
    for (0..3) |k| {
        lo[k] = @min(corners[0][k], corners[1][k]);
        hi[k] = @max(corners[0][k], corners[1][k]);
    }
    var plate = try helpers.boxAt(tol, lo, hi);
    errdefer plate.deinit();
    var points: [SIDE_CORNER_HULL.len]Vec3 = undefined;
    for (SIDE_CORNER_HULL, &points) |q, *moved| moved.* = tieMove(vec.add(vec.add(q, SIDE_CORNER_HULL_NUDGE), .{ shift, 0, 0 }), quarter, mirrored);
    const hull = try @import("../construct/hull.zig").hull(testing.allocator, tol, &points, &diag);
    return .{ plate, hull };
}

/// The running solid and the last hull of the tests about find dn: the box less the first
/// hull, joined with the second, and the last hull nudged by `nudge`; both turned
/// `quarter` quarter turns about z through the origin.
fn ownBlockSolids(nudge: Vec3, quarter: usize) ![2]Body {
    var drawn_box = try fuzzBoxPlaced(tol, OWN_BOX[0], OWN_BOX[1], vec.Z3, 0, OWN_BOX_SCALE, OWN_BOX_NUDGE);
    defer drawn_box.deinit();
    var cut = try fuzzHullPlaced(&OWN_CUT, vec.Z3, OWN_CUT_TURN, OWN_CUT_SCALE, OWN_CUT_MOVE, OWN_CUT_NUDGE);
    defer cut.deinit();
    var join = try fuzzHullPlaced(&OWN_JOIN, vec.Z3, 0, null, OWN_JOIN_MOVE, OWN_JOIN_NUDGE);
    defer join.deinit();
    var last = try fuzzHullPlaced(&OWN_LAST, vec.Z3, 0, null, vec.ZERO3, nudge);
    defer last.deinit();
    var notched = try sound(&drawn_box, &cut, .difference);
    defer notched.deinit();
    var running = try sound(&notched, &join, .@"union");
    defer running.deinit();
    if (quarter == 0) return .{ try running.clone(testing.allocator), try last.clone(testing.allocator) };
    const turn = mat.Affine.rotateAbout(vec.ZERO3, vec.Z3, std.math.pi / 2.0 * @as(f64, @floatFromInt(quarter)));
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const transform = @import("../construct/transform.zig").transform;
    var turned_running = try transform(testing.allocator, &running, &turn, .{}, &diag);
    errdefer turned_running.deinit();
    return .{ turned_running, try transform(testing.allocator, &last, &turn, .{}, &diag) };
}

test "degeneracy: a hull's base edge along a face it lies in, between ends merged onto it by their reach, cuts the face, so a pocket meeting it is refused" {
    // The nightly's locus_solids find dn (2026-11-24): the last hull's base edge ran along
    // the running solid's face at x = 4, its ends merged onto the box's top edge 1.5e-5
    // off it across and along (2.1e-5, within their reach of 2.5e-5 by their gap of 5e-6).
    // The block between them, the hull's own edge, was measured again by its middle with
    // no gap and left outside the hull's faces, so the face at x = 4 was not cut along it.
    // The difference kept the hull's sloped face as a pocket's wall meeting that face along
    // the line, the body touching itself there, made, and only the overlap rules saw it.
    // A face's own pave block is on its boundary by the paves' record (`pave.ownBlock`)
    var solids = try ownBlockSolids(OWN_LAST_NUDGES[0], 0);
    defer for (&solids) |*body| body.deinit();
    try expectDecidedEitherWay(&solids[0], &solids[1]);
}

test "degeneracy: a hull's base edge near a face it may lie in, nearer and farther and turned, is decided alike either way round" {
    // The cases about the find above: the last hull's base edge nearer the running solid's
    // face and edge and farther (`OWN_LAST_NUDGES`, either side of the merged ends' reach),
    // all turned the four quarter turns about z
    for (OWN_LAST_NUDGES) |nudge| for (0..4) |quarter| {
        errdefer std.debug.print("the last hull nudged {any}, {d} quarter turns\n", .{ nudge, quarter });
        var solids = try ownBlockSolids(nudge, quarter);
        defer for (&solids) |*body| body.deinit();
        try expectDecidedEitherWay(&solids[0], &solids[1]);
    };
}
