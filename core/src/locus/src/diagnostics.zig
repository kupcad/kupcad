//! What every operation takes and reports (docs/architecture.md §4.1): the error set, the
//! `Diagnostics` an operation fills with findings that name the entity and the measured
//! value (Zig errors carry no payload), the `Limits` that bound every loop a bad input could
//! lengthen, the `Options` every operation has in common (tolerance, limits, a cancel flag,
//! a `Parallel`, a trace directory), and the input checks at the boundary.

const std = @import("std");
const Tolerance = @import("tolerance.zig").Tolerance;
const Parallel = @import("parallel.zig").Parallel;

/// How an operation fails. The class is the error; the entity and the numbers are in the
/// `Diagnostics`.
pub const Error = error{
    /// An argument the operation can't take: not a number, not positive, an empty list, a
    /// range the wrong way round, a tolerance that isn't one, a body that fails the
    /// structural checker, a model too large for its tolerance.
    InvalidInput,
    /// The inputs are a degenerate configuration the operation can't resolve (a zero-length
    /// edge to sweep, a face of no area).
    Degenerate,
    /// The result has no representation in Locus's geometry (a non-uniform scale of an
    /// analytic surface).
    NotRepresentable,
    /// An edge too short to split (its shrunk range under `2·xsect`).
    TooSmallEdge,
    /// An intersection the tracer could not complete.
    IntersectionFailed,
    /// The result failed the checker: the findings say which rule and entity.
    NotValid,
    /// A scheduled capability not built yet (the milestone is in the finding).
    NotImplemented,
    /// A `Limits` bound was reached.
    LimitExceeded,
    /// The host's cancel flag was set; the inputs are untouched and nothing stays allocated.
    Canceled,
    OutOfMemory,
};

/// What a finding is about.
pub const EntityKind = enum(u8) { none, vertex, edge, coedge, loop, face, shell, body, curve, surface, argument };

/// The checker's structural failures are `error.NotValid` with the finding.
pub const EntityRef = struct {
    kind: EntityKind = .none,
    index: u32 = 0,

    pub const none: EntityRef = .{};

    pub fn of(kind: EntityKind, index: anytype) EntityRef {
        return .{ .kind = kind, .index = @intCast(index) };
    }
};

pub const Severity = enum(u8) { warning, failure };

/// The named rules and conditions a finding reports; `describe` is their text. The
/// checker's rules join this list as they are written.
pub const Code = enum(u16) {
    not_finite,
    not_positive,
    empty_input,
    range_reversed,
    bad_tolerance,
    too_large_for_tolerance,
    limit_exceeded,
    not_implemented,
    // The checker's structural rules (topology/check.zig, §9.1)
    index_out_of_range,
    next_prev_not_reciprocal,
    partner_not_reciprocal,
    partner_same_sense,
    loop_not_connected,
    loop_not_closed,
    loop_empty,
    coedge_loop_disagrees,
    edge_coedge_count,
    degenerate_edge_vertices,
    edge_range_reversed,
    vertex_coedge_not_leaving,
    shell_list_not_closed,
    face_shell_disagrees,
    loop_face_disagrees,
    face_without_loop,
    face_shell_count,
    euler_poincare,
    // Orientation
    open_edge_in_closed_shell,
    // Geometric
    vertex_off_curve,
    degenerate_edge_not_point,
    edge_too_short,
    gap_order,
    gap_too_large,
    edge_off_surface,
    pcurve_off_edge,
    pcurve_outside_box,
    pcurves_disjoint,
    uv_box_outside_domain,
    uv_box_wraps,
    loop_winding,
    shell_inside_out,
    vertices_too_close,
    // Global (level 2)
    hole_outside_outer,
    redundant_topology,
    singular_vertex,
    faces_overlap,
    faces_intersect,
    shell_overlaps,
    // Booleans (boolean/)
    imprint_unmatched,
    unclassified,
    nearly_coplanar,
    solids_touch,
    // Triangulation (mesh/triangulate.zig)
    ring_starts,
    ring_too_small,
    not_simple,

    pub fn describe(self: Code) []const u8 {
        return switch (self) {
            .not_finite => "is not a finite number",
            .not_positive => "must be positive",
            .empty_input => "is empty",
            .range_reversed => "must start before it ends",
            .bad_tolerance => "is not a valid tolerance (every field finite and positive, xsect at least zone)",
            .too_large_for_tolerance => "is too large for the tolerance: zone must be at least the extent times 1e-12",
            .limit_exceeded => "went past a limit",
            .not_implemented => "is not implemented yet",
            .index_out_of_range => "refers to an entity that is not there",
            .next_prev_not_reciprocal => "has a next whose prev is another",
            .partner_not_reciprocal => "has a partner that is not its own, or on another edge",
            .partner_same_sense => "runs the same way as its partner (its shell is regular, not oriented)",
            .loop_not_connected => "ends where the next coedge does not start",
            .loop_not_closed => "does not close",
            .loop_empty => "has neither coedges nor a vertex",
            .coedge_loop_disagrees => "names a loop it is not in",
            .edge_coedge_count => "has not one or two coedges (its shell is irregular)",
            .degenerate_edge_vertices => "is degenerate without start == end, or the reverse",
            .edge_range_reversed => "has its range the wrong way round",
            .vertex_coedge_not_leaving => "names a coedge that does not leave it",
            .shell_list_not_closed => "has a list of shells or faces that does not end",
            .face_shell_disagrees => "names a shell it is not in",
            .loop_face_disagrees => "names a face it is not in",
            .face_without_loop => "has no loop",
            .face_shell_count => "is in another number of shells than one",
            .euler_poincare => "fails Euler–Poincaré: V − E + F − (L − F) is not 2(1 − G) for a whole G ≥ 0",
            .open_edge_in_closed_shell => "has one coedge in a closed shell (the shell is oriented, not closed)",
            .vertex_off_curve => "has a vertex off its curve's end",
            .degenerate_edge_not_point => "is degenerate but not a point",
            .edge_too_short => "is shorter than the minimum feature size",
            .gap_order => "has a gap larger than its vertex's",
            .gap_too_large => "has a gap past the zone",
            .edge_off_surface => "does not lie on a face's surface",
            .pcurve_off_edge => "has a pcurve that does not lift onto its edge",
            .pcurve_outside_box => "has a pcurve that leaves its face's UV box",
            .pcurves_disjoint => "has a pcurve that does not join the one before it in UV",
            .uv_box_outside_domain => "has a UV box outside its surface's domain",
            .uv_box_wraps => "has a UV box wider than its surface's period",
            .loop_winding => "runs the wrong way round in UV: an outer loop is counter-clockwise about the outward normal, a hole clockwise",
            .shell_inside_out => "has its loops wound inward: its signed volume has the wrong sign",
            .vertices_too_close => "is within the zone of another vertex",
            .hole_outside_outer => "has a hole loop that is not inside its outer loop, or is inside another hole",
            .redundant_topology => "could be merged: its two faces lie on one surface the same way, or are one face",
            .singular_vertex => "is singular: the faces about it are not one fan (a solid touching itself at a point)",
            .faces_overlap => "lies under more than one face of the sheet, or under a face facing the other way",
            .faces_intersect => "meets another face of the body away from the two faces' boundaries, passing through it or lying on it (the measured value is the other face)",
            .imprint_unmatched => "was split where the operands' interferences found no point (its pieces and its neighbours' would not meet)",
            .nearly_coplanar => "lies parallel to a face of the other operand a hair from its plane (the measured distance), not in it: the result has faces as thin as that",
            .solids_touch => "is where two solids of the result touch along a line: one edge for each, at one place",
            .unclassified => "has a piece that lies on the other operand's boundary but on none of its faces in this face's plane, so it is neither inside nor outside",
            .shell_overlaps => "lies where the body's other shells put this much material, not none (an outer shell) or one (a void)",
            .ring_starts => "do not begin at 0, rise, and end at the point count",
            .ring_too_small => "has fewer than three points",
            .not_simple => "is not simple: its rings cross or touch, or repeat a point",
        };
    }
};

/// One thing an operation found: a rule or condition, the entity it concerns, and the
/// measured value against the threshold it failed. `label` names an argument (a static
/// string, never allocated).
pub const Finding = struct {
    code: Code,
    severity: Severity = .failure,
    entity: EntityRef = .none,
    label: []const u8 = "",
    measured: f64 = 0,
    threshold: f64 = 0,

    pub fn format(self: Finding, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.severity == .warning) try writer.writeAll("warning: ");
        if (self.label.len > 0) {
            try writer.print("{s} {s}", .{ self.label, self.code.describe() });
        } else {
            try writer.print("{s} {s}", .{ @tagName(self.entity.kind), self.code.describe() });
        }
        if (self.entity.kind != .none and self.entity.kind != .argument) try writer.print(" ({s} {d})", .{ @tagName(self.entity.kind), self.entity.index });
        if (self.measured != 0 or self.threshold != 0) try writer.print(": {d} against {d}", .{ self.measured, self.threshold });
    }
};

/// The findings of an operation, in the order they were made. `init` allocates nothing; a
/// finding that can't be recorded is `error.OutOfMemory`.
pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    findings: std.ArrayList(Finding) = .empty,

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.findings.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *Diagnostics) void {
        self.findings.clearRetainingCapacity();
    }

    pub fn add(self: *Diagnostics, finding: Finding) Error!void {
        self.findings.append(self.allocator, finding) catch return error.OutOfMemory;
    }

    /// Records `finding` as a failure and gives back `err` to return: `return diag.fail(err,
    /// .{ ... })`.
    pub fn fail(self: *Diagnostics, err: Error, finding: Finding) Error {
        var f = finding;
        f.severity = .failure;
        self.add(f) catch |e| return e;
        return err;
    }

    pub fn warn(self: *Diagnostics, finding: Finding) Error!void {
        var f = finding;
        f.severity = .warning;
        try self.add(f);
    }

    pub fn failures(self: *const Diagnostics) usize {
        return self.count(.failure);
    }

    pub fn warnings(self: *const Diagnostics) usize {
        return self.count(.warning);
    }

    fn count(self: *const Diagnostics, severity: Severity) usize {
        var n: usize = 0;
        for (self.findings.items) |f| n += @intFromBool(f.severity == severity);
        return n;
    }

    /// The first failure, which is what an error names.
    pub fn first(self: *const Diagnostics) ?Finding {
        for (self.findings.items) |f| if (f.severity == .failure) return f;
        return null;
    }

    /// Every finding, one per line.
    pub fn format(self: *const Diagnostics, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.findings.items) |f| {
            try f.format(writer);
            try writer.writeByte('\n');
        }
    }
};

/// The bounds on every iteration a bad input could lengthen. The loops are bounded by
/// construction; these make the bounds explicit and the host's to set (KupCAD's
/// `max_newton_trials` and `max_marching_steps` are two of them).
pub const Limits = struct {
    /// Newton steps for one projection or root.
    newton_trials: u32 = 50,
    /// Steps of one marched intersection curve.
    marching_steps: u32 = 500,
    /// Depth of recursive subdivision (curve–surface intersection, bounds).
    subdivision_depth: u32 = 64,
    /// Points a curve fit may use.
    fit_points: u32 = 4096,
    /// Faces one body may have.
    faces_per_body: u32 = 1 << 20,
    /// Entities of one kind one arena may hold.
    entities_per_arena: u32 = 1 << 31,

    pub fn isValid(self: Limits) bool {
        return self.newton_trials > 0 and self.marching_steps > 0 and self.subdivision_depth > 0 and
            self.fit_points > 0 and self.faces_per_body > 0 and self.entities_per_arena > 0;
    }
};

/// What every operation takes besides its inputs. Each operation's own options struct
/// A trace sink (§12): the host receives the body after each phase of an operation as its
/// JSON, with the operation's and the phase's names (`transform`, `mapped`), and keeps what
/// it wants (a file per phase, `kupcad dev brep-trace`); Locus writes no files itself. The
/// text is the sink's to read during the call only.
pub const Trace = struct {
    context: ?*anyopaque = null,
    write: *const fn (context: ?*anyopaque, operation: []const u8, phase: []const u8, body_json: []const u8) void,
};

/// holds one of these as `common`.
pub const Options = struct {
    /// The tolerance to work at; null: the bodies' own (merged for two).
    tolerance: ?Tolerance = null,
    limits: Limits = .{},
    /// Set by the host to stop the operation: checked between phases and every few hundred
    /// inner steps; the operation then returns `error.Canceled` with its inputs untouched
    /// and nothing allocated.
    cancel: ?*const std.atomic.Value(bool) = null,
    /// How to split independent work over threads; null: serial.
    parallel: ?Parallel = null,
    /// Where the body after each phase goes (§12), as JSON; null: no trace.
    trace: ?Trace = null,

    /// `error.Canceled` when the host has set the flag.
    pub fn checkCancel(self: *const Options) Error!void {
        if (self.cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
    }

    pub fn parallelOrSerial(self: *const Options) Parallel {
        return self.parallel orelse Parallel.serial;
    }
};

/// The checks at the boundary of every operation: a violation is `error.InvalidInput`
/// with a finding naming the argument, never an assertion (README rule 9).
pub const input = struct {
    pub fn finite(diag: *Diagnostics, label: []const u8, value: f64) Error!void {
        if (!(value - value == 0)) return diag.fail(error.InvalidInput, .{ .code = .not_finite, .entity = .{ .kind = .argument }, .label = label, .measured = value });
    }

    pub fn positive(diag: *Diagnostics, label: []const u8, value: f64) Error!void {
        try finite(diag, label, value);
        if (!(value > 0.0)) return diag.fail(error.InvalidInput, .{ .code = .not_positive, .entity = .{ .kind = .argument }, .label = label, .measured = value });
    }

    pub fn range(diag: *Diagnostics, label: []const u8, t0: f64, t1: f64) Error!void {
        try finite(diag, label, t0);
        try finite(diag, label, t1);
        if (!(t0 < t1)) return diag.fail(error.InvalidInput, .{ .code = .range_reversed, .entity = .{ .kind = .argument }, .label = label, .measured = t0, .threshold = t1 });
    }

    pub fn nonEmpty(diag: *Diagnostics, label: []const u8, len: usize) Error!void {
        if (len == 0) return diag.fail(error.InvalidInput, .{ .code = .empty_input, .entity = .{ .kind = .argument }, .label = label });
    }

    pub fn tolerance(diag: *Diagnostics, tol: Tolerance) Error!void {
        if (!tol.isValid()) return diag.fail(error.InvalidInput, .{ .code = .bad_tolerance, .entity = .{ .kind = .argument }, .label = "tolerance", .measured = tol.zone, .threshold = tol.xsect });
    }

    /// The scale guard on an argument (§12): `f64` carries about 16 digits, so a zone
    /// below the largest coordinate times 1e-12 is under the spacing of the coordinates.
    /// The checker applies the same rule to every body at its geometric level
    /// (`too_large_for_tolerance` on the body), so a built, loaded or moved body is caught
    /// there; this is for sizes and offsets before anything is built.
    pub fn scale(diag: *Diagnostics, magnitude: f64, tol: Tolerance) Error!void {
        if (!(tol.zone >= magnitude * SCALE_GUARD)) return diag.fail(error.InvalidInput, .{ .code = .too_large_for_tolerance, .entity = .{ .kind = .body }, .label = "the model", .measured = magnitude, .threshold = tol.zone / SCALE_GUARD });
    }
};

/// The least `zone / magnitude` a body may have (the magnitude its largest coordinate):
/// about 64 ulp of the coordinate, with a digit of margin over `f64`'s spacing.
pub const SCALE_GUARD: f64 = 1e-12;

/// `error.LimitExceeded` with a finding, for a loop that reached its bound.
pub fn limitExceeded(diag: *Diagnostics, label: []const u8, reached: usize, limit: usize) Error {
    return diag.fail(error.LimitExceeded, .{ .code = .limit_exceeded, .label = label, .measured = @floatFromInt(reached), .threshold = @floatFromInt(limit) });
}

/// `error.NotImplemented` with a finding naming the milestone that adds it.
pub fn notImplemented(diag: *Diagnostics, label: []const u8, milestone: u8) Error {
    return diag.fail(error.NotImplemented, .{ .code = .not_implemented, .label = label, .threshold = @floatFromInt(milestone) });
}
