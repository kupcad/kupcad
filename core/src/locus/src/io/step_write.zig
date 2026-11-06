//! The STEP writer (AP214, docs/architecture.md §7.9): one `MANIFOLD_SOLID_BREP` per
//! solid body, its vertices and edges written once, every curve and surface as its own
//! STEP entity (a plane as `PLANE`, a circle as `CIRCLE`, …) in Part 42's parameterization,
//! which is Locus's own, and every number at full `f64` precision (the shortest text that
//! reads back to the same double, never rounded). The file's uncertainty is the first
//! body's `zone`. A left-handed frame (a mirrored body's) has no STEP form: its surface is
//! written right-handed and the face's sense turned, which is the same face. NURBS, swept
//! surfaces and sheet bodies are M1's.

const std = @import("std");
const vec = @import("../math/vec.zig");
const geometry = @import("../geometry/types.zig");
const curves = @import("../geometry/curves.zig");
const surfaces = @import("../geometry/surfaces.zig");
const types = @import("../topology/types.zig");
const body_mod = @import("../topology/body.zig");
const traverse = @import("../topology/traverse.zig");
const Body = body_mod.Body;
const Vec3 = vec.Vec3;

pub const Error = error{
    OutOfMemory,
    /// No body, or a sheet body: STEP's solid form has no open shells.
    NotSolid,
    /// A NURBS, extrusion or revolution: M1 writes them.
    NotImplemented,
    /// A traversal did not close.
    Corrupt,
};

/// The entity ids of the header; bodies start after them.
const HEADER_ENTITIES: u32 = 16;

const Writer = struct {
    allocator: std.mem.Allocator,
    out: std.Io.Writer.Allocating,
    next: u32 = HEADER_ENTITIES,

    fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator, .out = .init(allocator) };
    }

    /// Writes `#id=<fmt>;` and returns the id.
    fn emit(self: *Writer, comptime fmt: []const u8, args: anytype) Error!u32 {
        self.next += 1;
        self.out.writer.print("#{d}=" ++ fmt ++ ";\n", .{self.next} ++ args) catch return error.OutOfMemory;
        return self.next;
    }

    fn point(self: *Writer, p: Vec3) Error!u32 {
        return self.emit("CARTESIAN_POINT('',({f},{f},{f}))", .{ real(p[0]), real(p[1]), real(p[2]) });
    }

    fn direction(self: *Writer, d: Vec3) Error!u32 {
        return self.emit("DIRECTION('',({f},{f},{f}))", .{ real(d[0]), real(d[1]), real(d[2]) });
    }

    /// `AXIS2_PLACEMENT_3D` at `origin` with axis `z` and reference direction `x`.
    fn placement(self: *Writer, origin: Vec3, z: Vec3, x: Vec3) Error!u32 {
        const o = try self.point(origin);
        const az = try self.direction(z);
        const ax = try self.direction(x);
        return self.emit("AXIS2_PLACEMENT_3D('',#{d},#{d},#{d})", .{ o, az, ax });
    }
};

/// A number as STEP wants it: the shortest text that reads back exactly, with a decimal
/// point or exponent (a REAL literal must have one).
const Real = struct {
    value: f64,
    pub fn format(self: Real, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{self.value}) catch unreachable;
        try w.writeAll(text);
        if (std.mem.indexOfAny(u8, text, ".eE") == null) try w.writeAll(".");
    }
};

fn real(v: f64) Real {
    return .{ .value = v };
}

/// The STEP file of `bodies`, each a solid, the caller's to free.
pub fn write(allocator: std.mem.Allocator, bodies: []const *const Body) Error![]u8 {
    if (bodies.len == 0) return error.NotSolid;
    for (bodies) |b| if (b.kind != .solid or b.isEmpty()) return error.NotSolid;
    var w = Writer.init(allocator);
    errdefer w.out.deinit();
    // Every body's solid id comes first, so the representation can list them
    const first_solid = w.next + 1;
    w.next += @intCast(bodies.len);
    w.out.writer.print(
        \\ISO-10303-21;
        \\HEADER;
        \\FILE_DESCRIPTION(('KupCAD B-Rep export'),'2;1');
        \\FILE_NAME('kupcad_export.step','','','','','','');
        \\FILE_SCHEMA(('AUTOMOTIVE_DESIGN {{ 1 0 10303 214 1 1 1 1 }}'));
        \\ENDSEC;
        \\DATA;
        \\#1=APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2001,#2);
        \\#2=APPLICATION_CONTEXT('core data for automotive mechanical design processes');
        \\#3=SHAPE_DEFINITION_REPRESENTATION(#4,#10);
        \\#4=PRODUCT_DEFINITION_SHAPE('','',#5);
        \\#5=PRODUCT_DEFINITION('design','',#6,#9);
        \\#6=PRODUCT_DEFINITION_FORMATION('','',#7);
        \\#7=PRODUCT('KupCAD Part','KupCAD Part','',(#8));
        \\#8=PRODUCT_CONTEXT('',#2,'mechanical');
        \\#9=PRODUCT_DEFINITION_CONTEXT('part definition',#2,'design');
        \\#10=ADVANCED_BREP_SHAPE_REPRESENTATION('',(
    , .{}) catch return error.OutOfMemory;
    for (0..bodies.len) |i| {
        w.out.writer.print("{s}#{d}", .{ if (i > 0) "," else "", first_solid + @as(u32, @intCast(i)) }) catch return error.OutOfMemory;
    }
    w.out.writer.print(
        \\),#12);
        \\#12=(GEOMETRIC_REPRESENTATION_CONTEXT(3) GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#13)) GLOBAL_UNIT_ASSIGNED_CONTEXT((#14,#15,#16)) REPRESENTATION_CONTEXT('Context #1','3D Context with UNITS and UNCERTAINTY'));
        \\#13=UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE({f}),#14,'distance_accuracy_value','confusion accuracy');
        \\#14=(LENGTH_UNIT() NAMED_UNIT(*) SI_UNIT(.MILLI.,.METRE.));
        \\#15=(NAMED_UNIT(*) PLANE_ANGLE_UNIT() SI_UNIT($,.RADIAN.));
        \\#16=(NAMED_UNIT(*) SI_UNIT($,.STERADIAN.) SOLID_ANGLE_UNIT());
        \\
    , .{real(bodies[0].tol.zone)}) catch return error.OutOfMemory;
    for (bodies, 0..) |b, i| try writeBody(&w, b, first_solid + @as(u32, @intCast(i)));
    w.out.writer.writeAll("ENDSEC;\nEND-ISO-10303-21;\n") catch return error.OutOfMemory;
    return w.out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeBody(w: *Writer, body: *const Body, solid_id: u32) Error!void {
    const allocator = w.allocator;
    // Vertices once
    const vertex_ids = try allocator.alloc(u32, body.vertices.items.len);
    defer allocator.free(vertex_ids);
    for (body.vertices.items, 0..) |v, i| {
        if (v.tombstone) continue;
        const p = try w.point(body.geometry.point(v.point));
        vertex_ids[i] = try w.emit("VERTEX_POINT('',#{d})", .{p});
    }
    // Edges once, each with its curve
    const edge_ids = try allocator.alloc(u32, body.edges.items.len);
    defer allocator.free(edge_ids);
    for (body.edges.items, 0..) |e, i| {
        // A degenerate edge (a pole, an apex) is a point: STEP has no entity for it and
        // readers close the loop over it (what OCCT writes)
        if (e.flags.tombstone or e.flags.degenerate) continue;
        const curve_id = try writeCurve(w, body.geometry.curve(e.curve));
        edge_ids[i] = try w.emit("EDGE_CURVE('',#{d},#{d},#{d},.T.)", .{ vertex_ids[@backingInt(e.start)], vertex_ids[@backingInt(e.end)], curve_id });
    }
    // Faces: their loops of oriented edges, their surface, their bounds
    var face_ids = std.ArrayList(u32).empty;
    defer face_ids.deinit(allocator);
    var shells = traverse.Shells.init(body);
    var outer_shell_id: ?u32 = null;
    while (try shells.next()) |s| {
        face_ids.clearRetainingCapacity();
        var faces = traverse.Faces.init(body, s);
        while (try faces.next()) |f| {
            const face = body.face(f);
            var bound_ids = std.ArrayList(u32).empty;
            defer bound_ids.deinit(allocator);
            var loops = traverse.Loops.init(body, f);
            var first = true;
            while (try loops.next()) |l| {
                var oriented = std.ArrayList(u32).empty;
                defer oriented.deinit(allocator);
                var coedges = traverse.Coedges.init(body, l);
                while (try coedges.next()) |c| {
                    const ce = body.coedge(c);
                    if (body.edge(ce.edge).flags.degenerate) continue;
                    try oriented.append(allocator, try w.emit("ORIENTED_EDGE('',*,*,#{d},.{s}.)", .{ edge_ids[@backingInt(ce.edge)], if (ce.same_sense) "T" else "F" }));
                }
                w.next += 1;
                const loop_id = w.next;
                w.out.writer.print("#{d}=EDGE_LOOP('',(", .{loop_id}) catch return error.OutOfMemory;
                for (oriented.items, 0..) |id, k| w.out.writer.print("{s}#{d}", .{ if (k > 0) "," else "", id }) catch return error.OutOfMemory;
                w.out.writer.writeAll("));\n") catch return error.OutOfMemory;
                try bound_ids.append(allocator, try w.emit("{s}('',#{d},.T.)", .{ if (first) "FACE_OUTER_BOUND" else "FACE_BOUND", loop_id }));
                first = false;
            }
            const surface = body.geometry.surface(face.surface);
            const written = try writeSurface(w, surface);
            // A left-handed frame is written right-handed: its normal turns, so the sense does
            const sense = face.same_sense != written.flipped;
            w.next += 1;
            const face_id = w.next;
            w.out.writer.print("#{d}=ADVANCED_FACE('',(", .{face_id}) catch return error.OutOfMemory;
            for (bound_ids.items, 0..) |id, k| w.out.writer.print("{s}#{d}", .{ if (k > 0) "," else "", id }) catch return error.OutOfMemory;
            w.out.writer.print("),#{d},.{s}.);\n", .{ written.id, if (sense) "T" else "F" }) catch return error.OutOfMemory;
            try face_ids.append(allocator, face_id);
        }
        w.next += 1;
        const shell_id = w.next;
        w.out.writer.print("#{d}=CLOSED_SHELL('',(", .{shell_id}) catch return error.OutOfMemory;
        for (face_ids.items, 0..) |id, k| w.out.writer.print("{s}#{d}", .{ if (k > 0) "," else "", id }) catch return error.OutOfMemory;
        w.out.writer.writeAll("));\n") catch return error.OutOfMemory;
        if (body.shell(s).kind == .outer and outer_shell_id == null) outer_shell_id = shell_id;
    }
    const outer = outer_shell_id orelse return error.NotSolid;
    w.out.writer.print("#{d}=MANIFOLD_SOLID_BREP('',#{d});\n", .{ solid_id, outer }) catch return error.OutOfMemory;
}

fn writeCurve(w: *Writer, c: curves.Curve) Error!u32 {
    switch (c) {
        .line => |l| {
            const o = try w.point(l.o);
            const d = try w.direction(l.d);
            const v = try w.emit("VECTOR('',#{d},1.)", .{d});
            return w.emit("LINE('',#{d},#{d})", .{ o, v });
        },
        .circle => |ci| {
            const p = try w.placement(ci.c, ci.normal(), ci.x);
            return w.emit("CIRCLE('',#{d},{f})", .{ p, real(ci.r) });
        },
        .ellipse => |e| {
            const p = try w.placement(e.c, e.normal(), e.x);
            return w.emit("ELLIPSE('',#{d},{f},{f})", .{ p, real(e.a), real(e.b) });
        },
        .nurbs => return error.NotImplemented,
    }
}

const WrittenSurface = struct { id: u32, flipped: bool };

fn writeSurface(w: *Writer, s: surfaces.Surface) Error!WrittenSurface {
    switch (s) {
        .plane => |p| {
            const pl = try w.placement(p.frame.origin, p.frame.z, p.frame.x);
            return .{ .id = try w.emit("PLANE('',#{d})", .{pl}), .flipped = p.frame.sign() < 0 };
        },
        .cylinder => |c| {
            const pl = try w.placement(c.frame.origin, c.frame.z, c.frame.x);
            return .{ .id = try w.emit("CYLINDRICAL_SURFACE('',#{d},{f})", .{ pl, real(c.r) }), .flipped = c.frame.sign() < 0 };
        },
        .cone => |c| {
            const pl = try w.placement(c.frame.origin, c.frame.z, c.frame.x);
            return .{ .id = try w.emit("CONICAL_SURFACE('',#{d},{f},{f})", .{ pl, real(c.r), real(c.half_angle) }), .flipped = c.frame.sign() < 0 };
        },
        .sphere => |sp| {
            const pl = try w.placement(sp.frame.origin, sp.frame.z, sp.frame.x);
            return .{ .id = try w.emit("SPHERICAL_SURFACE('',#{d},{f})", .{ pl, real(sp.r) }), .flipped = sp.frame.sign() < 0 };
        },
        .torus => |t| {
            const pl = try w.placement(t.frame.origin, t.frame.z, t.frame.x);
            return .{ .id = try w.emit("TOROIDAL_SURFACE('',#{d},{f},{f})", .{ pl, real(t.major), real(t.minor) }), .flipped = t.frame.sign() < 0 };
        },
        .extrusion, .revolution, .nurbs => return error.NotImplemented,
    }
}
