//! The case rig (locus/docs/architecture.md §9.3; research: SolidCraft's kernel-cases):
//! every case is a script and its own right answer, with the formula in words and where
//! the case came from. The answer is never a kernel's output: a closed form (`analytic`)
//! or an identity the result must satisfy (`invariants`). The cases are ordered as a
//! ladder by tier, each tier building on the shapes of the tiers before it, and the
//! **frontier** of a tier is its first case that fails, crashes or hangs; a refusal by
//! design (`refused`, until the milestone named) is counted apart and is not a frontier.
//! `case_rig.zig` runs them, `case_rig_test.zig` holds the ladder green, and
//! `kupcad dev brep-readiness` prints the ladder with its frontier. It lives with the dev
//! tools, which may run scripts; the kernel layer may not.
//!
//! A case that fails stays failing until the kernel is fixed: never a workaround in the
//! script, never a looser answer. When a milestone lands a feature, its `refused` cases
//! get their closed forms and the tier's frontier moves.

const std = @import("std");
const kernel = @import("../../kernel/kernel.zig");

const PI = std.math.pi;

/// The ladder's tiers, in order; each case names one.
pub const Tier = enum(u8) {
    primitives = 1,
    booleans = 2,
    profiles = 3,
    sweeps = 4,
    holes = 5,
    fillets = 7,
    offsets = 9,
    patterns = 10,
    parts = 11,

    pub fn label(self: Tier) []const u8 {
        return switch (self) {
            .primitives => "primitives",
            .booleans => "booleans",
            .profiles => "profiles",
            .sweeps => "sweeps",
            .holes => "holes",
            .fillets => "fillets and chamfers",
            .offsets => "offsets and shells",
            .patterns => "patterns and mirrors",
            .parts => "cumulative parts",
        };
    }
};

/// Where a case's answer comes from.
pub const Source = enum {
    /// A closed form, in `method`.
    analytic,
    /// An identity the result satisfies, in `method`.
    invariants,
};

pub const Measures = struct {
    volume: f64,
    /// The surface area, when its closed form is known.
    area: ?f64 = null,
    /// An empty result (nothing built), of no volume.
    empty: bool = false,
};

pub const Refusal = struct {
    /// The feature the engine says it can't do yet ("the brep engine can't …"), or
    /// `says`, a piece of the refusal's message, for a refusal that is not a feature's.
    feature: ?kernel.Feature = null,
    says: ?[]const u8 = null,
    /// The milestone that lands it, when the case gets its closed form; or why never.
    until: []const u8,
};

pub const Expect = union(enum) {
    measures: Measures,
    /// Refused by design on the B-Rep engine, counted apart from a failure.
    refused: Refusal,
};

pub const Case = struct {
    tier: Tier,
    name: []const u8,
    /// One expression; the rig assigns it to `r` and measures `r`.
    script: []const u8,
    what: []const u8,
    /// The formula or the identity, in words.
    method: []const u8,
    source: Source,
    /// Where the case comes from: a plan item, a fuzzer find, a report, a commit.
    from: []const u8,
    expect: Expect,
    /// How far the mesh engine's volume may differ from the answer, relative (its chords);
    /// null when the mesh engine approximates by design or can't build the script.
    mesh_bound: ?f64,
};

/// The B-Rep engine's volume must match a closed form to this, relative.
pub const EXACT: f64 = 1e-9;
/// A circle cut into 64 segments: its polygon's area is (n/2)·sin(2π/n) of the disc's,
/// 0.9984 for n = 64, so a mesh volume is within this of the exact one.
const CHORDS_64: f64 = 1e-2;
/// A unit arc at the default resolution: a few chords a turn, a tenth off.
const CHORDS_DEFAULT: f64 = 1e-1;
/// A round offset's arcs get the mesh engine's default segments, few at these sizes.
const CHORDS_OFFSET: f64 = 2e-2;

const ANALYTIC = Source.analytic;
const PLAN = "locus-plan MILESTONES M2 exit (case rig, 2026-11-09)";
/// The examples parabolic_dish and planetary_gearbox, failing in extrude and revolve until
/// M3's review found them (2026-11-12), reduced.
const FOUND_AT_M3_EXIT = "examples parabolic_dish and planetary_gearbox, M3 follow-up (2026-11-12)";

/// A case known to fail, with why: the frontier the ladder is expected to show until the
/// fix lands, when it leaves this list (a fix that does not is a test failure, as a new
/// failure is). Never a workaround in the case.
pub const Known = struct { name: []const u8, why: []const u8 };
pub const KNOWN_FRONTIER = [_]Known{};

pub const CASES = [_]Case{
    // --- 01 primitives: closed-form volumes and areas
    .{ .tier = .primitives, .name = "cube", .script = "cube(2)", .what = "a cube of side 2", .method = "side cubed; area six sides squared", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 8, .area = 24 } }, .mesh_bound = EXACT },
    .{ .tier = .primitives, .name = "box", .script = "cube(1, 2, 3)", .what = "a box 1 by 2 by 3", .method = "the sides' product; area twice the sum of the three face areas", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 6, .area = 22 } }, .mesh_bound = EXACT },
    .{ .tier = .primitives, .name = "cylinder", .script = "cylinder(r: 1, h: 3, segments: 64)", .what = "a cylinder of radius 1, height 3", .method = "π r² h; area 2π r h plus two discs", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 3 * PI, .area = 8 * PI } }, .mesh_bound = CHORDS_64 },
    .{ .tier = .primitives, .name = "cone frustum", .script = "cylinder(r1: 2, r2: 1, h: 3, segments: 64)", .what = "a frustum from radius 2 to 1 over height 3", .method = "π h (R² + R r + r²) / 3; area π (R + r) s plus the two discs, s the slant √(h² + (R − r)²)", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 7 * PI, .area = 3 * PI * @sqrt(10.0) + 5 * PI } }, .mesh_bound = CHORDS_64 },
    .{ .tier = .primitives, .name = "sphere", .script = "sphere(r: 2, segments: 64)", .what = "a sphere of radius 2", .method = "4/3 π r³; area 4π r²", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 32.0 / 3.0 * PI, .area = 16 * PI } }, .mesh_bound = CHORDS_64 },
    .{ .tier = .primitives, .name = "torus", .script = "torus(major_r: 5, minor_r: 1, segments: 64)", .what = "a torus of radii 5 and 1", .method = "Pappus: 2π² R r²; area 4π² R r", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 10 * PI * PI, .area = 20 * PI * PI } }, .mesh_bound = CHORDS_64 },

    // --- 02 booleans: of sketches now (M2); of solids refused until M4
    .{ .tier = .booleans, .name = "plate less a square", .script = "(square(10) - square(4).translate(3, 3)).extrude(2)", .what = "a 10 by 10 plate with a 4 by 4 window, 2 thick", .method = "(100 − 16) × 2", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 168 } }, .mesh_bound = EXACT },
    .{ .tier = .booleans, .name = "two squares joined", .script = "(square(10) + square(10).translate(5, 5)).extrude(1)", .what = "two 10 by 10 squares overlapping in a 5 by 5 corner", .method = "100 + 100 − 25", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 175 } }, .mesh_bound = EXACT },
    .{ .tier = .booleans, .name = "square within a circle", .script = "(square(4, center: true) & circle(r: 3, segments: 64)).extrude(1)", .what = "a centred 4 by 4 square cut to a circle of radius 3, which holds it", .method = "the square's corners are 2√2 < 3 from the centre, so the square itself: 16", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 16 } }, .mesh_bound = EXACT },
    .{ .tier = .booleans, .name = "plate less a disc", .script = "(square(10) - circle(r: 2, segments: 64).translate(5, 5)).extrude(3)", .what = "a 10 by 10 plate with a round hole of radius 2, 3 thick", .method = "(100 − 4π) × 3", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = (100 - 4 * PI) * 3 } }, .mesh_bound = CHORDS_64 },
    .{ .tier = .booleans, .name = "difference of two sketches, two pieces", .script = "(square(10) - square(2, 20).translate(4, -5)).extrude(1)", .what = "a 10 by 10 square cut in two by a 2-wide strip", .method = "100 − 2 × 10", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 80 } }, .mesh_bound = EXACT },
    .{ .tier = .booleans, .name = "cube less a sphere", .script = "cube(4) - sphere(2.5, segments: 64).translate(x: 2, y: 2, z: 2)", .what = "a cube of side 4 less a sphere of radius 2.5 about its centre", .method = "refused: booleans of curved solids are M5's; then 64 less the sphere's part within the cube", .source = ANALYTIC, .from = PLAN, .expect = .{ .refused = .{ .feature = .curved_boolean, .until = "M5" } }, .mesh_bound = null },
    .{ .tier = .booleans, .name = "two cubes joined", .script = "cube(2) + cube(2).translate(1, 1, 1)", .what = "two cubes of side 2 overlapping in a unit cube", .method = "8 + 8 − 1; each cube's 24 less the three unit squares inside the other", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 15, .area = 42 } }, .mesh_bound = EXACT },
    .{ .tier = .booleans, .name = "cube with a void", .script = "cube(4) - cube(2).translate(1, 1, 1)", .what = "a cube of side 4 less a cube of side 2 inside it", .method = "64 − 8; the outer 96 and the void's 24", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 56, .area = 120 } }, .mesh_bound = EXACT },
    .{ .tier = .booleans, .name = "plate with a square hole", .script = "cube(10, 10, 2) - cube(2, 2, 4).translate(4, 4, -1)", .what = "a 10 by 10 plate 2 thick with a 2 by 2 hole through it", .method = "(100 − 4) × 2; two faces of 96, the rim's 80 and the hole's 16", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 192, .area = 288 } }, .mesh_bound = EXACT },
    .{ .tier = .booleans, .name = "cube trimmed on a slant", .script = "cube(2).trim_by_plane(1, 1, 0, Math.sqrt(2))", .what = "a cube of side 2 cut by the plane x + y = 2, the part beyond it", .method = "a prism on the triangle of legs 2: 2 × 2", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 4 } }, .mesh_bound = EXACT },

    // --- 03 profiles: polygons extruded and revolved
    .{ .tier = .profiles, .name = "square extruded", .script = "square(10).extrude(5)", .what = "a 10 by 10 square extruded 5", .method = "100 × 5; area 2 × 100 + 4 × 50", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 500, .area = 400 } }, .mesh_bound = EXACT },
    .{ .tier = .profiles, .name = "quadrilateral extruded", .script = "polygon([[0, 0], [4, 0], [4, 3], [1, 5]]).extrude(2)", .what = "a quadrilateral of area 14.5 extruded 2", .method = "the shoelace area 14.5, times 2; area twice it plus the perimeter (7 + √13 + √26) times 2", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 29, .area = 29 + 2 * (7 + @sqrt(13.0) + @sqrt(26.0)) } }, .mesh_bound = EXACT },
    .{ .tier = .profiles, .name = "hexagon extruded", .script = "regular_polygon(6, r: 5).extrude(2)", .what = "a regular hexagon of circumradius 5 extruded 2", .method = "(3√3 / 2) r² × 2", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 3 * @sqrt(3.0) / 2.0 * 25 * 2 } }, .mesh_bound = EXACT },
    .{ .tier = .profiles, .name = "rounded triangle extruded", .script = "polygon([[0, 0], [4, 0], [4, 3]], round_r: 0.5, segments: 64).extrude(2)", .what = "the 3-4-5 triangle with its corners rounded to a half, extruded 2", .method = "each corner of angle θ loses r² (cot(θ/2) − (π − θ)/2): the three together r² (6 − π), so (6 − 1.5 + π/4) × 2", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = (4.5 + PI / 4.0) * 2 } }, .mesh_bound = CHORDS_64 },
    .{ .tier = .profiles, .name = "slot from a closed path", .script = "line([0, 0], [4, 0]).arc_to([4, 2], r: 1).line_to([0, 2]).arc_to([0, 0], r: 1).close.extrude(2)", .what = "a stadium of a 4 by 2 rectangle with half-discs of radius 1 at its ends, extruded 2", .method = "(8 + π) × 2", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = (8 + PI) * 2 } }, .mesh_bound = CHORDS_DEFAULT },
    .{ .tier = .profiles, .name = "square revolved", .script = "square(2).translate(1, 0).revolve(segments: 64)", .what = "a 2 by 2 square a unit off the axis, revolved fully", .method = "Pappus: the area 4 times the path of its centroid, 2π × 2", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 16 * PI } }, .mesh_bound = CHORDS_64 },
    .{ .tier = .profiles, .name = "square revolved a quarter", .script = "square(2).translate(1, 0).revolve(deg: 90, segments: 64)", .what = "the same square revolved a quarter turn", .method = "a quarter of Pappus: 4π", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 4 * PI } }, .mesh_bound = CHORDS_64 },
    .{ .tier = .profiles, .name = "triangle revolved into a cone", .script = "polygon([[0, 0], [2, 0], [0, 3]]).revolve(segments: 64)", .what = "a right triangle on the axis revolved: a cone of radius 2, height 3", .method = "π r² h / 3", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 4 * PI } }, .mesh_bound = CHORDS_64 },
    .{ .tier = .profiles, .name = "disc revolved into a torus", .script = "circle(r: 1, segments: 64).translate(3, 0).revolve(segments: 64)", .what = "a disc of radius 1 three off the axis, revolved", .method = "Pappus: π r² × 2π R", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 6 * PI * PI } }, .mesh_bound = CHORDS_64 },

    .{ .tier = .profiles, .name = "bow tie extruded", .script = "polygon([[0, 0], [2, 2], [2, 0], [0, 2]]).extrude(3)", .what = "a self-crossing outline: two triangles touching at (1, 1), extruded 3 (two solids touching along a line)", .method = "each triangle of area 1 times 3; area: four triangle caps and the sides, 3 × twice the perimeter 2 + 2√2", .source = ANALYTIC, .from = FOUND_AT_M3_EXIT, .expect = .{ .measures = .{ .volume = 6, .area = 4 + 12 + 12 * @sqrt(2.0) } }, .mesh_bound = EXACT },
    .{ .tier = .profiles, .name = "bow tie revolved", .script = "polygon([[0, 0], [2, 2], [2, 0], [0, 2]]).translate(3, 0).revolve(segments: 64)", .what = "the bow tie three off the axis, revolved: two rings touching along a circle, the diagonals' pieces on one cone", .method = "Pappus: each triangle's area 1 times its centroid's path, 2π (3 + 1/3) + 2π (3 + 5/3) = 16π", .source = ANALYTIC, .from = FOUND_AT_M3_EXIT, .expect = .{ .measures = .{ .volume = 16 * PI } }, .mesh_bound = CHORDS_64 },
    .{ .tier = .profiles, .name = "two blocks sharing a side plane", .script = "(square(2, 1) + square(2, 1).translate(3, -1)).extrude(2)", .what = "two 2 by 1 blocks whose sides lie in the plane y = 0, facing opposite ways (as an even-toothed gear's opposite flanks)", .method = "2 × (2 × 1 × 2); area 2 × 2 (2 + 4 + 2)", .source = ANALYTIC, .from = FOUND_AT_M3_EXIT, .expect = .{ .measures = .{ .volume = 8, .area = 32 } }, .mesh_bound = EXACT },

    // --- 04 sweeps
    .{ .tier = .sweeps, .name = "square swept along a line", .script = "square(2).sweep(line([0, 0], [10, 0]))", .what = "a 2 by 2 square swept 10 along a line", .method = "4 × 10", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 40 } }, .mesh_bound = EXACT },
    .{ .tier = .sweeps, .name = "square swept along an arc", .script = "square(2).sweep(arc(center: [10, 0], r: 10, start: 180, sweep: 90), segments: 64)", .what = "a 2 by 2 square swept a quarter turn about a point 10 away, its x along the radius inward", .method = "Pappus: 4 times the path of the centroid, which rides at radius 10 − 1: a quarter of 2π × 9", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 18 * PI } }, .mesh_bound = CHORDS_64 },
    .{ .tier = .sweeps, .name = "square extruded with a twist", .script = "square(1, center: true).extrude(4, twist: 90)", .what = "a unit square extruded 4 with a quarter twist", .method = "refused: twisted extrusions are later; the volume is the square's area times the height, 4, whatever the twist", .source = ANALYTIC, .from = PLAN, .expect = .{ .refused = .{ .feature = .extrude_twist, .until = "M5" } }, .mesh_bound = null },

    // --- 05 holes
    .{ .tier = .holes, .name = "plate with three round holes", .script = "(square(10) - circle(r: 1, segments: 64).translate(2, 2) - circle(r: 1, segments: 64).translate(5, 5) - circle(r: 1, segments: 64).translate(8, 8)).extrude(2)", .what = "a 10 by 10 plate 2 thick with three holes of radius 1", .method = "(100 − 3π) × 2", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = (100 - 3 * PI) * 2 } }, .mesh_bound = CHORDS_64 },
    .{ .tier = .holes, .name = "ring", .script = "(circle(r: 3, segments: 64) - circle(r: 1, segments: 64)).extrude(2)", .what = "a ring of radii 3 and 1, 2 thick", .method = "π (9 − 1) × 2", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 16 * PI } }, .mesh_bound = CHORDS_64 },

    // --- 07 fillets and chamfers: refused until M7
    .{ .tier = .fillets, .name = "cube with rounded edges", .script = "cube(3, round_r: 0.5)", .what = "a cube of side 3 with its vertical edges rounded to radius 0.5", .method = "the four vertical edges rounded (a rounded square extruded): (9 − (4 − π) r²) × 3", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = (9 - (4 - PI) * 0.25) * 3 } }, .mesh_bound = CHORDS_OFFSET },
    .{ .tier = .fillets, .name = "cube with chamfered edges", .script = "cube(3, chamfer: 0.4)", .what = "a cube of side 3 with its vertical edges chamfered 0.4", .method = "the four vertical edges cut: (9 − 4 c² / 2) × 3", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = (9 - 4 * 0.16 / 2.0) * 3 } }, .mesh_bound = EXACT },

    // --- 09 offsets and shells
    .{ .tier = .offsets, .name = "square grown round", .script = "square(10).offset(2, join: :round).extrude(1)", .what = "a 10 by 10 square grown by 2 with round corners", .method = "Steiner: 100 + 40 × 2 + π 2²", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 180 + 4 * PI } }, .mesh_bound = CHORDS_OFFSET },
    .{ .tier = .offsets, .name = "square grown mitered", .script = "square(10).offset(2, join: :miter).extrude(1)", .what = "a 10 by 10 square grown by 2 with sharp corners", .method = "(10 + 4)²", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 196 } }, .mesh_bound = EXACT },
    .{ .tier = .offsets, .name = "square shrunk", .script = "square(10).offset(-2, join: :round).extrude(1)", .what = "a 10 by 10 square shrunk by 2", .method = "(10 − 4)²", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 36 } }, .mesh_bound = EXACT },
    .{ .tier = .offsets, .name = "plate with a hole grown", .script = "(square(10) - circle(r: 2, segments: 64).translate(5, 5)).offset(1, join: :round).extrude(1)", .what = "a plate with a round hole of radius 2, grown by 1: the hole shrinks to radius 1", .method = "Steiner on the outline, 100 + 40 + π, less the shrunk hole, π 1²", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 140 } }, .mesh_bound = CHORDS_OFFSET },
    .{ .tier = .offsets, .name = "U shrunk with round joins", .script = "polygon([[0, 0], [6, 0], [6, 7], [3.5, 7], [3.5, 3], [2.5, 3], [2.5, 7], [0, 7]]).offset(-1, join: :round).extrude(1)", .what = "a 6 by 7 plate with a slot 1 wide and 4 deep, shrunk by 1", .method = "a U again, legs half wide and base one high, 8, plus at each inner corner the square between the sweeps less a quarter disc, 2 (1 − π/4)", .source = ANALYTIC, .from = "the fuzzer's offset finds, Locus offset_test (2026-11-08)", .expect = .{ .measures = .{ .volume = 8 + 2 * (1 - PI / 4.0) } }, .mesh_bound = null },
    .{ .tier = .offsets, .name = "U grown shut", .script = "polygon([[0, 0], [6, 0], [6, 7], [3.5, 7], [3.5, 3], [2.5, 3], [2.5, 7], [0, 7]]).offset(1, join: :round).extrude(1)", .what = "the same U grown by 1: the slot closes but for a notch at its mouth", .method = "the grown plate, 42 + 26 + π, less the notch the two corner discs leave, 1 − √3/4 − π/6", .source = ANALYTIC, .from = "the fuzzer's offset finds, Locus offset_test (2026-11-08)", .expect = .{ .measures = .{ .volume = 68 + PI - (1 - @sqrt(3.0) / 4.0 - PI / 6.0) } }, .mesh_bound = null },
    .{ .tier = .offsets, .name = "sliver shrunk past its width", .script = "polygon([[0, 0], [10, 0], [5, 0.1]]).offset(-1, join: :round).extrude(1)", .what = "a sliver triangle of height 0.1 shrunk by 1: nothing", .method = "every point of the sliver is within 0.05 of its edges, so nothing is left", .source = ANALYTIC, .from = "the fuzzer's hang (offset inside out), Locus offset_test (2026-11-08)", .expect = .{ .measures = .{ .volume = 0, .empty = true } }, .mesh_bound = EXACT },
    .{ .tier = .offsets, .name = "cube shelled", .script = "cube(4).shell(0.5)", .what = "a cube of side 4 hollowed to walls 0.5 thick", .method = "refused: shells are M7's; then 64 − 27", .source = ANALYTIC, .from = PLAN, .expect = .{ .refused = .{ .feature = .minkowski, .until = "M7" } }, .mesh_bound = null },

    // --- 10 patterns and mirrors: rigid moves keep the volume, a scale cubes it
    .{ .tier = .patterns, .name = "cube moved and turned", .script = "cube(2).translate(1, 2, 3).rotate(z: 90)", .what = "a cube of side 2 moved and turned", .method = "a rigid move keeps the volume: 8", .source = .invariants, .from = PLAN, .expect = .{ .measures = .{ .volume = 8, .area = 24 } }, .mesh_bound = EXACT },
    .{ .tier = .patterns, .name = "cube mirrored", .script = "cube(1, 2, 3).mirror([1, 0, 0])", .what = "a box mirrored in the yz plane", .method = "a mirror keeps the volume: 6", .source = .invariants, .from = PLAN, .expect = .{ .measures = .{ .volume = 6, .area = 22 } }, .mesh_bound = EXACT },
    .{ .tier = .patterns, .name = "sphere scaled", .script = "sphere(r: 2, segments: 64).translate(1, 2, 3).scale(2)", .what = "a sphere of radius 2 moved and scaled by 2", .method = "a scale by s multiplies the volume by s³: 8 × 4/3 π 2³", .source = .invariants, .from = PLAN, .expect = .{ .measures = .{ .volume = 8 * 32.0 / 3.0 * PI } }, .mesh_bound = CHORDS_64 },
    .{ .tier = .patterns, .name = "cylinder scaled unevenly", .script = "cylinder(r: 1, h: 3, segments: 64).scale(1, 2, 1)", .what = "a cylinder stretched along y", .method = "refused by design (D20): the exact engine keeps no elliptic cylinder; the mesh engine's volume is 2 × 3π", .source = ANALYTIC, .from = PLAN, .expect = .{ .refused = .{ .says = "non-uniform scale", .until = "never (D20)" } }, .mesh_bound = null },

    // --- 11 cumulative parts
    .{ .tier = .parts, .name = "bracket plate", .script = "(square(10) - circle(r: 2, segments: 64).translate(5, 5)).offset(1, join: :round).extrude(1).translate(0, 0, 2).rotate(x: 90)", .what = "the grown plate with its shrunk hole, moved and stood up", .method = "the offsets' case, 140, kept by the rigid move", .source = .invariants, .from = PLAN, .expect = .{ .measures = .{ .volume = 140 } }, .mesh_bound = CHORDS_OFFSET },
    .{ .tier = .parts, .name = "hull of two squares", .script = "square(10).hull(square(4).translate(15, 5)).extrude(1)", .what = "the hull of a 10 by 10 square and a 4 by 4 square to its right, extruded", .method = "the hull's shoelace area over its six corners: 163", .source = ANALYTIC, .from = PLAN, .expect = .{ .measures = .{ .volume = 163 } }, .mesh_bound = EXACT },
};
