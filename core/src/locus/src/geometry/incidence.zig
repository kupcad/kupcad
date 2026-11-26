//! When one thing lies on another (docs/architecture.md §3, §7.4): the one place the
//! tolerant "on" is written, for the boolean's paves, its classification and
//! simplification, and the rules that check a body (OCCT's `IntTools_Context`, one service
//! every stage and the checker ask; Hoffmann, Geometric and Solid Modeling pp. 81–91: a
//! geometric question is asked once, and what follows from the answer is derived from it,
//! never measured again).
//!
//! A vertex reaches as far as the intersection tolerance and its gap (`reach`), measured
//! at the vertex's point: it is on a plane or a curve within that of it, and two vertices
//! are one within the tolerance and both gaps. An edge reaches by its gap too, the larger
//! of its end vertices' (`edgeGap`: its curve lies within them of the segment between
//! their points): a vertex is on an edge, or a face's boundary there, within the tolerance,
//! its gap and the edge's (`onEdge`), and two edges meet within the tolerance and both
//! edges' gaps (`edgesMeet`), as two things interfere within the tolerance and the sum of
//! their gaps (architecture §7.1; OCCT's Tol(V) + Tol(E), Tol(E1) + Tol(E2)), an edge
//! measured by the segment between its end vertices' points; its curve itself, which a
//! face's boundary is, needs no widening (`onCurve`). The paves
//! measured an edge's crossing against the tolerance alone while a face was in another's
//! plane by its corners' gaps (Leo, 2026-11-16: the 10K session's find af). An edge lies in
//! a plane when both its end vertices are on it (a line; a curved edge's curve between
//! them too), a face when every vertex of it is. A distance within rounding of its limit is
//! neither (D27, `canonical.Verdict.at_tolerance`): the caller refuses it, the boolean and
//! the rules that check a body that exists alike (`intersect/planar_faces.zig`'s `place`
//! and `onPlaneOf`, Leo, 2026-11-26: taken for within there, a body moved far, its
//! distances rounded into the band, read as overlapping itself where in place it did not,
//! the solids oracle's finds dt and dy). Only a warning, which decides nothing, takes the
//! plain comparison (`holds`).

const std = @import("std");
const canonical = @import("canonical.zig");
const Tolerance = @import("../tolerance.zig").Tolerance;

pub const Verdict = canonical.Verdict;

/// How far a vertex with gap `gap` reaches: the intersection tolerance and its gap.
pub fn reach(tol: Tolerance, gap: f64) f64 {
    return tol.xsect + gap;
}

/// How far an edge reaches beyond the tolerance: the larger of its end vertices' gaps
/// (`gap_start`, `gap_end`), within which its curve lies of the segment between their
/// points all along.
pub fn edgeGap(gap_start: f64, gap_end: f64) f64 {
    return @max(gap_start, gap_end);
}

/// The decisions at a tolerance, for coordinates of size `scale` at most (what their
/// distances are rounded at).
pub const Decider = struct {
    tol: Tolerance,
    scale: f64,

    /// The widest band a decision here has about its limit: the farthest limit is two
    /// vertices' (the tolerance and two gaps, each the zone at most). What a search must
    /// reach beyond a limit to see every distance the limit decides.
    pub fn band(self: Decider) f64 {
        return canonical.Comparison.distance(0, self.tol.xsect + 2 * self.tol.zone, self.scale).band;
    }

    /// `d ≤ limit`, at the tolerance when `d` is within rounding of `limit`.
    pub fn within(self: Decider, d: f64, limit: f64) Verdict {
        return canonical.verdict(&.{canonical.Comparison.distance(d, limit, self.scale)});
    }

    /// A vertex with gap `gap`, `height` from a plane, on it.
    pub fn onPlane(self: Decider, height: f64, gap: f64) Verdict {
        return self.within(@abs(height), reach(self.tol, gap));
    }

    /// A vertex with gap `gap`, `distance` from a curve or a face's boundary (the edges'
    /// curves themselves, which their end vertices' gaps do not widen: those are the
    /// segments' between the vertices' points, `onEdge`), on it.
    pub fn onCurve(self: Decider, distance: f64, gap: f64) Verdict {
        return self.within(distance, reach(self.tol, gap));
    }

    /// A vertex with gap `gap`, `distance` from an edge with gap `edge_gap` (`edgeGap`), on
    /// it.
    pub fn onEdge(self: Decider, distance: f64, gap: f64, edge_gap: f64) Verdict {
        return self.within(distance, self.tol.xsect + gap + edge_gap);
    }

    /// Two edges with gaps `gap_a` and `gap_b` (`edgeGap`), their nearest points
    /// `distance` apart, meeting there.
    pub fn edgesMeet(self: Decider, distance: f64, gap_a: f64, gap_b: f64) Verdict {
        return self.within(distance, self.tol.xsect + gap_a + gap_b);
    }

    /// Two vertices `distance` apart, with gaps `gap_a` and `gap_b`, one vertex.
    pub fn merged(self: Decider, distance: f64, gap_a: f64, gap_b: f64) Verdict {
        return self.within(distance, self.tol.xsect + gap_a + gap_b);
    }
};

/// A verdict as a plain comparison, for a warning, which decides nothing and so refuses
/// nothing: at the tolerance is within it.
pub fn holds(verdict: Verdict) bool {
    return verdict != .apart;
}
