//! Where a point lies in a face by its loops' winding (`in_face.classify`, the queries'
//! way for a face with curved edges): a disc bounded by two arcs of one circle, the long
//! one winding most of a turn about points inside it.

const std = @import("std");
const testing = std.testing;
const vec = @import("../math/vec.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;
const Diagnostics = @import("../diagnostics.zig").Diagnostics;
const primitives = @import("../construct/primitives.zig");
const types = @import("../topology/types.zig");
const in_face = @import("in_face.zig");
const Vec2 = vec.Vec2;

const tol = Tolerance.fromZone(1e-5);
/// The disc of the find dg (the 2D chain fuzzer, 2026-11-22): a circle grown by an offset
/// to radius 2.0811 about (2.5, 1.5), its boundary two arcs, the short one from the angle
/// 0 to 0.32175, the long one on round; the point the queries asked, 0.634 of the radius
/// out at the angle 4.1923, which its own cap's winding put outside.
const DISC_CENTRE: Vec2 = .{ 2.5, 1.5 };
const DISC_RADIUS: f64 = 2.08113883008419;
const FIND_SHORT_ARC: f64 = 0.32175055439664213;
const FIND_POINT: Vec2 = .{ 1.8444412685234803, 0.3553736434536954 };
/// The family: the short arc's sweep, where it starts, and the points asked, at shares of
/// the radius (inside, near the rim either side, outside) and at angles round the circle.
const SHORT_ARCS = [_]f64{ 0.05, FIND_SHORT_ARC, 1.0 };
const ARC_STARTS = [_]f64{ 0, 0.7, 2.2, 4.0 };
const RADIUS_SHARES = [_]f64{ 0.2, 0.5, 0.634, 0.9, 0.99, 1.01, 1.3 };
const POINT_ANGLES = 24;

/// The disc as a sheet: the circle about `centre` cut at the angles `start` and `start +
/// short` into two counter-clockwise arcs; mirrored in x when `mirrored`.
fn disc(centre: Vec2, start: f64, short: f64, mirrored: bool, diag: *Diagnostics) !@import("../topology/body.zig").Body {
    const sign: f64 = if (mirrored) -1 else 1;
    const c: Vec2 = .{ sign * centre[0], centre[1] };
    const at = struct {
        fn at(cc: Vec2, s: f64, angle: f64) Vec2 {
            return .{ cc[0] + s * DISC_RADIUS * @cos(angle), cc[1] + DISC_RADIUS * @sin(angle) };
        }
    }.at;
    const a = at(c, sign, start);
    const b = at(c, sign, start + short);
    // Mirrored, the arcs run clockwise in the order drawn
    const ring = [_]primitives.OutlineEdge{
        .{ .a = a, .b = b, .arc = .{ .c = c, .r = DISC_RADIUS, .ccw = !mirrored } },
        .{ .a = b, .b = a, .arc = .{ .c = c, .r = DISC_RADIUS, .ccw = !mirrored } },
    };
    return primitives.outlines(testing.allocator, tol, &.{&ring}, diag);
}

fn placeOf(sheet: *const @import("../topology/body.zig").Body, p: Vec2, diag: *Diagnostics) !in_face.Place {
    const f = types.FaceIndex.of(0);
    const p3: vec.Vec3 = .{ p[0], p[1], 0 };
    return in_face.classify(sheet, f, p3, in_face.uvOf(sheet, f, p3), 0, diag);
}

test "in face: a point inside a disc of two arcs is inside, however the circle is cut (the find dg)" {
    // The long arc winds 2π − 0.32 about the find's point; measured the short way, whole
    // and by its halves, it read −0.32, the halves agreeing, and the point was outside its
    // own cap (in_face.sweptAngle)
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var sheet = try disc(DISC_CENTRE, 0, FIND_SHORT_ARC, false, &diag);
    defer sheet.deinit();
    try testing.expectEqual(in_face.Place.inside, try placeOf(&sheet, FIND_POINT, &diag));
}

test "in face: points about a disc of two arcs are inside within the rim and outside past it, the cut anywhere, mirrored or not" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    for (SHORT_ARCS) |short| for (ARC_STARTS) |start| for ([_]bool{ false, true }) |mirrored| {
        var sheet = try disc(DISC_CENTRE, start, short, mirrored, &diag);
        defer sheet.deinit();
        const sign: f64 = if (mirrored) -1 else 1;
        for (RADIUS_SHARES) |share| for (0..POINT_ANGLES) |k| {
            const angle = 2 * std.math.pi * (@as(f64, @floatFromInt(k)) + 0.5) / POINT_ANGLES;
            const p: Vec2 = .{ sign * DISC_CENTRE[0] + sign * share * DISC_RADIUS * @cos(angle), DISC_CENTRE[1] + share * DISC_RADIUS * @sin(angle) };
            errdefer std.debug.print("short arc {d} from {d}, mirrored {}: the point {d} of the radius at {d}\n", .{ short, start, mirrored, share, angle });
            const want: in_face.Place = if (share < 1) .inside else .outside;
            try testing.expectEqual(want, try placeOf(&sheet, p, &diag));
        };
    };
}
